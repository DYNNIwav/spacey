import Cocoa

class WindowManager: WindowObserverDelegate {
    static let shared = WindowManager()

    var config: PanelessConfig
    /// One layout per screen, the way each output in niri and Hyprland carries its own.
    ///
    /// Everything a keybinding does belongs to the screen you are looking at, and that is
    /// what `layoutEngine` hands back. The places that have to touch every screen ask for
    /// them by id instead. There used to be a single engine and a single tiling region, so
    /// with two displays connected every tiled window was laid out on whichever one was
    /// main, and moving focus across dragged the whole set after it.
    private var layoutEngines: [String: LayoutEngine] = [:]

    /// The screen the keyboard is on.
    var currentMonitorID: String {
        WorkspaceManager.shared.screenID(for: NSScreen.safeMain)
    }

    /// The layout belonging to the screen the keyboard is on.
    var layoutEngine: LayoutEngine { engine(for: currentMonitorID) }

    func engine(for monitorID: String) -> LayoutEngine {
        if let existing = layoutEngines[monitorID] { return existing }
        let created = LayoutEngine(config: config, monitorID: monitorID)
        layoutEngines[monitorID] = created
        return created
    }

    /// The screen a workspace or layout is keyed to, if it is still connected.
    func screen(for monitorID: String) -> NSScreen? {
        NSScreen.screens.first { WorkspaceManager.shared.screenID(for: $0) == monitorID }
    }

    /// The tiling region belonging to a layout's own screen.
    func region(for engine: LayoutEngine) -> TilingRegion {
        return getTilingRegion(for: screen(for: engine.monitorID))
    }

    /// The layout for the screen a window is physically sitting on.
    ///
    /// A window belongs to the display it is on, not to the display that happened to have
    /// the keyboard when it opened, which is what decided it before.
    func engine(forWindow wid: CGWindowID) -> LayoutEngine {
        guard let element = axElements[wid],
              let frame = AccessibilityBridge.getFrame(of: element),
              let screen = SpaceManager.screen(containing: CGPoint(x: frame.midX, y: frame.midY))
        else { return layoutEngine }
        return engine(for: WorkspaceManager.shared.screenID(for: screen))
    }

    /// The layout currently holding a window, wherever it ended up.
    func engineHolding(_ wid: CGWindowID) -> LayoutEngine? {
        layoutEngines.values.first {
            $0.tiledWindows.contains(wid) || $0.findWindowInColumns(wid) != nil
        }
    }

    /// Take a window out of every layout. Used when it is destroyed or floated, where
    /// leaving a stale id behind in another screen's list would strand a gap there.
    func removeFromAllEngines(_ wid: CGWindowID) {
        for engine in layoutEngines.values {
            engine.removeWindowFromColumns(wid)
            engine.remove(windowID: wid)
        }
    }
    let observer: WindowObserver
    let eventTap: EventTap

    var onSpaceChange: (() -> Void)?
    var onFocusChange: (() -> Void)?

    var trackedWindows: [CGWindowID: TrackedWindow] = [:]
    var axElements: [CGWindowID: AXUIElement] = [:]
    var floatingWindows: Set<CGWindowID> = []
    var fullscreenWindows: Set<CGWindowID> = []
    var stickyWindows: Set<CGWindowID> = []
    var focusedWindowID: CGWindowID?

    private var mouseMonitor: Any?
    private var lastMouseFocusTime: Date = .distantPast
    private var dimmedWindows: Set<CGWindowID> = []  // windows currently at reduced brightness
    private var clickMonitor: Any?
    private var clickDimWorkItem: DispatchWorkItem?
    private var resizeMonitor: Any?
    private var isResizing = false
    private var resizeStartPos: CGFloat = 0
    private var resizeInitialRatio: CGFloat = 0.5

    // Minimized windows (hidden but tracked in workspace)
    private var minimizedWindows: Set<CGWindowID> = []

    // Window marks (vim-style: key -> windowID)
    private var windowMarks: [String: CGWindowID] = [:]

    // Per-workspace layout memory
    private var workspaceLayouts: [String: Int] = [:]  // "monitorID-wsNum" -> layoutVariant

    // Drag-to-reorder
    private var dragMonitor: Any?
    private var dragStartWindowID: CGWindowID?

    // Niri mode: windows hidden because they're off-screen in the scrolling strip
    private var niriHiddenWindows: Set<CGWindowID> = []
    private var niriHideWorkItem: DispatchWorkItem?

    // Window swallowing: child GUI window ID -> swallowed parent (terminal) window ID
    private var swallowedWindows: [CGWindowID: CGWindowID] = [:]

    // Focus-follows-app: guard against re-entrant workspace switches
    private var isAutoSwitching = false

    // How many times in a row a parked window has been found on screen and parked
    // again without it taking. See windowsPolled.
    private var reparkFailures: [CGWindowID: Int] = [:]

    // Every window that has ever been tiled. Window ids are never reused within a
    // login session, so this only grows by a few bytes per window and never lies.
    private var onceTiled = Set<CGWindowID>()

    // A niri window's measured minimum width, for windows that refuse to be as narrow
    // as their column. Filled in by the poll, read by the niri layout so the column
    // widens to fit rather than letting the window overlap the next one.
    private var niriMinWidth: [CGWindowID: CGFloat] = [:]

    // The monitor whose active workspace is currently loaded into the live set
    // (trackedWindows / axElements / layoutEngine). Used to migrate state when a
    // display is disconnected so windows aren't stranded under a dead monitor ID.
    private var liveMonitorID: String = ""

    // Debounce display-reconfiguration bursts (macOS fires several notifications)
    private var displayReconfigWorkItem: DispatchWorkItem?

    // When a window was last destroyed. Used to distinguish a genuine app activation
    // from macOS auto-activating the next app after the user closed the last window.
    private var lastWindowDestroyedAt: Date = .distantPast

    // When we last switched workspaces. Right after a switch macOS briefly re-activates
    // the app from the previous workspace; without this guard focus-follows-app would
    // summon that app onto the new workspace and hijack focus.
    private var lastWorkspaceSwitchAt: Date = .distantPast

    // How long to wait after an app activation before acting on it. macOS activates
    // the next app in z-order when a window closes, and that notification arrives
    // ahead of the window's destruction, so an immediate decision cannot tell a user
    // request apart from that fallback.
    private let summonSettleDelay: TimeInterval = 0.3
    private var pendingSummon: DispatchWorkItem?

    // Settings UI: skip next config reload (the UI just wrote the file)
    var suppressNextReload = false

    private init() {
        self.config = PanelessConfig.load()
        self.observer = WindowObserver()
        self.eventTap = EventTap()
    }

    func start() {
        BorderManager.shared.config = config.border
        eventTap.keyBindings = config.keyBindings
        eventTap.hyperkeyCode = config.hyperkeyCode
        Animator.shared.enabled = config.animations
        Animator.shared.sizeOnce = config.sizeOnce
        Animator.shared.appDrivenAnimation = config.appDrivenAnimation

        observer.delegate = self
        observer.start()

        eventTap.actionHandler = { [weak self] action in
            self?.handleAction(action)
        }
        eventTap.start()

        scanCurrentSpace()

        // Check for orphaned hidden windows from a previous crash and restore them
        restoreOrphanedWindows()

        // Reset any stale alpha/brightness from previous crash or failed dimming attempts
        restoreAllDimming()

        // Initialize virtual workspace 1 with the scanned windows
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        WorkspaceManager.shared.activeWorkspace[monitorID] = 1
        liveMonitorID = monitorID

        // Spread windows back to their saved workspaces BEFORE the first save, not after.
        //
        // The first save is not debounced away, because the last-save time starts at the
        // distant past, so it writes at once. Doing it first overwrote the saved file with
        // everything piled on workspace 1, and restore then read that clobbered file and
        // found nothing to move: every window stayed on workspace 1, most of them parked
        // off the edge of the strip where they looked lost. Restore first, save the
        // result.
        WorkspacePersistence.restoreWorkspaceAssignments()

        saveWorkspaceState(workspace: 1, monitor: monitorID)
        panelessLog("Initialized workspace 1 on \(monitorID) with \(layoutEngine.tiledWindows.count) tiled windows")

        // Smart retile on display change (monitor connected/disconnected/resolution change)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Focus follows mouse
        if config.focusFollowsMouse {
            startFocusFollowsMouse()
        }

        // Global click monitor to refresh dimming after macOS finishes window activation
        setupClickMonitor()

        // Mouse drag resize between tiled windows
        setupResizeMonitor()

        // Ctrl+drag to reorder tiled windows
        setupDragMonitor()

        // Hold ProMotion at 120Hz for as long as Paneless runs. Arming it only around
        // animations was measured cheaper, 0.0% idle against 2.4%, but the display sits
        // at 60Hz while idle and climbs too slowly: an animation then opened at 21
        // frames where a held keepalive gave 27. Smoothness wins here by instruction.
        if config.forceProMotion {
            startDisplayLink()
        }

        panelessLog("Paneless started (monitors: \(NSScreen.screens.count), bindings: \(config.keyBindings.count))")
    }

    func stop() {
        // Save workspace state before shutting down
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        saveWorkspaceState(workspace: currentWS, monitor: monitorID)
        WorkspacePersistence.saveImmediate()

        Animator.shared.cancelAll()
        BorderManager.shared.removeAll()
        restoreAllDimming()
        unparkEverything()
        stopFocusFollowsMouse()
        stopResizeMonitor()
        stopDisplayLink()
        NotificationCenter.default.removeObserver(self)
        observer.stop()
        eventTap.stop()
        panelessLog("Paneless stopped")
    }

    // MARK: - Action Dispatch

    func handleAction(_ action: WMAction) {
        switch action {
        case .focusDirection(let dir):      focusInDirection(dir)
        case .focusNext:                    focusCycle(forward: true)
        case .focusPrev:                    focusCycle(forward: false)
        case .swapWithMaster:               swapWithMaster()
        case .toggleFloat:                  toggleFloat()
        case .toggleFullscreen:             toggleFullscreen()
        case .closeFocused:                 closeFocused()
        case .focusMonitor(let dir):        focusMonitor(dir)
        case .moveToMonitor(let dir):       moveToMonitor(dir)
        case .positionLeft:                 positionFocused(.left)
        case .positionRight:                positionFocused(.right)
        case .positionUp:                   positionFocused(.up)
        case .positionDown:                 positionFocused(.down)
        case .positionFill:                 positionFocused(.fill)
        case .positionCenter:               positionFocused(.center)
        case .rotateNext:                   rotateWindows(forward: true)
        case .rotatePrev:                   rotateWindows(forward: false)
        case .cycleLayout:                  cycleLayout()
        case .increaseGap:                  adjustGap(by: 4)
        case .decreaseGap:                  adjustGap(by: -4)
        case .growFocused:                  adjustSplitRatio(by: 0.05)
        case .shrinkFocused:                adjustSplitRatio(by: -0.05)
        case .retile:
            layoutEngine.splitRatio = 0.5
            layoutEngine.layoutVariant = 0
            scanCurrentSpace()
        case .reloadConfig:                 reloadConfig()
        case .switchWorkspace(let n):       switchVirtualWorkspace(n)
        case .moveToWorkspace(let n):       moveToVirtualWorkspace(n)
        case .minimizeToWorkspace:          minimizeFocused()
        case .setMark(let key):             setWindowMark(key)
        case .jumpToMark(let key):          jumpToWindowMark(key)
        case .niriConsume:                  niriConsume()
        case .niriMoveColumnLeft:           niriMoveColumn(right: false)
        case .niriMoveColumnRight:          niriMoveColumn(right: true)
        case .niriMoveLeft:                 niriMoveFocused(right: false)
        case .niriMoveUp:                   niriMoveVertical(-1)
        case .niriMoveDown:                 niriMoveVertical(1)
        case .niriMoveRight:                niriMoveFocused(right: true)
        case .niriExpel:                    niriExpel()
        }
    }

    // MARK: - Focus Navigation

    private func focusInDirection(_ direction: Direction) {
        if config.niriMode {
            // In Niri mode, left/right scrolls columns, up/down navigates within column
            switch direction {
            case .left:  niriFocusDirection(-1)
            case .right: niriFocusDirection(1)
            case .up:    niriFocusVertical(-1)
            case .down:  niriFocusVertical(1)
            }
            return
        }

        var currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()

        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())

        // If the focused window isn't in our tiled layout (common with Electron apps
        // like Arc/Cursor that have internal windows), fall back to the first tiled window.
        if let cid = currentID, layouts.first(where: { $0.0 == cid }) == nil {
            currentID = layoutEngine.tiledWindows.first
            if let fid = currentID { focusedWindowID = fid }
        }

        guard let currentID = currentID else { return }

        guard let neighborID = layoutEngine.getNeighbor(of: currentID, direction: direction, layouts: layouts)
        else { return }

