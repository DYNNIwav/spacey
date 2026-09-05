import Cocoa

protocol WindowObserverDelegate: AnyObject {
    /// Returns false when the window could not be taken on yet and should be offered
    /// again, which happens when its app has no accessibility element for it so far.
    @discardableResult
    func windowCreated(windowID: CGWindowID, pid: pid_t, appName: String) -> Bool
    func windowDestroyed(windowID: CGWindowID)
    /// Every window on the current Space with its frame, as of the latest poll.
    func windowsPolled(frames: [CGWindowID: CGRect])
    func spaceChanged()
    func focusChanged()
    func focusChanged(windowID: CGWindowID)
    func applicationLaunched(pid: pid_t, name: String)
    func applicationTerminated(pid: pid_t, name: String)
    func applicationActivated(pid: pid_t, name: String)
    func axElementDestroyed(element: AXUIElement)
}

class WindowObserver {
    weak var delegate: WindowObserverDelegate?

    private var knownWindows: Set<CGWindowID> = []
    private var pollingTimer: Timer?
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Burst-poll timer (50ms interval) for fast detection
    private var burstTimer: Timer?
    private var burstEndTime: Date?

    /// Pause/resume support to prevent race conditions during workspace switching
    private(set) var isPaused = false

    func pause() { isPaused = true }
    func resume() {
        isPaused = false
        pollWindows()
    }

    // Adaptive polling state
    private var lastChangeTime: Date = Date()
    private var currentPollInterval: TimeInterval = 0.5
    private let fastPollInterval: TimeInterval = 0.5
    private let slowPollInterval: TimeInterval = 3.0
    private let slowdownThreshold: TimeInterval = 5.0  // go slow after 5s of no changes

    // MARK: - Background Window Interceptor
    // Runs CGWindowList polling on a HIGH PRIORITY background thread during
    // app launches. Catches new windows at the WindowServer level and hides
    // them (alpha=0) before AX notifications even fire. This prevents the
    // flash of the window at its default position for slow apps.

    private let interceptorQueue = DispatchQueue(label: "com.paneless.interceptor", qos: .userInteractive)
    private var interceptorTimer: DispatchSourceTimer?
    /// Thread-safe snapshot of known window IDs for the interceptor
    private var interceptorKnown = Set<CGWindowID>()
    /// Windows already hidden by the interceptor (so we don't double-hide)
    private var interceptorHidden = Set<CGWindowID>()
    private let interceptorLock = NSLock()

    func start() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(spaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addAXObserver(for: app.processIdentifier)
        }

        // Start adaptive polling
        schedulePoll()

