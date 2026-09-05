import Cocoa

/// Layout application using AX frame setting with smooth animation.
/// Calculates simple layouts (fill, halves, quarters) and uses the Animator
/// for smooth frame interpolation via the compositor.
enum NativeTiling {

    // Layout variants
    static let variantCount = 3
    // 0 = side-by-side (default)
    // 1 = stacked (top/bottom)
    // 2 = monocle (all fill, overlapping)

    // MARK: - Native Menu-Based Tiling (macOS Sequoia+)

    /// macOS tiling actions available under the Window menu (Sequoia+).
    /// These trigger native compositor-driven animation (GPU texture movement,
    /// zero content redraw) — the smoothest possible window animation on macOS.
    ///
    /// Menu structure (from AX dump):
    ///   Window > Fill                          (direct child)
    ///   Window > Center                        (direct child)
    ///   Window > Move & Resize > Left          (submenu)
    ///   Window > Move & Resize > Right         (submenu)
    ///   Window > Move & Resize > Top Left      (submenu)
    ///   ...etc
    enum NativeTileAction {
        case fill          // Window > Fill (direct)
        case center        // Window > Center (direct)
        case left          // Window > Move & Resize > Left
        case right         // Window > Move & Resize > Right
        case top           // Window > Move & Resize > Top
        case bottom        // Window > Move & Resize > Bottom
        case topLeft       // Window > Move & Resize > Top Left
        case topRight      // Window > Move & Resize > Top Right
        case bottomLeft    // Window > Move & Resize > Bottom Left
        case bottomRight   // Window > Move & Resize > Bottom Right
    }

    /// Whether menu-based tiling can be used for the given layout.
    /// Requires: standard split ratio (0.5), variant 0 (side-by-side) or 1 (stacked),
    /// window count 1-4, and not monocle mode.
    static func canUseMenuTiling(count: Int, splitRatio: CGFloat, variant: Int) -> Bool {
        guard count >= 1 && count <= 4 else { return false }
        guard abs(splitRatio - 0.5) < 0.01 else { return false }
        guard variant == 0 || variant == 1 else { return false }
        return true
    }

    /// Tile a single window via the macOS Window menu items.
    /// The window's owning app must be focused for the menu item to apply to it.
    /// Returns true if the menu item was found and pressed.
    @discardableResult
    static func tileViaMenu(pid: pid_t, action: NativeTileAction) -> Bool {
        return AccessibilityBridge.pressWindowTileItem(pid: pid, action: action)
    }

    /// Determine the native tile actions for a given layout configuration.
    /// Returns nil if the layout cannot be expressed with native tiling.
    static func menuActionsForLayout(count: Int, variant: Int) -> [NativeTileAction]? {
        switch (count, variant) {
        case (1, _):
            return [.fill]
        case (2, 0): // side-by-side
            return [.left, .right]
        case (2, 1): // stacked
            return [.top, .bottom]
        case (3, 0): // left half + two right quarters
            return [.left, .topRight, .bottomRight]
        case (3, 1): // three rows — no native equivalent for 1/3 splits
            return nil
        case (4, 0): // four quarters
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case (4, 1): // four rows — no native equivalent
            return nil
        default:
            return nil
        }
    }

    /// Apply layout using native macOS menu tiling for compositor-driven animation.
    /// Each window is focused then tiled via the menu item, producing smooth native animation.
    /// Returns true if all windows were tiled successfully, false if any failed (caller should fall back).
    @discardableResult
    static func applyViaMenu(
        windows: [(windowID: CGWindowID, element: AXUIElement, pid: pid_t)],
        variant: Int
    ) -> Bool {
        guard let actions = menuActionsForLayout(count: windows.count, variant: variant) else {
            return false
        }

        guard windows.count == actions.count else { return false }

        var allSucceeded = true

        for (i, window) in windows.enumerated() {
            // Focus the window so the menu item applies to it
            AccessibilityBridge.focus(window: window.element, pid: window.pid)

            // Brief pause to let focus take effect before pressing the menu item.
            // Without this, the menu item may apply to the previously focused window.
            usleep(50_000) // 50ms

            if !tileViaMenu(pid: window.pid, action: actions[i]) {
                allSucceeded = false
            }
        }

        return allSucceeded
    }