        if let element = axElements[neighborID], let tracked = trackedWindows[neighborID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = neighborID
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
            onFocusChange?()
        }
    }

    /// Cycle focus through tiled AND floating windows in list order (wraps around).
    private func focusCycle(forward: Bool) {
        if config.niriMode {
            niriFocusDirection(forward ? 1 : -1)
            return
        }

        // Build a combined list: tiled windows first, then floating windows
        let allWindows = layoutEngine.tiledWindows + Array(floatingWindows).sorted()
        guard allWindows.count >= 2 else { return }

        let currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        let currentIdx = currentID.flatMap { allWindows.firstIndex(of: $0) } ?? 0

        let nextIdx: Int
        if forward {
            nextIdx = (currentIdx + 1) % allWindows.count
        } else {
            nextIdx = (currentIdx - 1 + allWindows.count) % allWindows.count
        }

        let targetID = allWindows[nextIdx]
        if let element = axElements[targetID], let tracked = trackedWindows[targetID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = targetID
            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)

            onFocusChange?()
        }
    }

    // MARK: - Multi-Monitor

    private func focusMonitor(_ direction: Direction) {
        guard let currentScreen = NSScreen.main,
              let targetScreen = SpaceManager.neighborScreen(of: currentScreen, direction: direction)
        else { return }

        for (windowID, tracked) in trackedWindows {
            guard let element = axElements[windowID],
                  !floatingWindows.contains(windowID)
            else { continue }

            if let frame = AccessibilityBridge.getFrame(of: element) {
                let screenForWindow = SpaceManager.screen(containing: CGPoint(x: frame.midX, y: frame.midY))
                if screenForWindow == targetScreen {
                    AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    focusedWindowID = windowID
                    return
                }
            }
        }
    }

    private func moveToMonitor(_ direction: Direction) {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID],
              let currentFrame = AccessibilityBridge.getFrame(of: element)
        else { return }

        let currentScreen = SpaceManager.screen(containing: currentFrame.origin) ?? NSScreen.main!
        guard let targetScreen = SpaceManager.neighborScreen(of: currentScreen, direction: direction) else { return }

        let targetVisible = targetScreen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
        let axY = primaryHeight - targetVisible.origin.y - targetVisible.size.height

        let newFrame = CGRect(
            x: targetVisible.origin.x + (targetVisible.width - currentFrame.width) / 2,
            y: axY + (targetVisible.height - currentFrame.height) / 2,
            width: currentFrame.width,
            height: currentFrame.height
        )
        AccessibilityBridge.setFrame(of: element, to: newFrame)

        // Hand the window over to the other display's layout. Placing it on the screen was
        // all this did, so the window stayed in the layout it came from and the next
        // retile pulled it straight back where it had been.
        guard !floatingWindows.contains(windowID) else { return }
        if let source = engineHolding(windowID) {
            source.removeWindowFromColumns(windowID)
            source.remove(windowID: windowID)
        }
        let target = engine(for: WorkspaceManager.shared.screenID(for: targetScreen))
        target.insert(windowID: windowID, afterFocused: nil)
        if config.niriMode { target.insertWindowAsNewColumn(windowID) }
        retile()
    }

    // MARK: - Swap / Layout

    private func swapWithMaster() {
        guard let currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }
        if config.niriMode {
            // Move active column to first position
            let colIdx = layoutEngine.niriActiveColumn
            guard colIdx > 0 && colIdx < layoutEngine.niriColumns.count else { return }
            let col = layoutEngine.niriColumns.remove(at: colIdx)
            layoutEngine.niriColumns.insert(col, at: 0)
            layoutEngine.niriActiveColumn = 0
            layoutEngine.syncTiledWindowsFromColumns()
            retile()
            return
        }
        layoutEngine.swapWithFirst(currentID)
        retile()
    }

    private func rotateWindows(forward: Bool) {
        guard layoutEngine.tiledWindows.count >= 2 else { return }

        if config.niriMode {
            // Same keys, different job per mode, which is how focus_next already works.
            // In niri this reorders the strip: moving focus within a column became
            // pointless once focus stepping started entering columns by itself.
            niriMoveColumn(right: forward)
            return
        }

        if forward {
            layoutEngine.rotateNext()
        } else {
            layoutEngine.rotatePrev()
        }
        retile()

        // Re-focus the same window at its new position so focus follows the move
        if let fid = focusedWindowID,
           let element = axElements[fid],
           let tracked = trackedWindows[fid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
        }
    }

    // MARK: - Float / Fullscreen

    private func toggleFloat() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        if floatingWindows.contains(windowID) {
            floatingWindows.remove(windowID)
            layoutEngine.insert(windowID: windowID, afterFocused: nil)
        } else {
            floatingWindows.insert(windowID)
            layoutEngine.remove(windowID: windowID)
        }
        retile()
    }

    private func toggleFullscreen() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID]
        else { return }

        if fullscreenWindows.contains(windowID) {
            fullscreenWindows.remove(windowID)
            layoutEngine.insert(windowID: windowID, afterFocused: nil)
            retile()
        } else {
            fullscreenWindows.insert(windowID)
            layoutEngine.remove(windowID: windowID)
            // Use the full visible screen (menu bar + dock respected, no Paneless gaps)
            let screen = NSScreen.safeMain
            let visibleFrame = screen.visibleFrame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let axY = primaryHeight - visibleFrame.origin.y - visibleFrame.size.height
            let fullFrame = CGRect(x: visibleFrame.origin.x, y: axY,
                                   width: visibleFrame.width, height: visibleFrame.height)
            AccessibilityBridge.setFrame(of: element, to: fullFrame)
            retile()
        }
    }

    // MARK: - Window Positioning

    private enum Position { case left, right, up, down, fill, center }

    private func positionFocused(_ position: Position) {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        switch position {
        case .left:
            // Move focused window to first position in layout
            guard layoutEngine.contains(windowID) else { return }
            layoutEngine.tiledWindows.removeAll { $0 == windowID }
            layoutEngine.tiledWindows.insert(windowID, at: 0)
            retile()

        case .right:
            // Move focused window to last position in layout
            guard layoutEngine.contains(windowID) else { return }
            layoutEngine.tiledWindows.removeAll { $0 == windowID }
            layoutEngine.tiledWindows.append(windowID)
            retile()

        case .up:
            // Swap focused window one position earlier
            guard let idx = layoutEngine.tiledWindows.firstIndex(of: windowID), idx > 0 else { return }
            layoutEngine.tiledWindows.swapAt(idx, idx - 1)
            retile()

        case .down:
            // Swap focused window one position later
            guard let idx = layoutEngine.tiledWindows.firstIndex(of: windowID),
                  idx < layoutEngine.tiledWindows.count - 1 else { return }
            layoutEngine.tiledWindows.swapAt(idx, idx + 1)
            retile()

        case .fill:
            guard let element = axElements[windowID] else { return }
            let region = getTilingRegion()
            let gap = config.innerGap
            let halfGap = gap / 2
            let frame = CGRect(
                x: region.x + halfGap,
                y: region.y + halfGap,
                width: max(region.width - gap, 100),
                height: max(region.height - gap, 100)
            )
            AccessibilityBridge.setFrame(of: element, to: frame)

        case .center:
            guard let element = axElements[windowID] else { return }
            let region = getTilingRegion()
            let w = region.width * 0.6
            let h = region.height * 0.7
            let frame = CGRect(
                x: region.x + (region.width - w) / 2,
                y: region.y + (region.height - h) / 2,
                width: w,
                height: h
            )
            AccessibilityBridge.setFrame(of: element, to: frame)
        }
    }

    // MARK: - Close

    private func closeFocused() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID]
        else { return }

        let wasTiled = layoutEngine.contains(windowID)
        let closingFrame = AccessibilityBridge.getFrame(of: element) ?? .zero

        if wasTiled && closingFrame != .zero {
            // Animated close: scale down + fade the closing window
            // while remaining windows redistribute simultaneously

            // Remove from layout so we can calculate remaining layout
            layoutEngine.remove(windowID: windowID)

            // Build transitions for remaining windows
            let region = getTilingRegion()
            let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
                guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
                return (wid, el, t.pid)
            }
            let targetFrames = NativeTiling.calculateFrames(
                count: windows.count, region: region, gap: config.innerGap,
                singleWindowPadding: config.singleWindowPadding,
                splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant
            )

            var transitions: [Animator.Transition] = []
            for (i, w) in windows.enumerated() where i < targetFrames.count {
                let currentFrame = AccessibilityBridge.getFrame(of: w.element) ?? targetFrames[i]
                transitions.append(Animator.Transition(
                    windowID: w.windowID, element: w.element,
                    startFrame: currentFrame, targetFrame: targetFrames[i]
                ))
            }

            // Animate close + redistribute, then actually close the window
            Animator.shared.animateWithClose(
                redistributeTransitions: transitions,
                closingWindowID: windowID,
                closingFrame: closingFrame,
                closingElement: element
            ) { [weak self] in
                AccessibilityBridge.close(window: element)
                // Restore alpha in case the window survives (e.g. "Save?" dialog)
                let conn = CGSMainConnectionID()
                CGSSetWindowAlpha(conn, windowID, 1.0)
                self?.windowDestroyed(windowID: windowID)
            }
        } else {
            AccessibilityBridge.close(window: element)
        }
    }

    // MARK: - Config Reload

    private func reloadConfig() {
        if suppressNextReload {
            suppressNextReload = false
            panelessLog("Config reload suppressed (settings UI wrote the file)")
            return
        }
        let oldMode = config.tilingMode
        config = PanelessConfig.load()
        for engine in layoutEngines.values { engine.config = config }

        // Reset Niri state if mode changed
        if config.tilingMode != oldMode {
            // Unhide any Niri-hidden windows before clearing
            let conn = CGSMainConnectionID()
            for wid in niriHiddenWindows {
                CGSSetWindowAlpha(conn, wid, 1.0)
            }
            niriHiddenWindows.removeAll()
            layoutEngine.niriActiveColumn = 0
            layoutEngine.niriColumns.removeAll()
        }
        BorderManager.shared.config = config.border
        eventTap.keyBindings = config.keyBindings
        eventTap.hyperkeyCode = config.hyperkeyCode

        // Update focus-follows-mouse
        stopFocusFollowsMouse()
        if config.focusFollowsMouse {
            startFocusFollowsMouse()
        }

        // Update dimming
        if config.dimUnfocused <= 0 {
            restoreAllDimming()
        }

        // Update animations
        Animator.shared.enabled = config.animations
        Animator.shared.sizeOnce = config.sizeOnce
        Animator.shared.appDrivenAnimation = config.appDrivenAnimation

        // Update ProMotion forcing
        if config.forceProMotion {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }

        scanCurrentSpace()
        panelessLog("Config reloaded")
    }

    // MARK: - Tiling

    /// Lay out every screen. Each display carries its own layout, so this runs once per
    /// screen and the overlays are refreshed once at the end, with every screen's frames
    /// together: they are global, and updating them per screen would leave only the last
    /// screen's windows accounted for.
    func retile(animated: Bool = true) {
        var layouts: [(CGWindowID, CGRect)] = []
        for screen in NSScreen.screens {
            let monitorID = WorkspaceManager.shared.screenID(for: screen)
            layouts += retile(engine: engine(for: monitorID), animated: animated)
        }
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
    }

    /// Lay out one screen, and hand back the frames it placed.
    @discardableResult
    private func retile(engine: LayoutEngine, animated: Bool) -> [(CGWindowID, CGRect)] {
        if config.niriMode {
            return retileNiri(engine: engine, animated: animated)
        }

        let windows = engine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
            guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
            return (wid, el, t.pid)
        }

        let region = region(for: engine)

        // Native macOS compositor tiling: GPU-driven animation, no content redraw.
        // Only used when explicitly enabled, and it is incompatible with gaps.
        if config.nativeAnimation &&
           NativeTiling.canUseMenuTiling(count: windows.count, splitRatio: engine.splitRatio, variant: engine.layoutVariant) {
            let menuSuccess = NativeTiling.applyViaMenu(
                windows: windows,
                variant: engine.layoutVariant
            )

            if menuSuccess {
                // Restore focus to the originally focused window (applyViaMenu cycles focus)
                if let focusedID = focusedWindowID,
                   let element = axElements[focusedID],
                   let tracked = trackedWindows[focusedID] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    }
                }
            } else {
                panelessLog("retile: menu tiling failed, falling back to AX frames")
                NativeTiling.applyLayout(
                    windows: windows, region: region, gap: config.innerGap,
                    singleWindowPadding: config.singleWindowPadding,
                    splitRatio: engine.splitRatio, variant: engine.layoutVariant,
                    animate: animated
                )
            }
        } else {
            NativeTiling.applyLayout(
                windows: windows, region: region, gap: config.innerGap,
                singleWindowPadding: config.singleWindowPadding,
                splitRatio: engine.splitRatio, variant: engine.layoutVariant,
                animate: animated
            )
        }

        return engine.calculateFrames(in: region)
    }

    /// Retile with a scale-in effect for a newly created window.
    /// Avoids redundant AX getFrame calls by using calculated start frames directly.
    private func retileWithScaleIn(newWindowID: CGWindowID) {
        if config.niriMode {
            retileNiriWithScaleIn(newWindowID: newWindowID)
            return
        }

        let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
            guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
            return (wid, el, t.pid)
        }
        guard !windows.isEmpty else { return }

        let region = getTilingRegion()
        let targetFrames = NativeTiling.calculateFrames(
            count: windows.count, region: region, gap: config.innerGap,
            singleWindowPadding: config.singleWindowPadding,
            splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant
        )

        var transitions: [Animator.Transition] = []
        for (i, w) in windows.enumerated() where i < targetFrames.count {
            let target = targetFrames[i]

            let startFrame: CGRect
            let isNew: Bool
            if w.windowID == newWindowID {
                // Start where the window actually is. We cannot hide a window before
                // its first paint: the alpha pre-hide is a no-op on other processes'
                // windows, so the app's own placement is always visible for a moment.
                // Teleporting from there to a scaled copy of the target and animating
                // the rest reads as a jump. Gliding from where it already sits is one
                // continuous movement instead, which is the closest we get to a
                // compositor placing it before anyone sees it.
                //
                // Only fall back to the centred popin when the window has no readable
                // frame yet, where there is nothing to glide from.
                if let actual = AccessibilityBridge.getFrame(of: w.element),
                   AccessibilityBridge.isPlausibleFrame(actual) {
                    startFrame = actual
                } else {
                    let scale: CGFloat = 0.80
                    startFrame = CGRect(
                        x: target.midX - target.width * scale / 2,
                        y: target.midY - target.height * scale / 2,
                        width: target.width * scale,
                        height: target.height * scale
                    )
                }
                isNew = true
            } else {
                startFrame = AccessibilityBridge.getFrame(of: w.element) ?? target
                isNew = false
            }

            transitions.append(Animator.Transition(
                windowID: w.windowID, element: w.element,
                startFrame: startFrame, targetFrame: target,
                isNewWindow: isNew
            ))
        }

        if let t = transitions.first(where: { $0.isNewWindow }) {
            panelessLog(String(format: "New window %d: scale-in %.0f,%.0f %.0fx%.0f -> %.0f,%.0f %.0fx%.0f",
                t.windowID,
                t.startFrame.origin.x, t.startFrame.origin.y, t.startFrame.width, t.startFrame.height,
                t.targetFrame.origin.x, t.targetFrame.origin.y, t.targetFrame.width, t.targetFrame.height))
        }
        Animator.shared.animate(transitions)

        let layouts = layoutEngine.calculateFrames(in: region)
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
    }

    func getTilingRegion(for screen: NSScreen? = nil) -> TilingRegion {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = screen else {
            return TilingRegion(x: 0, y: 0, width: 1920, height: 1080)
        }

        let visibleFrame = screen.visibleFrame
        let gap = config.outerGap
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axY = primaryHeight - visibleFrame.origin.y - visibleFrame.size.height

        return TilingRegion(
            x: visibleFrame.origin.x + gap,
            y: axY + gap,
            width: visibleFrame.size.width - gap * 2,
            height: visibleFrame.size.height - gap * 2
        )
    }

    // MARK: - Border Updates

    private func updateBorders(layouts: [(CGWindowID, CGRect)]) {
        guard config.border.enabled else { return }

        let focusedID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        if let fid = focusedID, let layout = layouts.first(where: { $0.0 == fid }) {
            BorderManager.shared.updateFocus(windowID: fid, frame: layout.1)
        } else {
            BorderManager.shared.updateFocus(windowID: nil, frame: nil)
        }
    }

    // MARK: - Window Scanning

    func scanCurrentSpace() {
        layoutEngine.tiledWindows.removeAll()
        trackedWindows.removeAll()
        axElements.removeAll()
        floatingWindows.removeAll()
        fullscreenWindows.removeAll()
        stickyWindows.removeAll()

        let allWindowIDs = SpaceManager.getWindowsOnCurrentSpace()
        let hiddenIDs = WorkspaceManager.shared.allHiddenWindowIDs()
        let windowIDs = allWindowIDs.filter { !hiddenIDs.contains($0) }
        // Known windows = active workspace windows + hidden windows (so hidden aren't re-discovered)
        var allKnown = Set(allWindowIDs)
        allKnown.formUnion(hiddenIDs)
        observer.syncKnownWindows(allKnown)

        for windowID in windowIDs {
            guard let info = SpaceManager.getWindowInfo(windowID) else { continue }
            guard !appMatchesRule(info.appName, bundleID: info.bundleID, rules: config.excludeApps) else { continue }

            var shouldFloat = appMatchesRule(info.appName, bundleID: info.bundleID, rules: config.floatApps)

            let tracked = TrackedWindow(
                windowID: windowID,
                pid: info.pid,
                appName: info.appName,
                bundleID: info.bundleID,
                isFloating: shouldFloat,
                frame: info.frame
            )
            trackedWindows[windowID] = tracked

            for (element, wid) in AccessibilityBridge.getWindows(for: info.pid) {
                if wid == windowID {
                    axElements[windowID] = element
                    break
                }
            }

            // Auto-float dialogs and small windows
            if !shouldFloat, config.autoFloatDialogs, let element = axElements[windowID] {
                if AccessibilityBridge.isDialog(element) || AccessibilityBridge.isSmallWindow(element) {
                    shouldFloat = true
                }
            }

            // Mark as sticky if app matches sticky rules
            if appMatchesRule(info.appName, bundleID: info.bundleID, rules: config.stickyApps) {
                stickyWindows.insert(windowID)
            }

            if shouldFloat {
                floatingWindows.insert(windowID)
            } else if axElements[windowID] != nil {
                engine(forWindow: windowID).insert(windowID: windowID, afterFocused: nil)
            } else {
                trackedWindows.removeValue(forKey: windowID)
            }
        }

        focusedWindowID = AccessibilityBridge.getFocusedWindowID()

        // In Niri mode, rebuild columns from the flat tiled window list
        if config.niriMode {
            layoutEngine.rebuildColumnsFromTiledWindows()
        }

        retile()
    }

    // MARK: - WindowObserverDelegate

    /// Restore window alpha that was pre-emptively set to 0 by the AX observer.
    /// Called for windows that won't be animated (floating, excluded, etc.).
    private func restoreWindowAlpha(_ windowID: CGWindowID) {
        let conn = CGSMainConnectionID()
        CGSSetWindowAlpha(conn, windowID, 1.0)
    }

    func windowCreated(windowID: CGWindowID, pid: pid_t, appName: String) -> Bool {
        panelessLog("New window \(windowID) (\(appName)) seen by Paneless")
        guard trackedWindows[windowID] == nil else {
            restoreWindowAlpha(windowID)
            return true
        }
        // Skip windows hidden on other virtual workspaces
        guard !WorkspaceManager.shared.isWindowHiddenOnOtherWorkspace(windowID) else {
            restoreWindowAlpha(windowID)
            return true
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard !appMatchesRule(appName, bundleID: bundleID, rules: config.excludeApps) else {
            restoreWindowAlpha(windowID)
            return true
        }

        var shouldFloat = appMatchesRule(appName, bundleID: bundleID, rules: config.floatApps)

        let tracked = TrackedWindow(
            windowID: windowID,
            pid: pid,
            appName: appName,
            bundleID: bundleID,
            isFloating: shouldFloat
        )
        trackedWindows[windowID] = tracked

        // No element means no way to move the window, so nothing below can work. Say so
        // rather than writing the window off: an app that has just launched often has no
        // accessibility tree yet at the instant its window appears, and Preview opened
        // from a Mail attachment sat unmanaged for exactly that reason. The observer
        // offers the window again shortly.
        guard let element = AccessibilityBridge.windowElement(for: windowID, pid: pid) else {
            trackedWindows.removeValue(forKey: windowID)
            restoreWindowAlpha(windowID)
            return false
        }
        axElements[windowID] = element

        // Park it the moment we can address it, before any of the classification below.
        // Everything after this point costs AX round trips to an app that may be slow,
        // measured at about 161ms, and until the window is out of sight the user is
        // watching it sit wherever the app happened to put it. That wait is the ghost.
        // A window we have tiled before is tiled again, whatever it looks like now.
        // Cmd+H, a native minimise or a spell in a fullscreen Space takes a window off
        // the screen list and brings it back as new, and one returning from a half or
        // third tile always looks like a small secondary window.
        let tiledBefore = onceTiled.contains(windowID)

        // Auto-float dialogs and small windows
        if !shouldFloat, !tiledBefore, config.autoFloatDialogs, let element = axElements[windowID] {
            if AccessibilityBridge.isDialog(element) || AccessibilityBridge.isSmallWindow(element) {
                shouldFloat = true
                panelessLog("Auto-floating dialog/small window: \(appName) (\(windowID))")
            }
        }

        // Auto-float secondary windows from apps that already have a tiled window.
        // Catches: settings panels, popups, tab pickers, address bar suggestions, etc.
        // Judged on size alone. This runs a few milliseconds after the window appears,
        // before a terminal's shell has named it, so an empty title says nothing, and
        // the popups this is for are small anyway.
        if !shouldFloat, !tiledBefore, let element = axElements[windowID] {
            let appAlreadyTiled = layoutEngine.tiledWindows.contains { tid in
                trackedWindows[tid]?.pid == pid
            }
            if appAlreadyTiled, let frame = AccessibilityBridge.getFrame(of: element) {
                let region = getTilingRegion()
                if frame.width < region.width * 0.7 || frame.height < region.height * 0.7 {
                    shouldFloat = true
                    panelessLog("Auto-floating secondary window from \(appName) (\(windowID))")
                }
            }
        }

        // Mark as sticky if app matches sticky rules
        if appMatchesRule(appName, bundleID: bundleID, rules: config.stickyApps) {
            stickyWindows.insert(windowID)
        }

        // Per-app workspace assignment: auto-move to specified workspace
        let targetWorkspace = config.appWorkspaceRules[appName]
            ?? (bundleID.flatMap { config.appWorkspaceRules[$0] })
        if let target = targetWorkspace {
            let screen = NSScreen.safeMain
            let monitorID = WorkspaceManager.shared.screenID(for: screen)
            let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
            if target != currentWS {
                panelessLog("New window \(windowID) (\(appName)): app rule sends it to workspace \(target), parking it")
                // Move directly to target workspace without showing on current
                let screenFrame = screenFrameInAX(for: screen)
                if let element = axElements[windowID] {
                    WorkspaceManager.shared.hideWindow(windowID, element: element, screenFrame: screenFrame)
                }

                var targetWS = WorkspaceManager.shared.workspaces[monitorID]?[target] ?? VirtualWorkspace()
                targetWS.trackedWindows[windowID] = tracked
                if let element = axElements[windowID] {
                    targetWS.axElements[windowID] = element
                }
                if shouldFloat {
                    targetWS.floatingWindows.insert(windowID)
                } else {
                    targetWS.tiledWindows.append(windowID)
                }
                WorkspaceManager.shared.workspaces[monitorID, default: [:]][target] = targetWS

                // Remove from current workspace tracking
                trackedWindows.removeValue(forKey: windowID)
                axElements.removeValue(forKey: windowID)

                // Update observer to know about this hidden window
                var known = observer.currentKnownWindows
                known.insert(windowID)
                observer.syncKnownWindows(known)

                panelessLog("Auto-moved \(appName) (\(windowID)) to workspace \(target)")
                return true
            }
        }

        // Window swallowing: check if this new window's process is a child of a tiled terminal
        if !shouldFloat, axElements[windowID] != nil,
           let terminalWID = findSwallowableParent(childPID: pid) {
            // Record swallow relationship
            swallowedWindows[windowID] = terminalWID
            trackedWindows[windowID]?.swallowedFrom = terminalWID
            trackedWindows[terminalWID]?.swallowedBy = windowID

            // Find terminal's position in layout
            let terminalIndex = layoutEngine.tiledWindows.firstIndex(of: terminalWID)

            // Hide the terminal window
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, terminalWID, 0.0)
            let screen = NSScreen.safeMain
            let screenFrame = screenFrameInAX(for: screen)
            if let termElement = axElements[terminalWID] {
                WorkspaceManager.shared.hideWindow(terminalWID, element: termElement, screenFrame: screenFrame)
            }

            // Remove terminal from tiling (but keep in trackedWindows)
            if config.niriMode {
                layoutEngine.removeWindowFromColumns(terminalWID)
            }
            layoutEngine.remove(windowID: terminalWID)

            // Insert new window at the terminal's old position
            if let idx = terminalIndex {
                layoutEngine.tiledWindows.insert(windowID, at: min(idx, layoutEngine.tiledWindows.count))
            } else {
                layoutEngine.insert(windowID: windowID, afterFocused: focusedWindowID)
            }

            if config.niriMode {
                layoutEngine.insertWindowAsNewColumn(windowID)
                if let ci = layoutEngine.niriColumns.firstIndex(where: { $0.windows.contains(windowID) }) {
                    layoutEngine.niriActiveColumn = ci
                }
            }

            focusedWindowID = windowID
            CGSSetWindowAlpha(conn, windowID, 0.0)
            retileWithScaleIn(newWindowID: windowID)

            panelessLog("Swallowed \(trackedWindows[terminalWID]?.appName ?? "terminal") (\(terminalWID)) → \(appName) (\(windowID))")
            return true
        }

        if shouldFloat {
            floatingWindows.insert(windowID)
            restoreWindowAlpha(windowID)
        } else {
            // The window joins the layout of the display it opened on. It used to join
            // whichever display had the keyboard, so a window appearing on the second
            // screen was tiled into the first one's row and dragged across to reach it.
            let target = engine(forWindow: windowID)
            target.insert(windowID: windowID, afterFocused: focusedWindowID)

            // Apply per-app layout rules (e.g. "Arc = left" puts Arc at index 0)
            let ruleKey = config.appLayoutRules[appName]
                ?? (bundleID.flatMap { config.appLayoutRules[$0] })
            if let rule = ruleKey {
                switch rule {
                case "left":
                    target.tiledWindows.removeAll { $0 == windowID }
                    target.tiledWindows.insert(windowID, at: 0)
                case "right":
                    target.tiledWindows.removeAll { $0 == windowID }
                    target.tiledWindows.append(windowID)
                default: break
                }
            }

            // macOS gives focus to newly created windows, so update our tracking
            // to match. This ensures dim overlays and borders reflect actual focus.
            focusedWindowID = windowID

            // In Niri mode, insert as new column and scroll to it
            if config.niriMode {
                target.insertWindowAsNewColumn(windowID)
                if let idx = target.niriColumns.firstIndex(where: { $0.windows.contains(windowID) }) {
                    target.niriActiveColumn = idx
                }
            }

            // Immediately hide the new window so the user never sees it at the
            // app's default position. The Animator will fade it in at the correct
            // tiled position with the Hyprland popin effect.
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, windowID, 0.0)

            retileWithScaleIn(newWindowID: windowID)
        }
        return true
    }

    /// Put back any parked window that has strayed onto the screen.
    ///
    /// A park is one write into another process with no read-back. The app may be busy
    /// and time out, it may move its own window later, and macOS relocates anything it
    /// considers off-screen after a display change. None of that was noticed, and the
    /// window then sat in plain view behind whatever was raised last, on a workspace it
    /// did not belong to. The poll already has every window's frame, so check the parked
    /// ones against it and park again as needed. Three failures in a row means the app
    /// will not take the position; stop asking rather than write to it forever.
    func windowsPolled(frames: [CGWindowID: CGRect]) {
        let wsMgr = WorkspaceManager.shared
        for (monitorID, monitorWorkspaces) in wsMgr.workspaces {
            let active = wsMgr.activeWorkspace[monitorID] ?? 1
            guard let screen = screen(for: monitorID) else { continue }
            let screenFrame = screenFrameInAX(for: screen)
            for (number, ws) in monitorWorkspaces where number != active {
                for (wid, element) in ws.axElements {
                    guard !stickyWindows.contains(wid), let frame = frames[wid] else { continue }
                    if wsMgr.isHiddenPosition(screenFrame: screenFrame, windowFrame: frame) {
                        reparkFailures.removeValue(forKey: wid)
                        continue
                    }
                    let failures = reparkFailures[wid, default: 0]
                    guard failures < 3 else { continue }
                    reparkFailures[wid] = failures + 1
                    wsMgr.hideWindow(wid, element: element, screenFrame: screenFrame)
                    let name = ws.trackedWindows[wid]?.appName ?? "?"
                    panelessLog("Window \(wid) (\(name)) had strayed from workspace \(number)'s parking corner, parked it again")
                }
            }
        }

        measureNiriMinWidths(frames: frames)
    }

    /// Learn which niri windows refuse to be as narrow as their column, so the column
    /// can widen to fit them. macOS does not report a window's minimum width, so it is
    /// measured: lay the strip out, then see which windows came back wider than the share
    /// we gave them. Skip while an animation or a divider drag is in flight, when a width
    /// read would be mid-move.
    ///
    /// Only ever grows the recorded width, and records the window's own rendered width,
    /// which the window then accepts unchanged, so it settles after one retile. A clear
    /// or shrink path here would fight a terminal that rounds its width down to a
    /// character cell: give it back the space, it snaps narrow again, and the column
    /// jitters on every poll. A window that no longer needs the width just keeps a
    /// slightly wide column until it closes, which nobody notices.
    private func measureNiriMinWidths(frames: [CGWindowID: CGRect]) {
        guard config.niriMode, !Animator.shared.isAnimating, !isResizing,
              !layoutEngine.niriColumns.isEmpty else { return }

        let region = getTilingRegion()
        var offset = layoutEngine.niriScrollOffset
        let allocated = NativeTiling.calculateNiriFrames(
            columns: layoutEngine.niriColumns, region: region, gap: config.innerGap,
            activeColumn: layoutEngine.niriActiveColumn,
            defaultColumnWidth: config.niriColumnWidth,
            minColumnWidth: config.niriMinColumnWidth, stackMode: config.niriColumnStack,
            scrollOffset: layoutEngine.niriScrollOffset, fillScreen: config.niriFillScreen,
            minWidthByWindow: niriMinWidth, resultingScrollOffset: &offset)

        let tolerance: CGFloat = 4
        var changed = false
        for colResult in allocated where colResult.isVisible {
            for (wid, allocFrame) in colResult.windowFrames {
                guard let actual = frames[wid] else { continue }
                if actual.width > allocFrame.width + tolerance,
                   (niriMinWidth[wid] ?? 0) < actual.width - tolerance {
                    niriMinWidth[wid] = actual.width
                    changed = true
                }
            }
        }
        if changed { retile() }
    }

    /// An AX element somewhere died. If it is one of the windows we track, tear it
    /// down now rather than waiting for the poll to notice. The poll runs every 3s
    /// once idle, which is far too late for anything keyed off `lastWindowDestroyedAt`.
    func axElementDestroyed(element: AXUIElement) {
        guard let windowID = axElements.first(where: { CFEqual($0.value, element) })?.key else { return }
        windowDestroyed(windowID: windowID)
    }

    func windowDestroyed(windowID: CGWindowID) {
        guard trackedWindows[windowID] != nil else {
            // Not on the live workspace. Hidden with Cmd+H, minimised or away on another
            // native Space it still exists and keeps its place. Really gone, it must leave
            // the workspace that lists it, or that workspace keeps a slot for a window
            // that no longer exists.
            guard SpaceManager.getWindowInfo(windowID) == nil else { return }
            forgetParked(windowID)
            return
        }

        panelessLog("Window destroyed: \(windowID)")
        lastWindowDestroyedAt = Date()
        if engineHolding(windowID) != nil { onceTiled.insert(windowID) }

        // Last known rect of the window that is going away, so focus can follow the
        // position rather than snapping to the top left.
        let vacatedFrame = trackedWindows[windowID]?.frame

        // Clean up minimized state
        minimizedWindows.remove(windowID)
        niriHiddenWindows.remove(windowID)

        // Clean up any marks pointing to this window
        windowMarks = windowMarks.filter { $0.value != windowID }

        let destroyedPid = trackedWindows[windowID]?.pid

        // Window swallowing: if this window swallowed a terminal, restore it
        if let terminalWID = swallowedWindows.removeValue(forKey: windowID) {
            if trackedWindows[terminalWID] != nil {
                // Find the destroyed window's position in the layout
                let owner = engineHolding(windowID) ?? layoutEngine
                let destroyedIndex = owner.tiledWindows.firstIndex(of: windowID)

                // Remove the GUI window from layout first
                if config.niriMode {
                    owner.removeWindowFromColumns(windowID)
                }
                owner.remove(windowID: windowID)

                // Clean up the destroyed window
                trackedWindows.removeValue(forKey: windowID)
                axElements.removeValue(forKey: windowID)
                floatingWindows.remove(windowID)
                fullscreenWindows.remove(windowID)
                stickyWindows.remove(windowID)

                restoreSwallowedTerminal(terminalWID, at: destroyedIndex, in: owner)

                retile()
                panelessLog("Unswallowed terminal (\(terminalWID)), restored to layout")

                let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
                updateBorders(layouts: layouts)
                updateDimming(layouts: layouts)
                return
            }
            // The terminal is parked on another workspace, so it gets its place back
            // there, and this window closes here like any other.
            WorkspaceManager.shared.releaseSwallowed(terminalWID)
            panelessLog("Unswallowed terminal (\(terminalWID)) on its own workspace")
        }

        // If this window WAS a swallowed terminal (but the child outlived it), clean up
        if let swallowedBy = trackedWindows[windowID]?.swallowedBy {
            swallowedWindows.removeValue(forKey: swallowedBy)
            trackedWindows[swallowedBy]?.swallowedFrom = nil
        }

        trackedWindows.removeValue(forKey: windowID)
        axElements.removeValue(forKey: windowID)
        floatingWindows.remove(windowID)
        fullscreenWindows.remove(windowID)
        stickyWindows.remove(windowID)
        niriMinWidth.removeValue(forKey: windowID)
        if dimmedWindows.remove(windowID) != nil {
            var wids: [CGWindowID] = [windowID]
            var values: [Float] = [0.0]
            CGSSetWindowListBrightness(CGSMainConnectionID(), &wids, &values, 1)
        }

        // Ask whether this window was tiled BEFORE touching the columns.
        //
        // removeWindowFromColumns syncs the flat window list as a side effect, so asking
        // afterwards always said no in niri mode. Everything below is gated on this
        // answer, so in niri mode a closing window neither retiled nor moved focus: the
        // column vanished but the ones after it kept their old positions, leaving a hole
        // in the strip that stayed until something else forced a retile.
        // A window can be destroyed while the keyboard is on another display, so take it
        // out of the layout that is actually holding it, not the one in front of us. Left
        // in the other screen's list it would keep a place in that layout for a window
        // that no longer exists.
        let owner = engineHolding(windowID) ?? layoutEngine
        let wasTiled = owner.contains(windowID)

        if config.niriMode {
            owner.removeWindowFromColumns(windowID)
        }
        if wasTiled {
            owner.remove(windowID: windowID)
        }

        // Always try to focus a remaining tiled window after a tiled window is destroyed.
        // macOS may keep focus on the app that owned the closed window
        // (e.g. Ghostty/Arc with windows on other spaces), even if the destroyed
        // window wasn't tracked as focusedWindowID (Cmd+W bypass).
        if wasTiled {
            // Choose the new focus BEFORE retiling, not after.
            //
            // Moving a window to another workspace already did it in this order and
            // animates cleanly; closing did it the other way round and did not. Focusing
            // a window mid-animation makes macOS raise and nudge it, which landed as a
            // single 265px lurch in the middle of an otherwise even sequence of ~50px
            // steps: the hop you see before the animation appears to start.
            // Check if current focus is still on the destroyed window's app
            // and that app has no more tiled windows on this space.
            let appStillTiled = layoutEngine.tiledWindows.contains { tid in
                trackedWindows[tid]?.pid == destroyedPid
            }

            let shouldRefocus = focusedWindowID == windowID
                || focusedWindowID == nil
                || !appStillTiled

            if shouldRefocus {
                let heir = vacatedFrame.flatMap { windowTakingOver(vacated: $0) }
                    ?? layoutEngine.tiledWindows.first
                if let heirID = heir,
                   let element = axElements[heirID], let tracked = trackedWindows[heirID] {
                    AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    focusedWindowID = heirID
                } else if layoutEngine.tiledWindows.isEmpty && floatingWindows.isEmpty {
                    // No windows left on this workspace — focus Finder/desktop.
                    // Suppress focus-follows-app so activating Finder doesn't
                    // pull us to another workspace.
                    isAutoSwitching = true
                    focusDesktop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.isAutoSwitching = false
                    }
                }
            }

            // Now, and only now, move everything. One pass, nothing interrupting it.
            retile()

            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)
        }
    }

    /// A window that closed while parked on another workspace.
    private func forgetParked(_ windowID: CGWindowID) {
        if let terminalWID = swallowedWindows.removeValue(forKey: windowID) {
            WorkspaceManager.shared.releaseSwallowed(terminalWID)
        }
        niriMinWidth.removeValue(forKey: windowID)
        WorkspaceManager.shared.forget(windowID)
        panelessLog("Window \(windowID) closed while parked, dropped from its workspace")
    }

    /// Put a swallowed terminal back into a layout, where the window that swallowed it
    /// used to be, and hand it focus.
    private func restoreSwallowedTerminal(_ terminalWID: CGWindowID, at index: Int?, in engine: LayoutEngine) {
        trackedWindows[terminalWID]?.swallowedBy = nil

        // Unhide the terminal
        let conn = CGSMainConnectionID()
        CGSSetWindowAlpha(conn, terminalWID, 1.0)

        // Re-insert terminal into layout at the GUI window's old position
        if let idx = index {
            engine.tiledWindows.insert(terminalWID, at: min(idx, engine.tiledWindows.count))
        } else {
            engine.tiledWindows.append(terminalWID)
        }

        if config.niriMode {
            engine.insertWindowAsNewColumn(terminalWID)
            if let ci = engine.niriColumns.firstIndex(where: { $0.windows.contains(terminalWID) }) {
                engine.niriActiveColumn = ci
            }
        }

        // Focus the restored terminal
        if let element = axElements[terminalWID], let tracked = trackedWindows[terminalWID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = terminalWID
        }
    }

    func spaceChanged() {
        // With virtual workspaces, native space changes are a no-op.
        // All workspace switching is handled by switchVirtualWorkspace().
        panelessLog("Native space change detected (ignored — using virtual workspaces)")
    }

    func focusChanged() {
        guard let newFocusedID = AccessibilityBridge.getFocusedWindowID(),
              newFocusedID != focusedWindowID,
              trackedWindows[newFocusedID] != nil
        else { return }
        applyFocusChange(newFocusedID)
    }

    func focusChanged(windowID: CGWindowID) {
        guard windowID != focusedWindowID,
              trackedWindows[windowID] != nil
        else {
            // Fallback: the notification element might be an app ref, not a window.
            // Try the old NSWorkspace path.
            focusChanged()
            return
        }
        applyFocusChange(windowID)
    }

    private func applyFocusChange(_ newFocusedID: CGWindowID) {
        focusedWindowID = newFocusedID

        // Update column's focusedIndex when external focus changes
        if config.niriMode {
            if let (ci, ri) = layoutEngine.findWindowInColumns(newFocusedID) {
                layoutEngine.niriColumns[ci].focusedIndex = ri
                layoutEngine.niriActiveColumn = ci
            }
        }

        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)

        onFocusChange?()
    }

    func applicationLaunched(pid: pid_t, name: String) {}

    func applicationActivated(pid: pid_t, name: String) {
        guard config.focusFollowsApp, !isAutoSwitching else { return }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1

        // Check if the activated app has windows on the current workspace
        let hasWindowOnCurrent = trackedWindows.values.contains { $0.pid == pid }
        if hasWindowOnCurrent { return }

        // Don't summon right after a workspace switch. macOS momentarily re-activates
        // the previous workspace's app, which would otherwise be pulled here and steal focus.
        if Date().timeIntervalSince(lastWorkspaceSwitchAt) < 0.5 {
            return
        }

        // Only a parked window is worth waiting on.
        guard let monitorWorkspaces = WorkspaceManager.shared.workspaces[monitorID] else { return }
        let hasWindowElsewhere = monitorWorkspaces.contains { wsNum, ws in
            wsNum != currentWS && ws.trackedWindows.values.contains { $0.pid == pid }
        }
        guard hasWindowElsewhere else { return }

        // Closing a window makes macOS activate the next app in z-order, and that
        // activation reaches us BEFORE the window's death does: measured at 171ms
        // ahead of it. So at this instant there is nothing to distinguish a user
        // asking for this app from macOS handing it over after a close, and no
        // synchronous check can tell them apart because the truth has not arrived
        // yet. Let the teardown land, then decide.
        pendingSummon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingSummon = nil
            self.completeSummon(pid: pid, name: name, monitorID: monitorID, workspace: currentWS)
        }
        pendingSummon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + summonSettleDelay, execute: work)
    }

    /// Second half of focus-follows-app, run once any window teardown that could have
    /// caused the activation has had time to reach us.
    private func completeSummon(pid: pid_t, name: String, monitorID: String, workspace: Int) {
        // A window died around this activation, so macOS handed us this app after a
        // close rather than the user asking for it. Summoning now would drag a window
        // out of the workspace it belongs to, which is the thing we must never do.
        // The window covers a destroy landing either side of the activation.
        if Date().timeIntervalSince(lastWindowDestroyedAt) < summonSettleDelay + 0.2 {
            panelessLog("Focus-follows-app: suppressed (window closed around activation)")
            return
        }

        // The world may have moved while we waited, so re-establish every precondition.
        guard config.focusFollowsApp, !isAutoSwitching else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }

        let nowMonitor = WorkspaceManager.shared.screenID(for: NSScreen.safeMain)
        guard nowMonitor == monitorID,
              (WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1) == workspace else { return }
        if trackedWindows.values.contains(where: { $0.pid == pid }) { return }

        guard let monitorWorkspaces = WorkspaceManager.shared.workspaces[monitorID] else { return }
        let stillParked = monitorWorkspaces.contains { wsNum, ws in
            wsNum != workspace && ws.trackedWindows.values.contains { $0.pid == pid }
        }
        guard stillParked else { return }

        panelessLog("Focus-follows-app: summoning \(name) (pid \(pid)) to workspace \(workspace)")
        isAutoSwitching = true
        summonAppWindowsToCurrentWorkspace(pid: pid)
        isAutoSwitching = false
    }

    /// Pull every window belonging to `pid` that is parked on another workspace of the
    /// current monitor onto the current (active) workspace, un-parking it. This is the
    /// mirror of `moveToVirtualWorkspace`: stored workspace state -> live set.
    private func summonAppWindowsToCurrentWorkspace(pid: pid_t) {
        let wsMgr = WorkspaceManager.shared
        let screen = NSScreen.safeMain
        let monitorID = wsMgr.screenID(for: screen)
        let currentWS = wsMgr.activeWorkspace[monitorID] ?? 1
        let screenFrame = screenFrameInAX(for: screen)
        guard let monitorWorkspaces = wsMgr.workspaces[monitorID] else { return }

        var summoned: [CGWindowID] = []
        var lastSummoned: CGWindowID?

        for (wsNum, var ws) in monitorWorkspaces where wsNum != currentWS {
            let matches = ws.trackedWindows.filter { $0.value.pid == pid }.map { $0.key }
            guard !matches.isEmpty else { continue }

            for wid in matches {
                guard !stickyWindows.contains(wid) else { continue }

                let tracked = ws.trackedWindows.removeValue(forKey: wid)
                let element = ws.axElements.removeValue(forKey: wid)
                let wasFloating = ws.floatingWindows.remove(wid) != nil
                let wasFullscreen = ws.fullscreenWindows.remove(wid) != nil
                ws.tiledWindows.removeAll { $0 == wid }

                // Add to the live (current) workspace
                if let tracked = tracked { trackedWindows[wid] = tracked }
                if let element = element { axElements[wid] = element }

                if wasFloating || wasFullscreen {
                    if wasFloating { floatingWindows.insert(wid) }
                    if wasFullscreen { fullscreenWindows.insert(wid) }
                    // Un-park: place visibly on the current screen. Keep the saved frame
                    // if it lands inside this screen, otherwise center it.
                    if let element = element {
                        let saved = tracked?.frame ?? .zero
                        let target = screenFrame.contains(CGPoint(x: saved.midX, y: saved.midY)) && saved.width > 1
                            ? saved
                            : centeredFrame(for: saved.size, in: screenFrame)
                        AccessibilityBridge.setFrame(of: element, to: target)
                        trackedWindows[wid]?.frame = target
                    }
                } else {
                    layoutEngine.insert(windowID: wid, afterFocused: focusedWindowID)
                }

                summoned.append(wid)
                lastSummoned = wid
            }

            wsMgr.workspaces[monitorID]?[wsNum] = ws
        }

        guard !summoned.isEmpty else { return }

        retile()
        restoreFloatingWindowPositions()

        if let target = lastSummoned, let el = axElements[target], let t = trackedWindows[target] {
            AccessibilityBridge.focus(window: el, pid: t.pid)
            focusedWindowID = target
        }

        // Persist the new assignments and refresh the active workspace snapshot.
        saveWorkspaceState(workspace: currentWS, monitor: monitorID)
        onSpaceChange?()
        panelessLog("Summoned \(summoned.count) window(s) to workspace \(currentWS)")
    }

    /// A frame of `size` centered within `region` (AX coordinates).
    private func centeredFrame(for size: CGSize, in region: CGRect) -> CGRect {
        let w = size.width > 1 ? min(size.width, region.width) : region.width * 0.6
        let h = size.height > 1 ? min(size.height, region.height) : region.height * 0.6
        return CGRect(
            x: region.midX - w / 2,
            y: region.midY - h / 2,
            width: w,
            height: h
        )
    }

    func applicationTerminated(pid: pid_t, name: String) {
        let toRemove = trackedWindows.filter { $0.value.pid == pid }.map { $0.key }
        for windowID in toRemove {
            windowDestroyed(windowID: windowID)
        }
        // Its parked windows went with it.
        for windowID in WorkspaceManager.shared.windows(ofPid: pid) {
            forgetParked(windowID)
        }
    }

    // MARK: - Cycle Layout

    private func cycleLayout() {
        if config.niriMode {
            // Cycle column width presets: 1.0 → 0.5 → 0.333
            // The same three niri cycles: a third, a half, two thirds. Full width is
            // deliberately not among them, since a strip with one column visible is not
            // a strip.
            let presets: [CGFloat] = [1.0/3.0, 0.5, 2.0/3.0]
            let current = config.niriColumnWidth
            // Find the next preset after the current width
            let nextIdx = presets.firstIndex(where: { abs($0 - current) < 0.01 }).map { ($0 + 1) % presets.count } ?? 0
            config.niriColumnWidth = presets[nextIdx]
            // Clear per-column overrides so the new default takes effect
            for i in layoutEngine.niriColumns.indices {
                layoutEngine.niriColumns[i].widthOverride = nil
            }
            let names = ["full", "half", "third"]
            panelessLog("Niri column width: \(names[nextIdx])")
            retile()
            return
        }

        layoutEngine.cycleVariant()
        let names = ["side-by-side", "stacked", "monocle"]
        panelessLog("Layout: \(names[layoutEngine.layoutVariant])")

        // Save layout variant for this workspace
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        workspaceLayouts["\(monitorID)-\(currentWS)"] = layoutEngine.layoutVariant

        retile()
    }

    // MARK: - Gap Resize

    private func adjustGap(by delta: CGFloat) {
        config.innerGap = max(0, config.innerGap + delta)
        config.outerGap = max(0, config.outerGap + delta)
        panelessLog("Gaps: inner=\(config.innerGap) outer=\(config.outerGap)")
        retile()
    }

    // MARK: - Split Ratio

    private func adjustSplitRatio(by delta: CGFloat) {
        if config.niriMode {
            // Adjust active column's width override
            guard !layoutEngine.niriColumns.isEmpty else { return }
            let idx = max(0, min(layoutEngine.niriActiveColumn, layoutEngine.niriColumns.count - 1))
            // Start from the width the column is actually drawn at. Seeding from the
            // configured fraction ignored the fill-screen widening and the floor, so on a
            // laptop the first grow made a column narrower and the first shrink dropped it
            // by a few hundred points.
            let drawn = NativeTiling.defaultColumnFraction(
                columnCount: layoutEngine.niriColumns.count, region: getTilingRegion(),
                configured: config.niriColumnWidth, minColumnWidth: config.niriMinColumnWidth,
                fillScreen: config.niriFillScreen)
            let current = layoutEngine.niriColumns[idx].widthOverride ?? drawn
            layoutEngine.niriColumns[idx].widthOverride = max(0.1, min(3.0, current + delta))
            panelessLog("Niri column \(idx) width: \(layoutEngine.niriColumns[idx].widthOverride!)")
            retile()
            return
        }

        layoutEngine.splitRatio = max(0.2, min(0.8, layoutEngine.splitRatio + delta))
        panelessLog("Split ratio: \(layoutEngine.splitRatio)")
        retile()
    }

    // MARK: - Niri Scrolling Column Mode

    /// Core Niri retile: calculate column frames, animate visible windows, hide off-screen ones.
    /// Move a window to its parked spot without paying for a size write.
    ///
    /// Parking went through the full setFrame, which writes the size twice, on either
    /// side of the position, to satisfy applications that clamp one against the other. A
    /// window being parked almost always keeps the size it already had, so both writes
    /// buy nothing, and our own measurements put a size write at 25 to 53 milliseconds on
    /// Safari against 0.2 to 2 for a move. Reading the frame first costs a fraction of
    /// that and skips the expensive half whenever it cannot change anything.
    private func park(_ element: AXUIElement, at frame: CGRect) {
        let current = AccessibilityBridge.getFrame(of: element)
        let sameSize = current.map {
            abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2
        } ?? false
        if sameSize {
            AccessibilityBridge.setFrameDuringAnimation(of: element, to: frame, setSize: false)
        } else {
            AccessibilityBridge.setFrame(of: element, to: frame)
        }
    }

    /// Where a column goes when it is not on screen.
    ///
    /// Parking against the tiling region left the window inside the outer gap, so a
    /// strip of it stayed in view and read as a narrower gap beside the last visible
    /// window. macOS will not let a window leave the display altogether, so the most
    /// that can be hidden is everything but the single pixel it keeps reachable.
    private func niriParkedFrame(_ frame: CGRect, region: TilingRegion) -> CGRect {
        let screen = NSScreen.main.map { screenFrameInAX(for: $0) }
            ?? CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        // Leaving on the left needs two pixels of margin rather than one. The width an
        // app accepts is rounded down, so one pixel can leave the window a fraction short
        // of the edge, and macOS reads that as entirely off screen and snaps it back to
        // where forty pixels still show. Going off the right edge has no such problem:
        // the window extends away from the screen, so its origin alone decides.
        let parkedX = frame.midX < region.x + region.width / 2
            ? screen.minX - frame.width + 2
            : screen.maxX - 1
        return CGRect(x: parkedX, y: frame.origin.y, width: frame.width, height: frame.height)
    }

    @discardableResult
    private func retileNiri(engine: LayoutEngine, animated: Bool = true) -> [(CGWindowID, CGRect)] {
        // Keep the columns in step with the window list before placing anything.
        // A window can be in the list while no column knows about it: turning niri mode
        // on does that to every workspace at once, and moving a window in from another
        // workspace does it to one. Either way the window is never placed and stays
        // parked off-screen, which looks like it has vanished.
        engine.reconcileColumns()

        let region = region(for: engine)
        let results = NativeTiling.calculateNiriFrames(
            columns: engine.niriColumns,
            region: region,
            gap: config.innerGap,
            activeColumn: engine.niriActiveColumn,
            defaultColumnWidth: config.niriColumnWidth,
            minColumnWidth: config.niriMinColumnWidth,
            stackMode: config.niriColumnStack,
            scrollOffset: engine.niriScrollOffset,
            fillScreen: config.niriFillScreen,
            minWidthByWindow: niriMinWidth,
            resultingScrollOffset: &engine.niriScrollOffset
        )

        // Park what is not on screen just past the edge it belongs to. These used to sit
        // at their true position in the strip, which is why a column that only just
        // missed the edge stayed in plain sight under the neighbouring window: nothing
        // was covering it, because window alpha does not cross process boundaries.
        //
        // A window that was on screen a moment ago slides out to the parked spot instead
        // of vanishing where it stood.
        var transitions: [Animator.Transition] = []
        for colResult in results where !colResult.isVisible {
            for (wid, frame) in colResult.windowFrames {
                guard let element = axElements[wid] else { continue }
                let parked = niriParkedFrame(frame, region: region)
                if !niriHiddenWindows.contains(wid), trackedWindows[wid] != nil,
                   let current = AccessibilityBridge.getFrame(of: element) {
                    transitions.append(Animator.Transition(
                        windowID: wid, element: element,
                        startFrame: current, targetFrame: parked))
                } else {
                    park(element, at: parked)
                }
            }
        }

        niriUpdateVisibility(results)

        // Animate visible windows
        for colResult in results where colResult.isVisible {
            for (wid, frame) in colResult.windowFrames {
                guard let element = axElements[wid],
                      let _ = trackedWindows[wid]
                else { continue }
                let currentFrame = AccessibilityBridge.getFrame(of: element) ?? frame
                transitions.append(Animator.Transition(
                    windowID: wid,
                    element: element,
                    startFrame: currentFrame,
                    targetFrame: frame
                ))
            }
        }

        if !transitions.isEmpty {
            if animated {
                Animator.shared.animate(transitions)
            } else {
                // Un-parking after a workspace switch: appear in place, don't fly in.
                AccessibilityBridge.batchSetFrames(
                    transitions.map { (element: $0.element, frame: $0.targetFrame) })
            }
        }

        return results.filter { $0.isVisible }.flatMap { $0.windowFrames.map { ($0.windowID, $0.frame) } }
    }

    /// Niri retile with scale-in animation for a new window.
    private func retileNiriWithScaleIn(newWindowID: CGWindowID) {
        let region = getTilingRegion()
        let results = NativeTiling.calculateNiriFrames(
            columns: layoutEngine.niriColumns,
            region: region,
            gap: config.innerGap,
            activeColumn: layoutEngine.niriActiveColumn,
            defaultColumnWidth: config.niriColumnWidth,
            minColumnWidth: config.niriMinColumnWidth,
            stackMode: config.niriColumnStack,
            scrollOffset: layoutEngine.niriScrollOffset,
            fillScreen: config.niriFillScreen,
            minWidthByWindow: niriMinWidth,
            resultingScrollOffset: &layoutEngine.niriScrollOffset
        )

        niriUpdateVisibility(results)

        var transitions: [Animator.Transition] = []
        for colResult in results where colResult.isVisible {
            for (wid, frame) in colResult.windowFrames {
                guard let element = axElements[wid] else { continue }

                let startFrame: CGRect
                let isNew: Bool
                if wid == newWindowID {
                    let scale: CGFloat = 0.80
                    startFrame = CGRect(
                        x: frame.midX - frame.width * scale / 2,
                        y: frame.midY - frame.height * scale / 2,
                        width: frame.width * scale,
                        height: frame.height * scale
                    )
                    isNew = true
                } else {
                    startFrame = AccessibilityBridge.getFrame(of: element) ?? frame
                    isNew = false
                }

                transitions.append(Animator.Transition(
                    windowID: wid,
                    element: element,
                    startFrame: startFrame,
                    targetFrame: frame,
                    isNewWindow: isNew
                ))
            }
        }

        if !transitions.isEmpty {
            Animator.shared.animate(transitions)
        }

        let visibleLayouts: [(CGWindowID, CGRect)] = results.filter { $0.isVisible }.flatMap { $0.windowFrames.map { ($0.windowID, $0.frame) } }
        updateBorders(layouts: visibleLayouts)
        updateDimming(layouts: visibleLayouts)
    }

    /// Step focus one column sideways, landing on whatever that column had focused.
    ///
    /// This walked window by window for a while, because at the time nothing else could
    /// reach the second window in a column. Vertical focus has its own keys now, and the
    /// walk had become the problem: from the top of a stack the sideways key went down
    /// the stack first, so reaching the column beside you meant going through the one you
    /// were in. Columns are the horizontal unit again.
    ///
    /// Floating windows come after the last column, because nothing else reaches them.
    private func niriFocusDirection(_ delta: Int) {
        let columns = layoutEngine.niriColumns
        let floating = floatingWindows.sorted()
        let total = columns.count + floating.count
        guard total >= 2 else { return }

        let currentID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        let index: Int
        if let wid = currentID, let found = layoutEngine.findWindowInColumns(wid) {
            index = found.col
        } else if let wid = currentID, let slot = floating.firstIndex(of: wid) {
            index = columns.count + slot
        } else {
            // Nothing we know about holds focus, so come in from the end we head towards.
            index = delta > 0 ? -1 : total
        }

        let next = index + delta
        guard next >= 0 && next < total else { return }

        if next < columns.count {
            let column = columns[next]
            guard !column.windows.isEmpty else { return }
            niriFocus(column.windows[column.clampedFocusedIndex])
        } else {
            niriFocus(floating[next - columns.count])
        }
    }

    /// Focus one window from the niri walk, scrolling the strip only when it belongs to it.
    private func niriFocus(_ wid: CGWindowID) {
        if let found = layoutEngine.findWindowInColumns(wid) {
            layoutEngine.niriColumns[found.col].focusedIndex = found.row
            niriScrollToColumn(found.col)
        }
        guard let element = axElements[wid], let tracked = trackedWindows[wid] else { return }
        AccessibilityBridge.focus(window: element, pid: tracked.pid)
        focusedWindowID = wid
        onFocusChange?()
    }

    /// Animate scroll from current column to target column.
    /// Columns leaving the viewport slide out to the parked spot rather than stopping at
    /// their place in the strip, which is where they used to sit waiting to be faded.
    private func niriScrollToColumn(_ col: Int) {
        guard col >= 0 && col < layoutEngine.niriColumns.count else { return }

        let region = getTilingRegion()

        // Cancel any pending hide from a previous scroll
        niriHideWorkItem?.cancel()

        // Update active column
        layoutEngine.niriActiveColumn = col

        // Calculate target positions
        let results = NativeTiling.calculateNiriFrames(
            columns: layoutEngine.niriColumns,
            region: region,
            gap: config.innerGap,
            activeColumn: col,
            defaultColumnWidth: config.niriColumnWidth,
            minColumnWidth: config.niriMinColumnWidth,
            stackMode: config.niriColumnStack,
            scrollOffset: layoutEngine.niriScrollOffset,
            fillScreen: config.niriFillScreen,
            minWidthByWindow: niriMinWidth,
            resultingScrollOffset: &layoutEngine.niriScrollOffset
        )

        // Windows about to come into view stop counting as hidden. There is nothing to
        // un-fade here: what hides a column is where it sits, not its alpha.
        for colResult in results where colResult.isVisible {
            for (wid, _) in colResult.windowFrames {
                niriHiddenWindows.remove(wid)
            }
        }

        // Build transitions for visible + departing windows
        var transitions: [Animator.Transition] = []
        for colResult in results {
            for (wid, targetFrame) in colResult.windowFrames {
                guard let element = axElements[wid], let _ = trackedWindows[wid] else { continue }
                // Animate windows that are currently visible or will become visible
                let isCurrentlyVisible = !niriHiddenWindows.contains(wid)
                guard colResult.isVisible || isCurrentlyVisible else { continue }
                // A window on its way out slides to where it will be parked, not to its
                // place in the strip. Animating it to the strip position left it sitting
                // half on screen until the delayed hide caught up, which is what made it
                // look like it was being dragged off the edge.
                let endFrame = colResult.isVisible
                    ? targetFrame
                    : niriParkedFrame(targetFrame, region: region)
                let currentFrame = AccessibilityBridge.getFrame(of: element) ?? endFrame
                transitions.append(Animator.Transition(
                    windowID: wid, element: element,
                    startFrame: currentFrame, targetFrame: endFrame
                ))
            }
        }

        if !transitions.isEmpty {
            Animator.shared.animate(transitions)
        }

        // After animation, hide off-screen windows + position at strip locations
        let hideWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            for colResult in results where !colResult.isVisible {
                for (wid, frame) in colResult.windowFrames {
                    self.niriHiddenWindows.insert(wid)
                    guard let element = self.axElements[wid] else { continue }
                    self.park(element, at: self.niriParkedFrame(frame, region: region))
                }
            }
            var known = self.observer.currentKnownWindows
            known.formUnion(self.niriHiddenWindows)
            self.observer.syncKnownWindows(known)
        }
        niriHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: hideWork)

        // Focus the target window
        if let targetWID = layoutEngine.niriColumns[col].focusedWindow,
           let element = axElements[targetWID], let tracked = trackedWindows[targetWID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = targetWID
        }

        let visibleLayouts = results.filter { $0.isVisible }.flatMap { $0.windowFrames.map { ($0.windowID, $0.frame) } }
        updateBorders(layouts: visibleLayouts)
        updateDimming(layouts: visibleLayouts)
        onFocusChange?()
    }

    /// Hide off-screen windows and unhide on-screen ones for Niri mode.
    /// Uses alpha-only hiding so windows stay at their strip positions for smooth animation.
    private func niriUpdateVisibility(_ results: [NativeTiling.NiriColumnResult]) {
        // Keep track of which windows are off screen, so the observer goes on knowing
        // about them.
        //
        // This used to fade them out with CGSSetWindowAlpha, which reports success and
        // does nothing whatsoever on a window owned by another process. Parking the
        // window past the screen edge is what actually hides it. The alpha calls only
        // made it look as though something was covering the ones still in view.
        for colResult in results {
            for (wid, _) in colResult.windowFrames {
                if colResult.isVisible {
                    niriHiddenWindows.remove(wid)
                } else {
                    niriHiddenWindows.insert(wid)
                }
            }
        }

        // Sync observer's known windows to include niri-hidden windows
        var known = observer.currentKnownWindows
        known.formUnion(niriHiddenWindows)
        observer.syncKnownWindows(known)
    }

    /// Navigate up/down within the active column's window stack.
    /// Move the focused window up or down inside its own column.
    ///
    /// Columns stack vertically, but nothing could reorder that stack. The vertical keys
    /// stepped focus and the horizontal ones moved the whole column, so a window could
    /// join a column and never change places with the one it had joined.
    private func niriMoveVertical(_ delta: Int) {
        guard config.niriMode, let wid = focusedWindowID else { return }
        guard let (ci, ri) = layoutEngine.findWindowInColumns(wid) else { return }

        let target = ri + delta
        guard target >= 0 && target < layoutEngine.niriColumns[ci].windows.count else { return }

        layoutEngine.niriColumns[ci].windows.swapAt(ri, target)
        layoutEngine.niriColumns[ci].focusedIndex = target
        layoutEngine.syncTiledWindowsFromColumns()
        focusedWindowID = wid
        retile()
        onFocusChange?()
    }

    private func niriFocusVertical(_ delta: Int) {
        guard !layoutEngine.niriColumns.isEmpty else { return }
        let ci = max(0, min(layoutEngine.niriActiveColumn, layoutEngine.niriColumns.count - 1))
        let col = layoutEngine.niriColumns[ci]
        guard col.windows.count > 1 else { return }

        let newRow = col.clampedFocusedIndex + delta
        guard newRow >= 0 && newRow < col.windows.count else { return }

        layoutEngine.niriColumns[ci].focusedIndex = newRow
        let targetWID = col.windows[newRow]

        if let element = axElements[targetWID], let tracked = trackedWindows[targetWID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = targetWID
        }

        retile()

        onFocusChange?()
    }

    /// Consume: take the first window from the right column and append to the current column.
    /// Move the whole focused column one place along the strip.
    ///
    /// This is niri's move-column-left/right, and it is the one that reorders without
    /// rearranging: the column keeps whatever windows it holds and simply swaps place
    /// with its neighbour. Distinct from niri_move_left/right, which take a single
    /// window out of its column or into the next one.
    private func niriMoveColumn(right: Bool) {
        guard config.niriMode else { return }

        // Find the column from the focused window rather than trusting niriActiveColumn,
        // which can drift out of step with what is actually focused and then moves the
        // wrong column.
        var ci = layoutEngine.niriActiveColumn
        if let wid = focusedWindowID, let found = layoutEngine.findWindowInColumns(wid) {
            ci = found.col
        }
        guard ci >= 0 && ci < layoutEngine.niriColumns.count else { return }
        let target = right ? ci + 1 : ci - 1
        guard target >= 0 && target < layoutEngine.niriColumns.count else { return }

        layoutEngine.niriColumns.swapAt(ci, target)
        layoutEngine.niriActiveColumn = target
        layoutEngine.syncTiledWindowsFromColumns()
        retile()
        onFocusChange?()
        panelessLog("Niri move column \(right ? "right" : "left")")
    }

    /// Move the focused window one step sideways, merging or splitting as needed.
    ///
    /// This is niri's `consume-or-expel-window-left/right`, and it is what niri puts on
    /// its easiest keys rather than the raw consume and expel pair. Those two operate on
    /// the column: consume reaches out and pulls in a window you were not looking at, and
    /// expel pushes your window away and drags your focus along with it. Correct, but
    /// backwards to think about. This one is window-centric instead: the window you are
    /// looking at goes left or right, joining the column on that side if it is alone, or
    /// leaving its column if it is sharing one. Focus stays on it throughout.
    private func niriMoveFocused(right: Bool) {
        guard config.niriMode, let wid = focusedWindowID else { return }
        guard let (ci, ri) = layoutEngine.findWindowInColumns(wid) else { return }

        let sharing = layoutEngine.niriColumns[ci].windows.count > 1
        layoutEngine.niriColumns[ci].windows.remove(at: ri)

        if sharing {
            // Leave the column and stand alone next to it.
            layoutEngine.niriColumns[ci].focusedIndex = min(ri, layoutEngine.niriColumns[ci].windows.count - 1)
            let at = right ? ci + 1 : ci
            // A window leaving a column starts at the default width, the way niri does
            // it. Inheriting the override turned one widened column into two, so the row
            // grew a little wider every time a window was pushed out of one.
            let col = NiriColumn(windows: [wid])
            layoutEngine.niriColumns.insert(col, at: at)
            layoutEngine.niriActiveColumn = at
        } else {
            // Was alone: that column goes, and the window joins the one beside it.
            layoutEngine.niriColumns.remove(at: ci)
            let target = right ? ci : ci - 1
            if target >= 0 && target < layoutEngine.niriColumns.count {
                layoutEngine.niriColumns[target].windows.append(wid)
                layoutEngine.niriColumns[target].focusedIndex = layoutEngine.niriColumns[target].windows.count - 1
                layoutEngine.niriActiveColumn = target
            } else {
                // Nothing on that side, so put it back where it was.
                let at = max(0, min(ci, layoutEngine.niriColumns.count))
                layoutEngine.niriColumns.insert(NiriColumn(windows: [wid]), at: at)
                layoutEngine.niriActiveColumn = at
            }
        }

        layoutEngine.niriColumns.removeAll { $0.windows.isEmpty }
        layoutEngine.syncTiledWindowsFromColumns()
        focusedWindowID = wid
        retile()
        onFocusChange?()
        panelessLog("Niri move \(right ? "right" : "left"): window \(wid)")
    }

    private func niriConsume() {
        guard config.niriMode else { return }
        let ci = layoutEngine.niriActiveColumn
        guard ci >= 0 && ci < layoutEngine.niriColumns.count else { return }
        let rightIdx = ci + 1
        guard rightIdx < layoutEngine.niriColumns.count else { return }

        // Take the first window from the right column
        let wid = layoutEngine.niriColumns[rightIdx].windows.removeFirst()

        // If right column is now empty, remove it
        if layoutEngine.niriColumns[rightIdx].windows.isEmpty {
            layoutEngine.niriColumns.remove(at: rightIdx)
        } else {
            layoutEngine.niriColumns[rightIdx].focusedIndex = 0
        }

        // Append to current column
        layoutEngine.niriColumns[ci].windows.append(wid)
        layoutEngine.niriColumns[ci].focusedIndex = layoutEngine.niriColumns[ci].windows.count - 1

        // Unhide the consumed window if it was off-screen
        if niriHiddenWindows.remove(wid) != nil {
            let conn = CGSMainConnectionID()
            CGSSetWindowAlpha(conn, wid, 1.0)
        }

        layoutEngine.syncTiledWindowsFromColumns()
        focusedWindowID = wid
        retile()

        onFocusChange?()
        panelessLog("Niri consume: absorbed window \(wid) into column \(ci)")
    }

    /// Expel: eject focused window from a multi-window column into its own column to the right.
    private func niriExpel() {
        guard config.niriMode else { return }
        let ci = layoutEngine.niriActiveColumn
        guard ci >= 0 && ci < layoutEngine.niriColumns.count else { return }
        guard layoutEngine.niriColumns[ci].windows.count > 1 else { return }

        let ri = layoutEngine.niriColumns[ci].clampedFocusedIndex
        let wid = layoutEngine.niriColumns[ci].windows.remove(at: ri)

        // Clamp focusedIndex after removal
        layoutEngine.niriColumns[ci].focusedIndex = min(ri, layoutEngine.niriColumns[ci].windows.count - 1)

        // Insert as new column to the right
        // Expelled windows start at the default width rather than inheriting the width
        // of the column they came from, which used to widen the row on every expel.
        let newCol = NiriColumn(windows: [wid])
        layoutEngine.niriColumns.insert(newCol, at: ci + 1)

        // Move focus to the new column
        layoutEngine.niriActiveColumn = ci + 1

        layoutEngine.syncTiledWindowsFromColumns()
        focusedWindowID = wid
        retile()

        onFocusChange?()
        panelessLog("Niri expel: ejected window \(wid) into new column \(ci + 1)")
    }

    // MARK: - Focus Desktop (Empty Workspace)

    /// When no windows are on the current workspace, activate Finder so macOS
    /// doesn't keep a random app from another workspace focused.
    private func focusDesktop() {
        if let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) {
            finder.activate()
            focusedWindowID = nil
            panelessLog("Empty workspace — focused Finder/desktop")
        }
    }

    // MARK: - Click-to-Focus Dimming Refresh

    private func setupClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            // Cancel any pending refresh
            self.clickDimWorkItem?.cancel()
            // After a mouse click, macOS activates the target window and reshuffles z-order
            // asynchronously. Wait for that to settle, then re-query focus and refresh dimming.
            let work = DispatchWorkItem { [weak self] in
                self?.refreshFocusAndDimming()
            }
            self.clickDimWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    private func refreshFocusAndDimming() {
        guard let newFocusedID = AccessibilityBridge.getFocusedWindowID(),
              trackedWindows[newFocusedID] != nil
        else { return }
        let changed = newFocusedID != focusedWindowID
        focusedWindowID = newFocusedID
        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        updateBorders(layouts: layouts)
        updateDimming(layouts: layouts)
        if changed { onFocusChange?() }
    }

    // MARK: - Mouse Drag Resize

    private func setupResizeMonitor() {
        resizeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleResizeEvent(event)
        }
    }

    private func stopResizeMonitor() {
        if let monitor = resizeMonitor {
            NSEvent.removeMonitor(monitor)
            resizeMonitor = nil
        }
    }

    private func handleResizeEvent(_ event: NSEvent) {
        // Require Ctrl held to start a drag resize (prevents accidental triggers)
        guard layoutEngine.tiledWindows.count >= 2 else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard let primaryScreen = NSScreen.screens.first else { return }
        let screenHeight = primaryScreen.frame.height
        let axPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        let region = getTilingRegion()

        switch event.type {
        case .leftMouseDown:
            // Only start resize if Ctrl is held
            guard event.modifierFlags.contains(.control) else { return }

            let isStacked = layoutEngine.layoutVariant == 1

            if isStacked {
                let splitY = region.y + region.height * layoutEngine.splitRatio
                if abs(axPoint.y - splitY) < 20 {
                    isResizing = true
                    resizeStartPos = axPoint.y
                    resizeInitialRatio = layoutEngine.splitRatio
                }
            } else {
                let splitX = region.x + region.width * layoutEngine.splitRatio
                if abs(axPoint.x - splitX) < 20 {
                    isResizing = true
                    resizeStartPos = axPoint.x
                    resizeInitialRatio = layoutEngine.splitRatio
                }
            }

        case .leftMouseDragged:
            guard isResizing else { return }
            let isStacked = layoutEngine.layoutVariant == 1

            if isStacked {
                let delta = axPoint.y - resizeStartPos
                let ratioDelta = delta / region.height
                layoutEngine.splitRatio = max(0.2, min(0.8, resizeInitialRatio + ratioDelta))
            } else {
                let delta = axPoint.x - resizeStartPos
                let ratioDelta = delta / region.width
                layoutEngine.splitRatio = max(0.2, min(0.8, resizeInitialRatio + ratioDelta))
            }

            // Snap frames instantly during drag (no animation)
            let windows = layoutEngine.tiledWindows.compactMap { wid -> (windowID: CGWindowID, element: AXUIElement, pid: pid_t)? in
                guard let el = axElements[wid], let t = trackedWindows[wid] else { return nil }
                return (wid, el, t.pid)
            }
            NativeTiling.applyLayout(
                windows: windows, region: region, gap: config.innerGap,
                singleWindowPadding: config.singleWindowPadding,
                splitRatio: layoutEngine.splitRatio, variant: layoutEngine.layoutVariant,
                animate: false
            )
            let layouts = layoutEngine.calculateFrames(in: region)
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)

        case .leftMouseUp:
            if isResizing {
                isResizing = false
            }

        default:
            break
        }
    }

    // MARK: - Display Change

    @objc private func displayConfigChanged(_ notification: Notification) {
        panelessLog("Display configuration changed")
        // Debounce: macOS fires several notifications in a burst during a display
        // change. Wait for it to settle (and to finish relocating windows) before
        // reconciling workspace state.
        displayReconfigWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileAfterDisplayChange() }
        displayReconfigWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Reconcile workspace state after a display is connected, disconnected, or the
    /// main display changes. The core problem: workspace state is keyed by display ID,
    /// so when a monitor disappears its windows are stranded under a dead key and macOS
    /// dumps them onto the surviving display. Here we migrate those workspaces onto the
    /// monitor we're actually using, merged by workspace number, then re-hide inactive
    /// windows and retile.
    private func reconcileAfterDisplayChange() {
        let wsMgr = WorkspaceManager.shared
        let liveIDs = Set(NSScreen.screens.map { wsMgr.screenID(for: $0) })
        let knownIDs = Set(wsMgr.workspaces.keys).union(wsMgr.activeWorkspace.keys)
        let orphanedIDs = knownIDs.subtracting(liveIDs)

        guard !orphanedIDs.isEmpty else {
            // No monitor was lost — just a resolution or arrangement change.
            // Coordinate conversions recompute against the current primary, so a
            // plain retile is enough.
            retile()
            return
        }

        panelessLog("Display(s) disconnected: \(orphanedIDs.sorted()). Migrating workspaces.")

        observer.pause()
        defer { observer.resume() }

        // The live set belongs to whichever monitor we were last working on. If that
        // monitor survived, keep using it; otherwise fall back to the new primary.
        let oldLiveMonitor = liveMonitorID
        let oldActive = wsMgr.activeWorkspace[oldLiveMonitor] ?? 1

        let targetScreen: NSScreen
        let targetID: String
        if liveIDs.contains(oldLiveMonitor),
           let survivor = NSScreen.screens.first(where: { wsMgr.screenID(for: $0) == oldLiveMonitor }) {
            targetScreen = survivor
            targetID = oldLiveMonitor
        } else {
            targetScreen = NSScreen.safeMain
            targetID = wsMgr.screenID(for: targetScreen)
        }
        let screenFrame = screenFrameInAX(for: targetScreen)

        // Fold the current live set back into its stored workspace so nothing is lost.
        saveWorkspaceState(workspace: oldActive, monitor: oldLiveMonitor)

        // Migrate every disconnected monitor's workspaces onto the target monitor.
        for oldID in orphanedIDs where oldID != targetID {
            wsMgr.migrateMonitor(from: oldID, to: targetID)
            wsMgr.activeWorkspace.removeValue(forKey: oldID)

            // Fold the lost display's layout into the one we are keeping. Its windows are
            // on the surviving screen now, and a layout keyed to a display that is gone
            // would never be laid out again, so they would be left loose on the desktop.
            guard let orphan = layoutEngines.removeValue(forKey: oldID) else { continue }
            let survivor = engine(for: targetID)
            for wid in orphan.tiledWindows where !survivor.contains(wid) {
                survivor.insert(windowID: wid, afterFocused: nil)
                if config.niriMode { survivor.insertWindowAsNewColumn(wid) }
            }
        }
        wsMgr.activeWorkspace[targetID] = oldActive

        // macOS surfaced every relocated window onto the visible display. Re-hide the
        // ones that belong to non-active workspaces before showing the active one.
        rehideInactiveWorkspaces(activeMonitor: targetID, activeWorkspace: oldActive, screenFrame: screenFrame)

        loadWorkspaceState(workspace: oldActive, monitor: targetID)
        liveMonitorID = targetID
        retile()
        restoreFloatingWindowPositions()
        onSpaceChange?()
        WorkspacePersistence.save(debounced: false)
        panelessLog("Reconciled displays: active workspace \(oldActive) on \(targetID)")
    }

    /// Park every window that belongs to an inactive workspace off-screen so it doesn't
    /// linger on the visible display after a monitor change.
    private func rehideInactiveWorkspaces(activeMonitor: String, activeWorkspace: Int, screenFrame: CGRect) {
        let wsMgr = WorkspaceManager.shared
        guard let monitorWorkspaces = wsMgr.workspaces[activeMonitor] else { return }
        for (wsNum, ws) in monitorWorkspaces where wsNum != activeWorkspace {
            for (wid, element) in ws.axElements {
                guard !stickyWindows.contains(wid) else { continue }
                wsMgr.hideWindow(wid, element: element, screenFrame: screenFrame)
            }
        }
    }

    // MARK: - Focus Follows Mouse

    private func startFocusFollowsMouse() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
        }
    }

    private func stopFocusFollowsMouse() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        // Throttle: only check every 100ms
        let now = Date()
        guard now.timeIntervalSince(lastMouseFocusTime) > 0.1 else { return }
        lastMouseFocusTime = now

        let mouseLocation = NSEvent.mouseLocation
        guard let primaryScreen = NSScreen.screens.first else { return }
        let screenHeight = primaryScreen.frame.height
        // Convert Cocoa coords to AX coords
        let axPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        // Find which tiled window contains the cursor
        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        for (windowID, frame) in layouts {
            if frame.contains(axPoint) && windowID != focusedWindowID {
                if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
                    AccessibilityBridge.focus(window: element, pid: tracked.pid)
                    focusedWindowID = windowID
                    updateBorders(layouts: layouts)
                    updateDimming(layouts: layouts)
                }
                break
            }
        }
    }

    // MARK: - Dim Unfocused Windows (Compositor Brightness)

    /// Uses CGSSetWindowListBrightness as an additive brightness offset:
    ///   0.0 = normal, negative = darker, positive = brighter.
    /// Compositor-level — follows window shape, rounded corners, shadow perfectly.

    // MARK: - Dim ramp

    private var dimFrom: [CGWindowID: Float] = [:]
    private var dimTo: [CGWindowID: Float] = [:]
    private var dimTimer: DispatchSourceTimer?
    private var dimStart: CFTimeInterval = 0
    private let dimDuration: CFTimeInterval = 0.18

    /// Ease brightness to a new level instead of switching it.
    ///
    /// Worth doing because, unlike geometry and alpha, window brightness genuinely does
    /// apply to windows owned by other processes: measured, a -0.6 offset changed 100%
    /// of the pixels in the target window. So this is one of the few visual effects we
    /// can drive on someone else's window, and it costs one call for the whole list.
    private func rampBrightness(_ levels: [CGWindowID: Float]) {
        guard !levels.isEmpty else { return }
        let conn = CGSMainConnectionID()
        for (wid, target) in levels {
            dimFrom[wid] = dimTo[wid] ?? dimFrom[wid] ?? 0
            dimTo[wid] = target
        }
        dimStart = CACurrentMediaTime()

        dimTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let t = min((CACurrentMediaTime() - self.dimStart) / self.dimDuration, 1.0)
            // Smoothstep, not ease-out. Ease-out puts most of the change in the first
            // few milliseconds, which for brightness reads as a snap with a tail rather
            // than a fade: measured -11.45 in one frame and then a decaying remainder.
            let e = Float(t * t * (3 - 2 * t))
            var wids: [CGWindowID] = []
            var values: [Float] = []
            for (wid, to) in self.dimTo {
                let from = self.dimFrom[wid] ?? 0
                wids.append(wid)
                values.append(t >= 1.0 ? to : from + (to - from) * e)
            }
            if !wids.isEmpty {
                CGSSetWindowListBrightness(conn, &wids, &values, Int32(wids.count))
            }
            if t >= 1.0 {
                self.dimFrom = self.dimTo
                self.dimTimer?.cancel()
                self.dimTimer = nil
            }
        }
        dimTimer = timer
        timer.resume()
    }

    private func updateDimming(layouts: [(CGWindowID, CGRect)]? = nil) {
        let dimAmount = config.dimUnfocused
        guard dimAmount > 0 else { restoreAllDimming(); return }

        let focusedID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID()
        let tiledSet = Set(layoutEngine.tiledWindows)
        let offset = -Float(dimAmount)  // e.g. dim=0.3 → offset=-0.3 (darker)

        // Restore windows no longer tiled or now focused
        var toRestore: [CGWindowID] = []
        for wid in Array(dimmedWindows) {
            if !tiledSet.contains(wid) || wid == focusedID {
                toRestore.append(wid)
                dimmedWindows.remove(wid)
            }
        }
        if !toRestore.isEmpty {
            rampBrightness(Dictionary(uniqueKeysWithValues: toRestore.map { ($0, Float(0)) }))
        }

        // Dim unfocused tiled windows
        var toDim: [CGWindowID] = []
        for wid in layoutEngine.tiledWindows {
            if wid == focusedID {
                if dimmedWindows.contains(wid) {
                    rampBrightness([wid: 0.0])
                    dimmedWindows.remove(wid)
                }
                continue
            }
            toDim.append(wid)
            dimmedWindows.insert(wid)
        }

        if !toDim.isEmpty {
            rampBrightness(Dictionary(uniqueKeysWithValues: toDim.map { ($0, offset) }))
        }
    }

    private func restoreAllDimming() {
        let conn = CGSMainConnectionID()
        // Reset brightness offset to 0.0 (normal) for all visible windows
        let allWindowIDs = SpaceManager.getWindowsOnCurrentSpace()
        if !allWindowIDs.isEmpty {
            var wids = allWindowIDs
            var values = [Float](repeating: 0.0, count: allWindowIDs.count)
            CGSSetWindowListBrightness(conn, &wids, &values, Int32(allWindowIDs.count))
        }
        dimmedWindows.removeAll()
    }


    // MARK: - Window Minimize to Workspace

    private func minimizeFocused() {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID(),
              let element = axElements[windowID],
              trackedWindows[windowID] != nil
        else { return }

        if minimizedWindows.contains(windowID) {
            // Already minimized — restore it
            restoreMinimized(windowID)
            return
        }

        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)

        // Hide off-screen (same technique as workspace hiding)
        WorkspaceManager.shared.hideWindow(windowID, element: element, screenFrame: screenFrame)
        minimizedWindows.insert(windowID)

        // Remove from tiling
        let wasTiled = layoutEngine.contains(windowID)
        if wasTiled { layoutEngine.remove(windowID: windowID) }

        if dimmedWindows.remove(windowID) != nil {
            var wids: [CGWindowID] = [windowID]
            var values: [Float] = [0.0]
            CGSSetWindowListBrightness(CGSMainConnectionID(), &wids, &values, 1)
        }

        retile()

        // Focus next window or desktop
        if let firstWid = layoutEngine.tiledWindows.first,
           let el = axElements[firstWid], let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: el, pid: tracked.pid)
            focusedWindowID = firstWid
        } else {
            focusDesktop()
        }

        panelessLog("Minimized window \(windowID)")
        onFocusChange?()
    }

    private func restoreMinimized(_ windowID: CGWindowID) {
        guard let element = axElements[windowID],
              let tracked = trackedWindows[windowID]
        else { return }

        minimizedWindows.remove(windowID)

        // Restore to visible position
        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)
        let restoreFrame = CGRect(
            x: screenFrame.origin.x + screenFrame.width / 4,
            y: screenFrame.origin.y + screenFrame.height / 4,
            width: screenFrame.width / 2,
            height: screenFrame.height / 2
        )
        AccessibilityBridge.setFrame(of: element, to: restoreFrame)

        // Re-tile if not floating
        if !floatingWindows.contains(windowID) {
            layoutEngine.insert(windowID: windowID, afterFocused: focusedWindowID)
        }

        AccessibilityBridge.focus(window: element, pid: tracked.pid)
        focusedWindowID = windowID
        retile()
        panelessLog("Restored minimized window \(windowID)")
        onFocusChange?()
    }

    // MARK: - Drag to Reorder

    private func setupDragMonitor() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDragReorder(event)
        }
    }

    private func handleDragReorder(_ event: NSEvent) {
        // Only reorder when Ctrl is held
        guard event.modifierFlags.contains(.control) else {
            dragStartWindowID = nil
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        // Convert to AX coordinates
        guard let primaryScreen = NSScreen.screens.first else { return }
        let axPoint = CGPoint(x: mouseLocation.x, y: primaryScreen.frame.height - mouseLocation.y)

        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())

        if event.type == .leftMouseDragged {
            if dragStartWindowID == nil {
                // Find which tiled window the drag started on
                for (wid, frame) in layouts {
                    if frame.contains(axPoint) {
                        dragStartWindowID = wid
                        break
                    }
                }
            }
        } else if event.type == .leftMouseUp {
            guard let startID = dragStartWindowID else { return }
            dragStartWindowID = nil

            // Find which tiled window we dropped on
            for (wid, frame) in layouts {
                if frame.contains(axPoint) && wid != startID {
                    // Swap positions in the layout engine
                    if let idx1 = layoutEngine.tiledWindows.firstIndex(of: startID),
                       let idx2 = layoutEngine.tiledWindows.firstIndex(of: wid) {
                        layoutEngine.tiledWindows.swapAt(idx1, idx2)
                        retile()
                        panelessLog("Drag-reorder: swapped \(startID) with \(wid)")
                    }
                    break
                }
            }
        }
    }

    // MARK: - Window Marks (vim-style)

    private func setWindowMark(_ key: String) {
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }
        windowMarks[key] = windowID
        let appName = trackedWindows[windowID]?.appName ?? "unknown"
        panelessLog("Mark '\(key)' set on window \(windowID) (\(appName))")
    }

    private func jumpToWindowMark(_ key: String) {
        guard let windowID = windowMarks[key] else {
            panelessLog("No mark '\(key)' set")
            return
        }

        // If the window is on the current workspace, just focus it
        if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = windowID
            let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
            updateBorders(layouts: layouts)
            updateDimming(layouts: layouts)

            onFocusChange?()
            return
        }

        // Window might be on another workspace — find it
        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        if let wsNum = WorkspaceManager.shared.findWorkspace(for: windowID, on: monitorID) {
            switchVirtualWorkspace(wsNum)
            // After switching, focus the marked window
            if let element = axElements[windowID], let tracked = trackedWindows[windowID] {
                AccessibilityBridge.focus(window: element, pid: tracked.pid)
                focusedWindowID = windowID
                let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
                updateBorders(layouts: layouts)
                updateDimming(layouts: layouts)
    
                onFocusChange?()
            }
            return
        }

        // Mark is stale (window no longer exists)
        windowMarks.removeValue(forKey: key)
        panelessLog("Mark '\(key)' was stale — window no longer exists")
    }

    // MARK: - Virtual Workspace Switching

    private func switchVirtualWorkspace(_ number: Int) {
        let conn = CGSMainConnectionID()
        guard number >= 1 && number <= 9 else { return }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        liveMonitorID = monitorID

        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1
        guard number != currentWS else {
            panelessLog("Already on workspace \(number)")
            return
        }

        // Pause observer to prevent race conditions during workspace switch
        observer.pause()
        defer { observer.resume() }

        // Whatever is still in the air belongs to the workspace being left. Left
        // running, its final write put those windows back at their tile frames on top
        // of the new workspace, which is how a window came to sit behind the one you
        // had switched to. The delayed niri park is the same kind of leftover.
        Animator.shared.cancelAll()
        niriHideWorkItem?.cancel()
        niriHideWorkItem = nil
        reparkFailures.removeAll()

        let screenFrame = screenFrameInAX(for: screen)

        // Remove dim overlays before switching (they reference old workspace windows)
        restoreAllDimming()

        // Make the whole switch land as one frame.
        //
        // The old workspace's windows are parked off-screen before the new ones are
        // placed, so between those two steps there is nothing on screen and the desktop
        // shows through. Freezing compositor output across the swap means the screen
        // goes straight from one workspace to the other. Safe here in a way it would not
        // be around an animation: this block is synchronous and waits for nothing, and
        // the defer guarantees the release even if something below throws.
        SLSDisableUpdate(conn)
        defer { SLSReenableUpdate(conn) }

        // Save current layout variant for this workspace
        workspaceLayouts["\(monitorID)-\(currentWS)"] = layoutEngine.layoutVariant

        // Save current state into WorkspaceManager
        saveWorkspaceState(workspace: currentWS, monitor: monitorID)

        // Switch: hides old windows (moves off-screen), activates new workspace number
        // Sticky windows are excluded from hiding — they stay visible on all workspaces
        WorkspaceManager.shared.switchWorkspace(to: number, on: monitorID, screenFrame: screenFrame, stickyWindows: stickyWindows)

        // Load new workspace state
        loadWorkspaceState(workspace: number, monitor: monitorID)

        // Restore layout variant for this workspace
        if let savedVariant = workspaceLayouts["\(monitorID)-\(number)"] {
            layoutEngine.layoutVariant = savedVariant
        }

        // Un-parking, not a layout change: these windows are coming back from the
        // hidden corner, so they must appear where they belong rather than fly in.
        retile(animated: false)

        // Restore floating/fullscreen windows to their saved positions
        // (retile only handles tiled windows; floating windows need explicit restoration)
        restoreFloatingWindowPositions()

        // If workspace is empty, focus Finder so macOS doesn't keep a
        // random app from another workspace focused
        if layoutEngine.tiledWindows.isEmpty && floatingWindows.isEmpty {
            focusDesktop()
        } else if let fid = focusedWindowID,
                  let element = axElements[fid],
                  let tracked = trackedWindows[fid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
        } else if let firstWid = layoutEngine.tiledWindows.first,
                  let element = axElements[firstWid],
                  let tracked = trackedWindows[firstWid] {
            AccessibilityBridge.focus(window: element, pid: tracked.pid)
            focusedWindowID = firstWid
        }

        onSpaceChange?()
        lastWorkspaceSwitchAt = Date()
        // A summon queued from before the switch belongs to the old workspace.
        pendingSummon?.cancel()
        pendingSummon = nil
        panelessLog("Switched to workspace \(number) on \(monitorID)")
    }

    /// Which window takes over the space a departing one occupied.
    ///
    /// Focus should follow the position you were looking at. Jumping to the top left
    /// every time means that sending away the window in the lower right leaves you
    /// somewhere you never asked to be. Call after the window is out of the layout
    /// engine but before retiling, so the frames are the ones about to be applied.
    private func windowTakingOver(vacated: CGRect) -> CGWindowID? {
        let layouts = layoutEngine.calculateFrames(in: getTilingRegion())
        guard !layouts.isEmpty else { return nil }
        let centre = CGPoint(x: vacated.midX, y: vacated.midY)
        if let covering = layouts.first(where: { $0.1.contains(centre) }) {
            return covering.0
        }
        return layouts.min(by: {
            hypot($0.1.midX - centre.x, $0.1.midY - centre.y)
                < hypot($1.1.midX - centre.x, $1.1.midY - centre.y)
        })?.0
    }

    private func moveToVirtualWorkspace(_ number: Int) {
        guard number >= 1 && number <= 9 else { return }
        guard let windowID = focusedWindowID ?? AccessibilityBridge.getFocusedWindowID() else { return }

        // Sticky windows cannot be moved to a specific workspace (they're on all)
        guard !stickyWindows.contains(windowID) else {
            panelessLog("Cannot move sticky window to workspace — it's visible on all workspaces")
            return
        }

        let screen = NSScreen.safeMain
        let monitorID = WorkspaceManager.shared.screenID(for: screen)
        let currentWS = WorkspaceManager.shared.activeWorkspace[monitorID] ?? 1

        guard number != currentWS else {
            panelessLog("Window already on workspace \(number)")
            return
        }

        // The rect this window is giving up, read before anything moves it.
        let vacatedFrame = axElements[windowID].flatMap { AccessibilityBridge.getFrame(of: $0) }
            ?? trackedWindows[windowID]?.frame

        // Remove from current WM state
        let wasTiled = layoutEngine.contains(windowID)
        let vacatedIndex = layoutEngine.tiledWindows.firstIndex(of: windowID)
        // Out of the columns as well as the list. The retile would have dropped it
        // from the columns anyway, but a terminal restored below re-syncs the list
        // from the columns first, and would bring this window back with it.
        if config.niriMode { layoutEngine.removeWindowFromColumns(windowID) }
        if wasTiled { layoutEngine.remove(windowID: windowID) }

        // A window that swallowed a terminal leaves it behind, in the place it is
        // giving up. Taken along, the terminal was stranded: the unswallow only knew
        // how to find it on the workspace the window was on when it closed.
        if let terminalWID = swallowedWindows.removeValue(forKey: windowID) {
            trackedWindows[windowID]?.swallowedFrom = nil
            restoreSwallowedTerminal(terminalWID, at: vacatedIndex, in: layoutEngine)
        }

        let tracked = trackedWindows.removeValue(forKey: windowID)
        let element = axElements.removeValue(forKey: windowID)
        let wasFloating = floatingWindows.remove(windowID) != nil
        let wasFullscreen = fullscreenWindows.remove(windowID) != nil
        if dimmedWindows.remove(windowID) != nil {
            var wids: [CGWindowID] = [windowID]
            var values: [Float] = [0.0]
            CGSSetWindowListBrightness(CGSMainConnectionID(), &wids, &values, 1)
        }

        // Hide the window (move off-screen). Stop any glide it is in first, or the
        // glide's final write brings it straight back.
        Animator.shared.cancelAll()
        let screenFrame = screenFrameInAX(for: screen)
        WorkspaceManager.shared.hideWindow(windowID, element: element, screenFrame: screenFrame)

        // Add to target workspace in WorkspaceManager
        var targetWS = WorkspaceManager.shared.workspaces[monitorID]?[number] ?? VirtualWorkspace()
        if let tracked = tracked {
            targetWS.trackedWindows[windowID] = tracked
        }
        if let element = element {
            targetWS.axElements[windowID] = element
        }
        if wasFloating {
            targetWS.floatingWindows.insert(windowID)
        } else if wasFullscreen {
            targetWS.fullscreenWindows.insert(windowID)
        } else if wasTiled {
            targetWS.tiledWindows.append(windowID)
        }
        WorkspaceManager.shared.workspaces[monitorID, default: [:]][number] = targetWS

        // Focus whatever moves into the space this window just gave up, so you stay
        // where you were looking instead of being thrown to the top left corner.
        if focusedWindowID == windowID {
            focusedWindowID = vacatedFrame.flatMap { windowTakingOver(vacated: $0) }
                ?? layoutEngine.tiledWindows.first
            if let fid = focusedWindowID, let el = axElements[fid], let t = trackedWindows[fid] {
                AccessibilityBridge.focus(window: el, pid: t.pid)
            }
        }

        retile()
        onSpaceChange?()
        panelessLog("Moved window \(windowID) to workspace \(number)")
    }

    private func saveWorkspaceState(workspace: Int, monitor: String) {
        // Snapshot current floating window positions before saving
        for wid in floatingWindows {
            if let element = axElements[wid], let frame = AccessibilityBridge.getFrame(of: element) {
                trackedWindows[wid]?.frame = frame
            }
        }
        // Also snapshot fullscreen window positions
        for wid in fullscreenWindows {
            if let element = axElements[wid], let frame = AccessibilityBridge.getFrame(of: element) {
                trackedWindows[wid]?.frame = frame
            }
        }

        var ws = VirtualWorkspace()
        ws.tiledWindows = layoutEngine.tiledWindows
        ws.floatingWindows = floatingWindows
        ws.fullscreenWindows = fullscreenWindows
        ws.trackedWindows = trackedWindows
        ws.axElements = axElements
        ws.focusedWindowID = focusedWindowID
        ws.layoutVariant = layoutEngine.layoutVariant
        ws.splitRatio = layoutEngine.splitRatio
        ws.niriActiveColumn = layoutEngine.niriActiveColumn
        ws.niriColumns = layoutEngine.niriColumns
        WorkspaceManager.shared.workspaces[monitor, default: [:]][workspace] = ws

        // Persist to disk (debounced)
        WorkspacePersistence.save()
    }

    /// Restore floating and fullscreen windows to their saved positions after workspace switch.
    /// Tiled windows are handled by retile(); this handles non-tiled windows.
    /// Put floating and fullscreen windows back where they were.
    ///
    /// Their remembered frame is whatever they were sitting at when the workspace was
    /// last saved, and that is read live, so a window parked off-screen at that moment
    /// has the parking corner recorded as its home. Restoring it then puts it straight
    /// back off-screen, every time, and it never returns: that is how a floating window
    /// ends up permanently invisible. Refuse a remembered position that is off-screen
    /// and centre the window instead.
    private func restoreFloatingWindowPositions() {
        let screen = NSScreen.safeMain
        let screenFrame = screenFrameInAX(for: screen)

        func place(_ wid: CGWindowID) {
            guard let element = axElements[wid],
                  let tracked = trackedWindows[wid],
                  tracked.frame != .zero else { return }
            var frame = tracked.frame
            if WorkspaceManager.shared.isHiddenPosition(screenFrame: screenFrame, windowFrame: frame)
                || !AccessibilityBridge.isPlausibleFrame(frame) {
                frame = centeredFrame(for: frame.size, in: screenFrame)
                trackedWindows[wid]?.frame = frame
            }
            AccessibilityBridge.setFrame(of: element, to: frame)
        }

        for wid in floatingWindows { place(wid) }
        for wid in fullscreenWindows { place(wid) }
    }

    private func loadWorkspaceState(workspace: Int, monitor: String) {
        // Include ALL windows (active + hidden) in knownWindows so the observer
        // doesn't re-discover hidden windows as "new" on every poll cycle
        let hiddenIDs = WorkspaceManager.shared.allHiddenWindowIDs()

        // Preserve sticky windows from the previous workspace so they carry forward
        let previousStickyTracked = trackedWindows.filter { stickyWindows.contains($0.key) }
        let previousStickyElements = axElements.filter { stickyWindows.contains($0.key) }
        let previousStickyFloating = floatingWindows.intersection(stickyWindows)
        let previousStickyTiled = layoutEngine.tiledWindows.filter { stickyWindows.contains($0) }

        if let ws = WorkspaceManager.shared.workspaces[monitor]?[workspace] {
            layoutEngine.tiledWindows = ws.tiledWindows
            trackedWindows = ws.trackedWindows
            axElements = ws.axElements
            floatingWindows = ws.floatingWindows
            fullscreenWindows = ws.fullscreenWindows
            focusedWindowID = ws.focusedWindowID ?? ws.tiledWindows.first
            layoutEngine.layoutVariant = ws.layoutVariant
            layoutEngine.splitRatio = ws.splitRatio
            layoutEngine.niriActiveColumn = ws.niriActiveColumn
            layoutEngine.niriColumns = ws.niriColumns
            var allKnown = Set(ws.trackedWindows.keys)
            allKnown.formUnion(hiddenIDs)
            observer.syncKnownWindows(allKnown)
        } else {
            // Empty workspace — clear everything
            layoutEngine.tiledWindows.removeAll()
            trackedWindows.removeAll()
            axElements.removeAll()
            floatingWindows.removeAll()
            fullscreenWindows.removeAll()
            focusedWindowID = nil
            observer.syncKnownWindows(hiddenIDs)
        }

        // Merge sticky windows into the new workspace state
        for (wid, tracked) in previousStickyTracked {
            trackedWindows[wid] = tracked
        }
        for (wid, element) in previousStickyElements {
            axElements[wid] = element
        }
        floatingWindows.formUnion(previousStickyFloating)
        for wid in previousStickyTiled {
            if !layoutEngine.tiledWindows.contains(wid) {
                layoutEngine.insert(windowID: wid, afterFocused: nil)
            }
        }

        // Ensure sticky windows are included in known windows
        var currentKnown = observer.currentKnownWindows
        currentKnown.formUnion(stickyWindows)
        observer.syncKnownWindows(currentKnown)

        // Focus the workspace's focused window
        if let fid = focusedWindowID, let el = axElements[fid], let t = trackedWindows[fid] {
            AccessibilityBridge.focus(window: el, pid: t.pid)
        }
    }

    // MARK: - Force ProMotion 120Hz

    private var proMotionWindow: NSWindow?
    private var proMotionTimer: DispatchSourceTimer?

    private func startDisplayLink() {
        guard proMotionWindow == nil else { return }

        // Create a tiny 1x1 transparent window that continuously redraws,
        // forcing macOS ProMotion to stay at its max refresh rate (120Hz).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.alphaValue = 0.01  // Nearly invisible but still composited
        window.collectionBehavior = [.stationary, .canJoinAllSpaces]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        proMotionWindow = window

        // Keep ProMotion up with an animation the render server drives, not a timer we
        // drive. Marking the layer dirty from an 8ms DispatchSourceTimer woke this
        // process 125 times a second forever and was the entire idle cost of Paneless:
        // measured 2.2-2.7% CPU with it against 0.0-0.1% without. An infinite implicit
        // animation produces the same content updates from inside the compositor.
        //
        // Measured side by side, with nothing else holding the display up: timer 120Hz
        // at 0.3% of the test process, this 126Hz at 0.0%.
        let keepalive = CABasicAnimation(keyPath: "opacity")
        keepalive.fromValue = 0.01
        keepalive.toValue = 0.02
        keepalive.duration = 0.5
        keepalive.repeatCount = .infinity
        keepalive.autoreverses = true
        view.layer?.add(keepalive, forKey: "promotion-keepalive")

        panelessLog("ProMotion force enabled (120Hz keepalive, compositor driven)")
    }

    private func stopDisplayLink() {
        proMotionWindow?.contentView?.layer?.removeAnimation(forKey: "promotion-keepalive")
        proMotionTimer?.cancel()
        proMotionTimer = nil
        proMotionWindow?.orderOut(nil)
        proMotionWindow = nil
        panelessLog("ProMotion force disabled")
    }

    // MARK: - Crash Recovery

    /// Bring every parked window back on screen before shutting down.
    ///
    /// Windows on inactive workspaces live off-screen at the parking corner, which is
    /// fine while Paneless is running and can bring them back. It is not fine once it
    /// stops: the windows are then unreachable, with nothing on screen to explain where
    /// they went. Startup already recovers them, but only if Paneless is started again,
    /// and it may not be.
    ///
    /// Restore each to the frame its workspace remembers, so they land spread out where
    /// they belong rather than piled on one spot.
    private func unparkEverything() {
        let wsMgr = WorkspaceManager.shared
        var restored = 0
        for (monitorID, workspaces) in wsMgr.workspaces {
            guard let screen = NSScreen.screens.first(where: { wsMgr.screenID(for: $0) == monitorID })
                    ?? NSScreen.screens.first else { continue }
            let screenFrame = screenFrameInAX(for: screen)
            let active = wsMgr.activeWorkspace[monitorID] ?? 1
            for (number, ws) in workspaces where number != active {
                for (wid, tracked) in ws.trackedWindows {
                    guard let element = ws.axElements[wid] else { continue }
                    var frame = tracked.frame
                    if !AccessibilityBridge.isPlausibleFrame(frame)
                        || wsMgr.isHiddenPosition(screenFrame: screenFrame, windowFrame: frame) {
                        frame = CGRect(x: screenFrame.midX - frame.width / 2,
                                       y: screenFrame.midY - frame.height / 2,
                                       width: max(frame.width, 400), height: max(frame.height, 300))
                    }
                    AccessibilityBridge.setFrame(of: element, to: frame)
                    restored += 1
                }
            }
        }
        if restored > 0 {
            panelessLog("Brought \(restored) parked window(s) back on screen before shutting down")
        }
    }

    /// On launch, check for windows stuck at hidden positions (from a previous crash)
    /// and move them back on-screen.
    private func restoreOrphanedWindows() {
        let allWindows = SpaceManager.getWindowsOnCurrentSpace()
        for screen in NSScreen.screens {
            let screenFrame = screenFrameInAX(for: screen)
            for wid in allWindows {
                guard let info = SpaceManager.getWindowInfo(wid) else { continue }
                // A window we are going to lay out anyway does not need rescuing, and a
                // parked column looks exactly like a stranded one: parking leaves a single
                // pixel at the screen edge, which is the very signature this looks for.
                // Rescuing those dragged them into the middle of the display and left them
                // there, because nothing laid the strip out again afterwards.
                if engineHolding(wid) != nil { continue }
                if WorkspaceManager.shared.isHiddenPosition(screenFrame: screenFrame, windowFrame: info.frame) {
                    if let (element, _) = AccessibilityBridge.getWindows(for: info.pid).first(where: { $0.1 == wid }) {
                        let centerX = screenFrame.origin.x + screenFrame.width / 4
                        let centerY = screenFrame.origin.y + screenFrame.height / 4
                        let restoredFrame = CGRect(x: centerX, y: centerY, width: info.frame.width, height: info.frame.height)
                        AccessibilityBridge.setFrame(of: element, to: restoredFrame)
                        panelessLog("Restored orphaned window \(wid) (\(info.appName)) from hidden position")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Convert NSScreen frame to AX/Core Graphics coordinates (origin top-left of primary display)
    func screenFrameInAX(for screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let axY = primaryHeight - screen.frame.origin.y - screen.frame.height
        return CGRect(x: screen.frame.origin.x, y: axY, width: screen.frame.width, height: screen.frame.height)
    }

    func appMatchesRule(_ appName: String, bundleID: String?, rules: Set<String>) -> Bool {
        if rules.contains(appName) { return true }
        if let bid = bundleID, rules.contains(bid) { return true }
        let lowered = appName.lowercased()
        return rules.contains { $0.lowercased() == lowered }
    }

    // MARK: - Window Swallowing Helpers

    /// Get the parent PID of a process using proc_pidinfo.
    private func getParentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return nil }
        let ppid = pid_t(info.pbi_ppid)
        return ppid > 1 ? ppid : nil
    }

    /// Walk the PID chain upward to find a parent that owns a swallowable terminal window.
    /// Returns the terminal's window ID if found.
    private func findSwallowableParent(childPID: pid_t) -> CGWindowID? {
        var currentPID = childPID
        // Walk up to 5 levels (child → shell → terminal)
        for _ in 0..<5 {
            guard let parentPID = getParentPID(currentPID) else { return nil }

            // Check if any tiled window belongs to this parent PID and is a swallowable app
            for wid in layoutEngine.tiledWindows {
                guard let tracked = trackedWindows[wid],
                      tracked.pid == parentPID,
                      tracked.swallowedBy == nil  // not already swallowed
                else { continue }

                if config.swallowAll ||
                   appMatchesRule(tracked.appName, bundleID: tracked.bundleID, rules: config.swallowApps) {
                    return wid
                }
            }

            currentPID = parentPID
        }
        return nil
    }

}
