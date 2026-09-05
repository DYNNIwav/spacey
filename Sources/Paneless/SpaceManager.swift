import Cocoa

enum SpaceManager {

    // MARK: - Multi-Monitor

    /// Get the screen containing a specific point (AX coordinates)
    static func screen(containing point: CGPoint) -> NSScreen? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let screenHeight = primaryScreen.frame.height

        // Convert AX point to Cocoa point
        let cocoaPoint = NSPoint(x: point.x, y: screenHeight - point.y)

        for screen in NSScreen.screens {
            if screen.frame.contains(cocoaPoint) {
                return screen
            }
        }
        return NSScreen.main
    }

    /// Get the neighbor screen in a direction
    static func neighborScreen(of current: NSScreen, direction: Direction) -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return nil }

        let cx = current.frame.midX
        let cy = current.frame.midY

        var bestScreen: NSScreen?
        var bestDistance: CGFloat = .infinity

        for screen in screens where screen != current {
            let ox = screen.frame.midX
            let oy = screen.frame.midY

            let isInDirection: Bool
            switch direction {
            case .left: isInDirection = ox < cx
            case .right: isInDirection = ox > cx
            case .up: isInDirection = oy > cy     // Cocoa coords: up = higher y
            case .down: isInDirection = oy < cy
            }

            guard isInDirection else { continue }

            let distance = hypot(ox - cx, oy - cy)
            if distance < bestDistance {
                bestDistance = distance
                bestScreen = screen
            }
        }

        return bestScreen
    }

    // MARK: - Window Enumeration

    /// Ordinary windows on the current Space, front to back, as the window server lists them.
    static func getWindowsOnCurrentSpace() -> [CGWindowID] {
        return onScreenWindows().map { $0.windowID }
    }

    /// The same windows with their frames, in the same coordinates the AX API uses.
    static func getWindowFramesOnCurrentSpace() -> [CGWindowID: CGRect] {
        var frames: [CGWindowID: CGRect] = [:]
        for window in onScreenWindows() { frames[window.windowID] = window.frame }
        return frames
    }

    private static func onScreenWindows() -> [(windowID: CGWindowID, frame: CGRect)] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var windows: [(windowID: CGWindowID, frame: CGRect)] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 50, height > 50
            else { continue }

            if ownerPID == myPID { continue }

            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            windows.append((windowID, frame))
        }

        return windows
    }

    static func getWindowInfo(_ windowID: CGWindowID) -> (pid: pid_t, appName: String, bundleID: String?, frame: CGRect)? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for info in windowList {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID, wid == windowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let name = info[kCGWindowOwnerName as String] as? String,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return (pid, name, bundleID, frame)
        }

        return nil
    }
}