        pollWindows()
        panelessLog("Window observer started (adaptive polling)")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollingTimer?.invalidate()
        pollingTimer = nil
        burstTimer?.invalidate()
        burstTimer = nil
        stopInterceptor()

        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                 AXObserverGetRunLoopSource(observer),
                                 .defaultMode)
        }
        axObservers.removeAll()
    }

    var currentKnownWindows: Set<CGWindowID> { knownWindows }

    func syncKnownWindows(_ windows: Set<CGWindowID>) {
        knownWindows = windows
    }

    func triggerPoll() {
        pollWindows()
    }

    func startBurstPolling(duration: TimeInterval = 2.0) {
        burstEndTime = Date(timeIntervalSinceNow: duration)

        guard burstTimer == nil else { return }

        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            self.pollWindows()

            if let endTime = self.burstEndTime, Date() > endTime {
                timer.invalidate()
                self.burstTimer = nil
                self.burstEndTime = nil
            }
        }
    }

    /// Start the background window interceptor. Runs CGWindowList polling at
    /// ~8ms (display refresh rate) on a high-priority background thread.
    /// Any new window ID that appears is IMMEDIATELY hidden (alpha=0) before
    /// a single frame can render at the app's default position.
    func startInterceptor(duration: TimeInterval = 5.0) {
        // Sync current known windows to the interceptor
        interceptorLock.lock()
        interceptorKnown = knownWindows
        interceptorLock.unlock()

        // If already running, just extend the duration
        if interceptorTimer != nil { return }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let endTime = CACurrentMediaTime() + duration

        let timer = DispatchSource.makeTimerSource(queue: interceptorQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            if CACurrentMediaTime() > endTime {
                self.stopInterceptor()
                return
            }

            // Fast CGWindowList scan — same query as SpaceManager but inline
            // to avoid crossing to main thread
            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return }

            self.interceptorLock.lock()
            let known = self.interceptorKnown
            var hidden = self.interceptorHidden
            self.interceptorLock.unlock()

            for info in windowList {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                      let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                      let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let width = bounds["Width"], let height = bounds["Height"],
                      width > 50, height > 50
                else { continue }

                if ownerPID == myPID { continue }

                // New window we haven't seen. This loop runs every 8ms on a high
                // priority thread, so it knows about the window long before the ordinary
                // poll does. It used to only call CGSSetWindowAlpha, which does nothing
                // at all to a window owned by another process, so all that head start
                // was thrown away and the window sat visible where the app put it for a
                // further 200ms. Tell the manager at once instead.
                if !known.contains(windowID) && !hidden.contains(windowID) {
                    hidden.insert(windowID)
                    let name = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, !self.isPaused else { return }
                        self.delegate?.windowCreated(windowID: windowID, pid: ownerPID, appName: name)
                    }
                }
            }

            self.interceptorLock.lock()
            self.interceptorHidden = hidden
            self.interceptorLock.unlock()
        }

        interceptorTimer = timer
        timer.resume()
    }

    private func stopInterceptor() {
        interceptorTimer?.cancel()
        interceptorTimer = nil
        interceptorLock.lock()
        interceptorHidden.removeAll()
        interceptorLock.unlock()
    }

    /// Notify the interceptor that a window is now known (so it stops hiding it)
    func interceptorAcknowledge(_ windowID: CGWindowID) {
        interceptorLock.lock()
        interceptorKnown.insert(windowID)
        interceptorHidden.remove(windowID)
        interceptorLock.unlock()
    }

    // MARK: - Adaptive Polling

    private func schedulePoll() {
        pollingTimer?.invalidate()

        // Adaptive interval: fast when changes are happening, slow when idle
        let timeSinceLastChange = Date().timeIntervalSince(lastChangeTime)
        currentPollInterval = timeSinceLastChange > slowdownThreshold ? slowPollInterval : fastPollInterval

        pollingTimer = Timer.scheduledTimer(withTimeInterval: currentPollInterval, repeats: false) { [weak self] _ in
            self?.pollWindows()
            self?.schedulePoll()
        }
    }

    private func markActivity() {
        let wasIdle = Date().timeIntervalSince(lastChangeTime) > slowdownThreshold
        lastChangeTime = Date()

        // If we were in slow mode, immediately switch to fast polling
        if wasIdle {
            schedulePoll()
        }
    }

    // MARK: - Workspace Notifications

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        addAXObserver(for: app.processIdentifier)
        delegate?.applicationLaunched(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")

        markActivity()
        startBurstPolling(duration: 3.0)

        // Start background interceptor — catches windows at WindowServer level
        // before AX notifications fire, hiding them instantly (alpha=0)
        startInterceptor(duration: 5.0)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        removeAXObserver(for: app.processIdentifier)
        delegate?.applicationTerminated(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")
        markActivity()
    }

    @objc private func spaceChanged(_ notification: Notification) {
        // With virtual workspaces, native space changes are informational only.
        delegate?.spaceChanged()
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        delegate?.applicationActivated(pid: app.processIdentifier, name: app.localizedName ?? "Unknown")
    }

    // MARK: - Polling

    /// Windows the delegate has seen but could not take on yet: when first offered and
    /// when last tried. A window whose app has not built its accessibility tree yet has
    /// no element to move, and used to be written off after that one look. Keep offering
    /// it for a while, a little apart, before giving up on it.
    private var pendingAdoption: [CGWindowID: (firstSeen: Date, lastTry: Date)] = [:]
    private let adoptionRetryFor: TimeInterval = 3.0
    private let adoptionRetrySpacing: TimeInterval = 0.1

    private func pollWindows() {
        guard !isPaused else { return }
        let frames = SpaceManager.getWindowFramesOnCurrentSpace()
        let currentWindows = Set(frames.keys)
        let now = Date()
        pendingAdoption = pendingAdoption.filter { currentWindows.contains($0.key) }

        let newWindows = currentWindows.subtracting(knownWindows)
        let conn = CGSMainConnectionID()
        for windowID in newWindows {
            let pending = pendingAdoption[windowID]
            if let pending = pending {
                if now.timeIntervalSince(pending.lastTry) < adoptionRetrySpacing { continue }
                if now.timeIntervalSince(pending.firstSeen) > adoptionRetryFor {
                    // Give up: from here on it is just a window we know about.
                    pendingAdoption.removeValue(forKey: windowID)
                    continue
                }
            }

            // Pre-hide new windows before notifying delegate. The background
            // interceptor may have already hidden this window, which is fine:
            // CGSSetWindowAlpha is idempotent.
            CGSSetWindowAlpha(conn, windowID, 0.0)

            // Tell the interceptor we've claimed this window
            interceptorAcknowledge(windowID)

            if let info = SpaceManager.getWindowInfo(windowID) {
                let adopted = delegate?.windowCreated(windowID: windowID, pid: info.pid, appName: info.appName) ?? true
                markActivity()
                if adopted {
                    pendingAdoption.removeValue(forKey: windowID)
                } else {
                    pendingAdoption[windowID] = (pending?.firstSeen ?? now, now)
                    CGSSetWindowAlpha(conn, windowID, 1.0)
                }
            } else {
                // Can't get info, so restore alpha rather than leave the window stuck invisible
                CGSSetWindowAlpha(conn, windowID, 1.0)
            }
        }

        let removedWindows = knownWindows.subtracting(currentWindows)
        for windowID in removedWindows {
            delegate?.windowDestroyed(windowID: windowID)
            markActivity()
        }

        // A window still pending stays unknown, so the next poll offers it again.
        knownWindows = currentWindows.subtracting(pendingAdoption.keys)

        delegate?.windowsPolled(frames: frames)
    }

    // MARK: - AX Observers

    private func addAXObserver(for pid: pid_t) {
        guard axObservers[pid] == nil else { return }

        var observer: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &observer)
        guard err == .success, let observer = observer else { return }

        let appRef = AXUIElementCreateApplication(pid)

        let refPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, appRef,
                                  kAXWindowCreatedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXUIElementDestroyedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXFocusedWindowChangedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXWindowMiniaturizedNotification as CFString, refPtr)
        AXObserverAddNotification(observer, appRef,
                                  kAXWindowDeminiaturizedNotification as CFString, refPtr)

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
        axObservers[pid] = observer
    }

    private func removeAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }
}