    // MARK: - Frame Calculation

    /// Calculate layout frames for 1-4 windows.
    /// - Parameters:
    ///   - singleWindowPadding: Extra padding when only 1 window is tiled (0 = fill)
    ///   - splitRatio: Ratio of first window to remaining (0.2-0.8, default 0.5)
    ///   - variant: Layout variant (0=side-by-side, 1=stacked, 2=monocle)
    static func calculateFrames(count: Int, region: TilingRegion, gap: CGFloat,
                                singleWindowPadding: CGFloat = 0,
                                splitRatio: CGFloat = 0.5,
                                variant: Int = 0) -> [CGRect] {
        let halfGap = gap / 2

        guard count > 0 else { return [] }

        // Monocle: all windows get the same fill frame
        if variant == 2 {
            let frame = CGRect(
                x: region.x + halfGap,
                y: region.y + halfGap,
                width: max(region.width - gap, 100),
                height: max(region.height - gap, 100)
            )
            return Array(repeating: frame, count: count)
        }

        switch count {
        case 1:
            let pad = singleWindowPadding
            if pad == 0 {
                // No padding: remove all gaps for true fullscreen feel
                return [CGRect(
                    x: region.x,
                    y: region.y,
                    width: max(region.width, 100),
                    height: max(region.height, 100)
                )]
            }
            return [CGRect(
                x: region.x + halfGap + pad,
                y: region.y + halfGap + pad,
                width: max(region.width - gap - pad * 2, 100),
                height: max(region.height - gap - pad * 2, 100)
            )]

        case 2:
            if variant == 1 {
                // Stacked: top/bottom
                let topH = region.height * splitRatio
                let botH = region.height * (1.0 - splitRatio)
                return [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(region.width - gap, 100), height: max(topH - gap, 100)),
                    CGRect(x: region.x + halfGap, y: region.y + topH + halfGap,
                           width: max(region.width - gap, 100), height: max(botH - gap, 100))
                ]
            } else {
                // Side by side
                let leftW = region.width * splitRatio
                let rightW = region.width * (1.0 - splitRatio)
                return [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(leftW - gap, 100), height: max(region.height - gap, 100)),
                    CGRect(x: region.x + leftW + halfGap, y: region.y + halfGap,
                           width: max(rightW - gap, 100), height: max(region.height - gap, 100))
                ]
            }

        case 3:
            if variant == 1 {
                // Stacked: three rows
                let rowH = region.height / 3.0
                return (0..<3).map { i in
                    CGRect(x: region.x + halfGap, y: region.y + rowH * CGFloat(i) + halfGap,
                           width: max(region.width - gap, 100), height: max(rowH - gap, 100))
                }
            } else {
                // Left half + top-right quarter + bottom-right quarter
                let leftW = region.width * splitRatio
                let rightW = region.width * (1.0 - splitRatio)
                let halfHeight = region.height / 2.0
                return [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(leftW - gap, 100), height: max(region.height - gap, 100)),
                    CGRect(x: region.x + leftW + halfGap, y: region.y + halfGap,
                           width: max(rightW - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + leftW + halfGap, y: region.y + halfHeight + halfGap,
                           width: max(rightW - gap, 100), height: max(halfHeight - gap, 100))
                ]
            }

