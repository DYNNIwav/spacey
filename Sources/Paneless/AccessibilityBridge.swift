import Cocoa

enum AccessibilityBridge {

    /// Get the focused window's AXUIElement, CGWindowID, and owner PID
    static func getFocusedWindow() -> (AXUIElement, CGWindowID, pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowElement = focusedWindow else { return nil }

        var windowID: CGWindowID = 0
        let err = _AXUIElementGetWindow(windowElement as! AXUIElement, &windowID)
        guard err == .success, windowID != 0 else { return nil }

        return (windowElement as! AXUIElement, windowID, app.processIdentifier)
    }

    static func getFocusedWindowID() -> CGWindowID? {
        return getFocusedWindow()?.1
    }

    // MARK: - Frame Operations

    static func getFrame(of element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    static func setFrame(of element: AXUIElement, to rect: CGRect) {
        guard isPlausibleFrame(rect) else { return }
        // Disable AXEnhancedUserInterface to prevent app-side animations.
        // Same workaround used by Amethyst/Silica and yabai.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appRef = pid != 0 ? AXUIElementCreateApplication(pid) : nil

        var wasEnhanced = false
        if let appRef = appRef {
            var enhancedValue: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &enhancedValue) == .success {
                wasEnhanced = (enhancedValue as? Bool) ?? false
            }
            if wasEnhanced {
                AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        // Set size -> position -> size to handle apps that constrain position based on size
        var size = rect.size
        var position = rect.origin

        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }

        // Restore AXEnhancedUserInterface
        if wasEnhanced, let appRef = appRef {
            AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Whether a frame is safe to hand to another application.
    ///
    /// Not defensive programming for its own sake. On 18 August 2026 this machine
    /// kernel panicked: a window was given an absurd geometry, the window server tried
    /// to allocate a 111848100 x 1544 Metal surface, failed, crashed twice and stopped
    /// checking in, and the kernel watchdog rebooted the machine after 121 seconds.
    /// Frames are computed 120 times a second and sent straight into other processes,
    /// so one NaN or overflow is not a visual glitch, it is a lost session. This is the
    /// single choke point every frame passes through, so the check belongs here.
    static func isPlausibleFrame(_ r: CGRect) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite,
              r.size.width.isFinite, r.size.height.isFinite else { return false }
        guard r.width >= 1, r.height >= 1 else { return false }

        let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let limit = bounds.isNull ? CGRect(x: 0, y: 0, width: 8000, height: 8000) : bounds
        guard r.width <= limit.width * 4, r.height <= limit.height * 4 else { return false }

        // A screen's worth of slack outside the desktop, since parking puts windows
        // deliberately off-screen.
        let slack = max(limit.width, limit.height)
        return r.origin.x > limit.minX - slack && r.origin.x < limit.maxX + slack
            && r.origin.y > limit.minY - slack && r.origin.y < limit.maxY + slack
    }

    /// Lean frame set for use inside an animation. Skips the AXEnhancedUserInterface
    /// dance that `setFrame` does per call, because that costs two extra IPC round
    /// trips to the app every time. Toggle it once around the whole animation with
    /// `setEnhancedUI` instead. Safe to call off the main thread.
    static func setFrameDuringAnimation(of element: AXUIElement, to rect: CGRect, setSize: Bool = true) {
        guard isPlausibleFrame(rect) else { return }
        // Size is the expensive half by a wide margin: measured medians per call are
        // 0.2-2ms for position against 5ms for Ghostty and 25-53ms for Safari, because
        // the app has to lay its content out again. Skipping it when it cannot change
        // anything is the difference between 120fps and 20fps.
        if setSize {
            var size = rect.size
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
        }
        var position = rect.origin
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        }
    }

    /// Cap how long an AX call on this element may block. The system default is several
    /// seconds, so one hung app can otherwise wedge an animation loop for that long.
    /// Generous next to the slowest resize measured here (Safari, 51.75ms) and far below
    /// the default. The cap sticks to the element for every later call, so pass 0 to
    /// restore the default once the animation is over.
    static func limitMessagingTime(of element: AXUIElement, to seconds: Float = 0.25) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// Turn AXEnhancedUserInterface off (or back on) for a set of apps. Off stops the
    /// app running its own animation on top of ours, which is what makes windows drift.
    /// Returns the pids that actually had it enabled, so they can be restored.
    @discardableResult
    static func setEnhancedUI(pids: Set<pid_t>, enabled: Bool) -> Set<pid_t> {
        var changed = Set<pid_t>()
        for pid in pids where pid != 0 {
            let appRef = AXUIElementCreateApplication(pid)
            var value: AnyObject?
            let has = AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &value) == .success
            let current = has ? ((value as? Bool) ?? false) : false
            if current != enabled {
                AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString,
                                             enabled ? kCFBooleanTrue : kCFBooleanFalse)
                changed.insert(pid)
            }
        }
        return changed
    }

    /// Batch set frames for multiple windows. Disables AXEnhancedUserInterface once per app
    /// instead of once per window, reducing IPC overhead significantly.
    static func batchSetFrames(_ rawFrames: [(element: AXUIElement, frame: CGRect)]) {
        let frames = rawFrames.filter { isPlausibleFrame($0.frame) }
        guard !frames.isEmpty else { return }

        // Phase 1: Disable AXEnhancedUserInterface for all unique apps
        var pidApps: [pid_t: (appRef: AXUIElement, wasEnhanced: Bool)] = [:]

        for (element, _) in frames {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard pid != 0, pidApps[pid] == nil else { continue }

            let appRef = AXUIElementCreateApplication(pid)
            var enhancedValue: AnyObject?
            var wasEnhanced = false
            if AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &enhancedValue) == .success {
                wasEnhanced = (enhancedValue as? Bool) ?? false
            }
            if wasEnhanced {
                AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            pidApps[pid] = (appRef, wasEnhanced)
        }

        // Phase 2: Set all frames (size -> position -> size for each)
        for (element, rect) in frames {
            var size = rect.size
            var position = rect.origin

            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            }
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
        }

        // Phase 3: Restore AXEnhancedUserInterface for apps that had it
        for (_, (appRef, wasEnhanced)) in pidApps where wasEnhanced {
            AXUIElementSetAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - Window Enumeration

    /// Find one window's AX element without building the app's whole window list.
    ///
    /// `kAXWindows` makes the app enumerate everything it has, and until we hold an
    /// element we cannot move the window, so that wait is time a brand new window spends
    /// sitting visibly wherever the app put it. A window that has just opened is almost
    /// always the focused one, so try that single attribute first and only fall back to
    /// the full list if it is something else.
    static func windowElement(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let element = focused {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(element as! AXUIElement, &wid) == .success, wid == windowID {
                return (element as! AXUIElement)
            }
        }
        return getWindows(for: pid).first(where: { $0.1 == windowID })?.0
    }

    static func getWindows(for pid: pid_t) -> [(AXUIElement, CGWindowID)] {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return [] }

        var result: [(AXUIElement, CGWindowID)] = []
        for window in windows {
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 {
                result.append((window, windowID))
            }
        }
        return result
    }

    // MARK: - Window Actions

    static func focus(window element: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    /// Focus a window using only AX attributes — no app activation of any kind.
    /// Safe to call during space transitions. Both NSRunningApplication.activate()
    /// and kAXFrontmostAttribute cause macOS to switch spaces when apps have
    /// windows on multiple spaces.
    static func focusLocally(window element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func close(window element: AXUIElement) {
        var closeButton: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton) == .success
        else { return }
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        var minimized: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
        return (minimized as? Bool) ?? false
    }

    static func getTitle(of element: AXUIElement) -> String? {
        var title: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    /// Check if a window is a dialog, sheet, or utility panel that should auto-float.
    static func isDialog(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleStr = subrole as? String {
            let dialogRoles: Set<String> = [
                "AXDialog", "AXSheet", "AXFloatingWindow",
                "AXSystemDialog", "AXSystemFloatingWindow"
            ]
            if dialogRoles.contains(subroleStr) {
                return true
            }
        }
        return false
    }

    /// Check if a window is small enough to be considered a popup/dialog.
    /// Threshold: below 500x400 is likely a dialog or utility.
    static func isSmallWindow(_ element: AXUIElement, threshold: CGSize = CGSize(width: 500, height: 400)) -> Bool {
        guard let frame = getFrame(of: element) else { return false }
        return frame.width < threshold.width && frame.height < threshold.height
    }

    // MARK: - Menu Item Traversal

    /// Find a menu item by traversing the AX menu bar hierarchy.
    /// Path example: ["Window", "Move & Resize", "Left Half"]
    /// Returns the AXUIElement of the menu item if found.
    static func findMenuItem(pid: pid_t, path: [String]) -> AXUIElement? {
        guard !path.isEmpty else { return nil }

        let app = AXUIElementCreateApplication(pid)

        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBarElement = menuBar
        else { return nil }

        var current: AXUIElement = menuBarElement as! AXUIElement

        for (depth, name) in path.enumerated() {
            var children: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
                  let items = children as? [AXUIElement]
            else { return nil }

            var found: AXUIElement?
            for item in items {
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title) == .success,
                   let titleStr = title as? String, titleStr == name {
                    found = item
                    break
                }
            }

            guard let matchedItem = found else { return nil }

            // If this is not the last path component, descend into its submenu
            if depth < path.count - 1 {
                // Menu bar items and menu items with submenus have children that are the submenu
                var submenuChildren: AnyObject?
                if AXUIElementCopyAttributeValue(matchedItem, kAXChildrenAttribute as CFString, &submenuChildren) == .success,
                   let submenus = submenuChildren as? [AXUIElement], let submenu = submenus.first {
                    current = submenu
                } else {
                    return nil
                }
            } else {
                return matchedItem
            }
        }

        return nil
    }

    /// Press a menu item found by path. Returns true if the action was performed.
    @discardableResult
    static func pressMenuItem(pid: pid_t, path: [String]) -> Bool {
        guard let menuItem = findMenuItem(pid: pid, path: path) else { return false }
        return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
    }

    // MARK: - Window Tiling via Menu Items

    /// Find the Window menu for an app. Tries English "Window" first, then
    /// scans all top-level menus for one containing a "Fill" or "Move & Resize" child item
    /// (handles localized menus like Norwegian "Vindu", German "Fenster", etc.).
    private static func findWindowMenu(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success
        else { return nil }

        let menuBarElement = menuBar as! AXUIElement

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &children) == .success,
              let topItems = children as? [AXUIElement]
        else { return nil }

        // First pass: try known Window menu names
        let knownNames: Set<String> = ["Window", "Vindu", "Fenster", "Fenêtre", "Ventana", "Finestra", "Janela", "Fönster", "Ikkuna", "Vindue"]
        for item in topItems {
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title) == .success,
               let name = title as? String, knownNames.contains(name) {
                return item
            }
        }

        // Second pass: find a menu that contains "Fill" or "Move & Resize" as direct children
        // (these are macOS-injected items present in all apps on Sequoia+)
        for item in topItems {
            var subChildren: AnyObject?
            guard AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subChildren) == .success,
                  let subMenus = subChildren as? [AXUIElement], let subMenu = subMenus.first
            else { continue }

            var menuItems: AnyObject?
            guard AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
                  let items = menuItems as? [AXUIElement]
            else { continue }

            for menuItem in items {
                var itemTitle: AnyObject?
                if AXUIElementCopyAttributeValue(menuItem, kAXTitleAttribute as CFString, &itemTitle) == .success,
                   let name = itemTitle as? String {
                    if name == "Fill" || name == "Minimize" || name == "Move & Resize" {
                        return item
                    }
                }
            }
        }

        return nil
    }

    /// Find a child menu item by title within a menu's submenu.
    private static func findChildItem(in menuBarItem: AXUIElement, title: String) -> AXUIElement? {
        var subChildren: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &subChildren) == .success,
              let subMenus = subChildren as? [AXUIElement], let subMenu = subMenus.first
        else { return nil }

        var menuItems: AnyObject?
        guard AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
              let items = menuItems as? [AXUIElement]
        else { return nil }

        for item in items {
            var itemTitle: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle) == .success,
               let name = itemTitle as? String, name == title {
                return item
            }
        }
        return nil
    }

    /// Find a submenu item within a parent menu item (e.g., "Left" inside "Move & Resize").
    private static func findSubmenuItem(in parentItem: AXUIElement, title: String) -> AXUIElement? {
        var subChildren: AnyObject?
        guard AXUIElementCopyAttributeValue(parentItem, kAXChildrenAttribute as CFString, &subChildren) == .success,
              let subMenus = subChildren as? [AXUIElement], let subMenu = subMenus.first
        else { return nil }

        var menuItems: AnyObject?
        guard AXUIElementCopyAttributeValue(subMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
              let items = menuItems as? [AXUIElement]
        else { return nil }

        for item in items {
            var itemTitle: AnyObject?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle) == .success,
               let name = itemTitle as? String, name == title {
                return item
            }
        }
        return nil
    }

    /// Press a Window tiling menu item. Handles the two structures:
    /// - Direct items: Fill, Center (Window > Fill)
    /// - Submenu items: Left, Right, etc. (Window > Move & Resize > Left)
    @discardableResult
    static func pressWindowTileItem(pid: pid_t, action: NativeTiling.NativeTileAction) -> Bool {
        guard let windowMenu = findWindowMenu(pid: pid) else {
            panelessLog("pressWindowTileItem: no Window menu for pid \(pid)")
            return false
        }

        let menuItem: AXUIElement?

        switch action {
        case .fill:
            menuItem = findChildItem(in: windowMenu, title: "Fill")
        case .center:
            menuItem = findChildItem(in: windowMenu, title: "Center")
        default:
            let submenuTitle: String
            switch action {
            case .left:        submenuTitle = "Left"
            case .right:       submenuTitle = "Right"
            case .top:         submenuTitle = "Top"
            case .bottom:      submenuTitle = "Bottom"
            case .topLeft:     submenuTitle = "Top Left"
            case .topRight:    submenuTitle = "Top Right"
            case .bottomLeft:  submenuTitle = "Bottom Left"
            case .bottomRight: submenuTitle = "Bottom Right"
            default:           return false
            }

            guard let moveResize = findChildItem(in: windowMenu, title: "Move & Resize") else {
                panelessLog("pressWindowTileItem: 'Move & Resize' not found for pid \(pid)")
                return false
            }
            menuItem = findSubmenuItem(in: moveResize, title: submenuTitle)
        }

        guard let item = menuItem else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

}