// MARK: - AX Observer Callback

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let windowObserver = Unmanaged<WindowObserver>.fromOpaque(userData).takeUnretainedValue()
    let notifName = notification as String

    // Extract window ID from the notification element immediately (before async dispatch)
    // so we don't lose it to a race condition with NSWorkspace.frontmostApplication
    var notifWindowID: CGWindowID = 0
    if notifName == kAXFocusedWindowChangedNotification as String ||
       notifName == kAXWindowCreatedNotification as String {
        _ = _AXUIElementGetWindow(element, &notifWindowID)
    }

    // CRITICAL: Hide newly created windows IMMEDIATELY — before the main queue
    // dispatch. This prevents the window from ever being visible at the app's
    // default position. CGS calls are thread-safe for the main connection.
    // The Animator will fade the window in at the correct tiled position.
    if notifName == kAXWindowCreatedNotification as String && notifWindowID != 0 {
        let conn = CGSMainConnectionID()
        CGSSetWindowAlpha(conn, notifWindowID, 0.0)
    }

    DispatchQueue.main.async {
        // Skip all processing while paused (during workspace switching)
        guard !windowObserver.isPaused else { return }

        // Pass the window ID directly from the AX notification element.
        // This avoids a race where NSWorkspace.frontmostApplication hasn't
        // updated yet when the user clicks a window with the mouse.
        if notifName == kAXFocusedWindowChangedNotification as String {
            if notifWindowID != 0 {
                windowObserver.delegate?.focusChanged(windowID: notifWindowID)
            } else {
                windowObserver.delegate?.focusChanged()
            }
        }

        // Report destroyed elements directly. CGWindowList still lists a window for
        // a while after the app tears it down, so the poll below cannot see this yet;
        // the delegate matches the element against the windows it tracks instead.
        if notifName == kAXUIElementDestroyedNotification as String {
            windowObserver.delegate?.axElementDestroyed(element: element)
        }

        // A new window is often not in CGWindowList yet when this notification lands,
        // so the single poll below misses it and detection falls to the next ordinary
        // tick, up to 500ms later. Measured: 190ms before Paneless even saw a new Mail
        // window. Burst-poll instead so we catch it within one 50ms tick. Only fires
        // for real window creation, not for every destroyed menu or popover.
        if notifName == kAXWindowCreatedNotification as String {
            windowObserver.startBurstPolling(duration: 1.0)
        }

        windowObserver.triggerPoll()
    }
}