        default:
            if variant == 1 {
                // Stacked: equal rows
                let rowH = region.height / CGFloat(count)
                return (0..<count).map { i in
                    CGRect(x: region.x + halfGap, y: region.y + rowH * CGFloat(i) + halfGap,
                           width: max(region.width - gap, 100), height: max(rowH - gap, 100))
                }
            } else {
                // 4+ windows: four quarters
                let halfWidth = region.width / 2.0
                let halfHeight = region.height / 2.0
                var frames = [
                    CGRect(x: region.x + halfGap, y: region.y + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + halfWidth + halfGap, y: region.y + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + halfGap, y: region.y + halfHeight + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100)),
                    CGRect(x: region.x + halfWidth + halfGap, y: region.y + halfHeight + halfGap,
                           width: max(halfWidth - gap, 100), height: max(halfHeight - gap, 100))
                ]
                for _ in 4..<count { frames.append(frames[3]) }
                return frames
            }
        }
    }

    // MARK: - Niri Scrolling Column Layout

    struct NiriColumnResult {
        let columnIndex: Int
        let windowFrames: [(windowID: CGWindowID, frame: CGRect)]
        let isVisible: Bool
    }

    /// Calculate frames for Niri scrolling column mode.
    /// Each column may contain multiple windows stacked vertically.
    /// The active column is centered on screen; off-screen columns are hidden.
    /// Split a rect between n windows, always cutting the longer side.
    ///
    /// The same rule every BSP tiler uses, and it needs no configuration because it
    /// gives the most square pane available at every count: two windows in a tall column
    /// end up one above the other, two in a wide one end up side by side, and four end up
    /// in a 2x2 whose panes have the same proportions the whole column had.
    static func splitEvenly(_ rect: CGRect, count n: Int) -> [CGRect] {
        guard n > 1 else { return n == 1 ? [rect] : [] }
        let a = n / 2, b = n - a
        let fa = CGFloat(a) / CGFloat(n)
        let first: CGRect, second: CGRect
        if rect.width >= rect.height {
            let w = rect.width * fa
            first = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            second = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
        } else {
            let h = rect.height * fa
            first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            second = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
        }
        return splitEvenly(first, count: a) + splitEvenly(second, count: b)
    }

    /// Below this a stacked pane is too short to work in, and the column is carved up
    /// along its longer side instead.
    static let minimumStackedPaneHeight: CGFloat = 400

    /// The width a column is drawn at when it has no override of its own.
    ///
    /// Widen columns while they still fit. Two windows on a wide screen should share
    /// it rather than sit at a third each with wallpaper between them, and the same
    /// reasoning that gives a lone window the whole screen gives two windows a half.
    /// Past the point where they fill the screen the configured width applies and the
    /// strip starts to scroll.
    ///
    /// Then never leave a column too narrow to work in. The configured width is a
    /// fraction, so one number means 1274 points on a wide display and 498 on a laptop,
    /// and only one of those is a window anyone wants. Step up through whole fractions
    /// until the column clears the floor, so a screen that cannot fit thirds falls back
    /// to halves rather than to some number like 0.42. Nothing changes on a display wide
    /// enough for the configured width.
    static func defaultColumnFraction(columnCount: Int, region: TilingRegion,
                                      configured: CGFloat, minColumnWidth: CGFloat,
                                      fillScreen: Bool) -> CGFloat {
        let fitWidth = 1.0 / CGFloat(max(columnCount, 1))
        var fraction = fillScreen ? max(configured, min(fitWidth, 1.0)) : configured
        if minColumnWidth > 0 {
            for candidate in [1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0] as [CGFloat]
            where region.width * fraction < minColumnWidth {
                if candidate > fraction { fraction = candidate }
            }
        }
        return fraction
    }

    static func calculateNiriFrames(
        columns: [NiriColumn],
        region: TilingRegion,
        gap: CGFloat,
        activeColumn: Int,
        defaultColumnWidth: CGFloat,
        minColumnWidth: CGFloat = 0,
        stackMode: String = "auto",
        scrollOffset: CGFloat = 0,
        fillScreen: Bool = false,
        minWidthByWindow: [CGWindowID: CGFloat] = [:],
        resultingScrollOffset: inout CGFloat
    ) -> [NiriColumnResult] {
        guard !columns.isEmpty else { return [] }

        let halfGap = gap / 2
        let clampedActive = max(0, min(activeColumn, columns.count - 1))

        let effectiveDefaultWidth = defaultColumnFraction(
            columnCount: columns.count, region: region, configured: defaultColumnWidth,
            minColumnWidth: minColumnWidth, fillScreen: fillScreen)

        // An override is the user's own number, so it is held to the floor as a plain
        // minimum rather than stepped up to a whole fraction.
        let floorFraction = minColumnWidth > 0 ? min(1.0, minColumnWidth / region.width) : 0

        // Compute each column's width in pixels
        let colWidths: [CGFloat] = columns.map { col in
            var fraction = max(col.widthOverride ?? effectiveDefaultWidth, floorFraction)
            // Honour a window that will not shrink to its share. Mail and other apps
            // with a fixed minimum width used to render wider than the column and lap
            // over the next one, because our layout math is fit-to-screen. This is a
            // scrolling strip, so the column takes the window's real width instead and
            // the columns after it move along the strip and scroll, the way niri does.
            // The width is measured, not asked for: see WindowManager.niriMinWidth.
            let widest = col.windows.compactMap { minWidthByWindow[$0] }.max() ?? 0
            if widest > 0 {
                fraction = max(fraction, (widest + gap) / region.width)
            }
            return region.width * fraction
        }

        // Layout columns sequentially in the virtual strip
        var colXPositions: [CGFloat] = []
        var x: CGFloat = 0
        for w in colWidths {
            colXPositions.append(x)
            x += w
        }

        // Scroll only as far as needed to bring the active column into view, keeping
        // whatever position the strip already had otherwise.
        //
        // Centring the active column on every change is what made this feel unlike niri:
        // merging two columns or moving focus slid the entire strip, so it looked as
        // though every other window flew across the screen rather than the one window
        // you moved going anywhere. niri leaves the view alone while the focused column
        // is already visible.
        let activeX = colXPositions[clampedActive]
        let activeW = colWidths[clampedActive]

        var offset = scrollOffset
        let leftEdge = activeX + offset
        let rightEdge = leftEdge + activeW
        if leftEdge < region.x {
            offset += region.x - leftEdge
        } else if rightEdge > region.x + region.width {
            offset -= rightEdge - (region.x + region.width)
        }
        // Never scroll past the start of the strip.
        offset = min(offset, region.x)

        // Land on a column boundary.
        //
        // Partial columns are hidden, so a strip left mid-scroll shows a band of bare
        // desktop where the hidden column would have stood, and the row stops being even.
        // Pick the boundary nearest to where the strip already is that still shows the
        // active column whole, so the view moves as little as it has to.
        let activeRight = activeX + activeW
        var bestOffset = offset
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for start in colXPositions {
            let candidate = min(region.x - start, region.x)
            guard activeX + candidate >= region.x - 1,
                  activeRight + candidate <= region.x + region.width + 1
            else { continue }
            let distance = abs(candidate - offset)
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = candidate
            }
        }
        offset = bestOffset
        resultingScrollOffset = offset

        // Build results
        var results: [NiriColumnResult] = []
        let screenLeft = region.x
        let screenRight = region.x + region.width

        for (i, col) in columns.enumerated() {
            let colX = colXPositions[i] + offset
            let colW = colWidths[i]

            // A column shows only when the whole of it fits. Partial columns counted as
            // visible before, so whenever the strip overflowed, the column at the far end
            // poked a few pixels out from under the window at the edge with nothing to
            // cover it: CGSSetWindowAlpha is a silent no-op on another application's
            // window, so position is the only thing that can hide one.
            let fitsEntirely = colX >= screenLeft - 1 && (colX + colW) <= screenRight + 1
            // A column too wide to ever fit still has to be drawn, or it would vanish.
            let tooWideToFit = colW >= region.width - 1
            let isVisible = fitsEntirely
                || (tooWideToFit && (colX + colW) > screenLeft && colX < screenRight)

            // Divide height equally among windows in this column
            let windowCount = col.windows.count
            var windowFrames: [(windowID: CGWindowID, frame: CGRect)] = []

            if windowCount > 0 {
                // Windows sharing a column sit one above the other by default, as they
                // do in niri. Side by side is offered because on a wide screen a column
                // is short and broad, so splitting its height twice leaves two letterbox
                // strips, while splitting its width gives two usable panes.
                if stackMode == "auto" {
                    // Stack vertically for as long as the panes stay usable, and only
                    // carve the column up when they would not be.
                    //
                    // This used to hand the column straight to splitEvenly, which cuts
                    // whichever side is longer. A half-screen column on a wide display is
                    // broader than it is tall, so two windows landed side by side there
                    // while the same two stacked on a laptop. One key, opposite results,
                    // decided by the screen you happened to be sitting at. Worse, it made
                    // pulling a window into a column look exactly like leaving it in its
                    // own, only narrower.
                    let stackedHeight = region.height / CGFloat(windowCount)
                    if stackedHeight >= minimumStackedPaneHeight {
                        let windowHeight = region.height / CGFloat(windowCount)
                        for (wi, wid) in col.windows.enumerated() {
                            windowFrames.append((windowID: wid, frame: CGRect(
                                x: colX + halfGap,
                                y: region.y + windowHeight * CGFloat(wi) + halfGap,
                                width: max(colW - gap, 100),
                                height: max(windowHeight - gap, 100))))
                        }
                        results.append(NiriColumnResult(
                            columnIndex: i, windowFrames: windowFrames, isVisible: isVisible))
                        continue
                    }
                    let column = CGRect(x: colX, y: region.y, width: colW, height: region.height)
                    for (wid, r) in zip(col.windows, splitEvenly(column, count: windowCount)) {
                        windowFrames.append((windowID: wid, frame: CGRect(
                            x: r.minX + halfGap, y: r.minY + halfGap,
                            width: max(r.width - gap, 100), height: max(r.height - gap, 100))))
                    }
                } else if stackMode == "horizontal" {
                    let windowWidth = colW / CGFloat(windowCount)
                    for (wi, wid) in col.windows.enumerated() {
                        let frame = CGRect(
                            x: colX + windowWidth * CGFloat(wi) + halfGap,
                            y: region.y + halfGap,
                            width: max(windowWidth - gap, 100),
                            height: max(region.height - gap, 100)
                        )
                        windowFrames.append((windowID: wid, frame: frame))
                    }
                } else {
                    let windowHeight = region.height / CGFloat(windowCount)
                    for (wi, wid) in col.windows.enumerated() {
                        let frame = CGRect(
                            x: colX + halfGap,
                            y: region.y + windowHeight * CGFloat(wi) + halfGap,
                            width: max(colW - gap, 100),
                            height: max(windowHeight - gap, 100)
                        )
                        windowFrames.append((windowID: wid, frame: frame))
                    }
                }
            }

            results.append(NiriColumnResult(
                columnIndex: i,
                windowFrames: windowFrames,
                isVisible: isVisible
            ))
        }

        return results
    }

    // MARK: - High-Level Layout

    /// Apply layout to N windows with smooth animation.
    static func applyLayout(
        windows: [(windowID: CGWindowID, element: AXUIElement, pid: pid_t)],
        region: TilingRegion,
        gap: CGFloat,
        singleWindowPadding: CGFloat = 0,
        splitRatio: CGFloat = 0.5,
        variant: Int = 0,
        animate: Bool = true
    ) {
        guard !windows.isEmpty else { return }

        let targetFrames = calculateFrames(
            count: windows.count, region: region, gap: gap,
            singleWindowPadding: singleWindowPadding,
            splitRatio: splitRatio, variant: variant
        )

        if animate {
            var transitions: [Animator.Transition] = []
            for (i, w) in windows.enumerated() where i < targetFrames.count {
                let currentFrame = AccessibilityBridge.getFrame(of: w.element) ?? targetFrames[i]
                transitions.append(Animator.Transition(
                    windowID: w.windowID,
                    element: w.element,
                    startFrame: currentFrame,
                    targetFrame: targetFrames[i]
                ))
            }
            Animator.shared.animate(transitions)
        } else {
            // Snap immediately (used during mouse drag resize)
            var frames: [(element: AXUIElement, frame: CGRect)] = []
            for (i, w) in windows.enumerated() where i < targetFrames.count {
                frames.append((w.element, targetFrames[i]))
            }
            AccessibilityBridge.batchSetFrames(frames)
        }
    }
}
