import Cocoa
import CoreVideo

/// Window animation engine.
///
/// Everything here goes through the Accessibility API, because that is the only
/// thing that works. Measured on macOS Tahoe with a controlled two-process test:
/// SLSSetWindowTransform and CGSSetWindowAlpha both return CGError 0 and do
/// nothing at all when the target window belongs to another process. They only
/// affect windows we own ourselves. This file used to claim the opposite and the
/// popin, popout and alpha pre-hide effects were all built on it, so none of them
/// ever ran. Do not add a compositor path back without measuring it first.
///
/// yabai gets a real GPU animation by capturing the window, animating its own
/// proxy, and asking Dock.app to hide the real one. That last step needs SIP
/// partially disabled, and capturing window pixels at all costs the Screen
/// Recording permission plus a permanently lit recording indicator, so neither
/// is available to us.
class Animator: NSObject {
    static let shared = Animator()

    var enabled: Bool = true
    /// Take the final size in one step at the start and animate position only.
    /// See Config.sizeOnce.
    var sizeOnce: Bool = false
    /// See Config.appDrivenAnimation.
    var appDrivenAnimation: String = "moves"

    /// Called with true when an animation starts and false when the last one ends.
    /// Lets the owner run the ProMotion keepalive only while it is worth anything.
    var onAnimationActive: ((Bool) -> Void)?

    private var isAnimating = false
    private let conn = CGSMainConnectionID()

    // Close animation state


    // MARK: - Hyprland Animation Curves & Timing

    /// Hyprland's "default" bezier: (0.25, 1, 0.5, 1) — smooth ease-out
    private let easeOut = BezierCurve(p1x: 0.25, p1y: 1.0, p2x: 0.5, p2y: 1.0)


    // Hyprland default durations & scale
    /// Slight swing past the target, then settle. The overshoot is deliberately small:
    /// enough to read as weight, not enough to lap a neighbouring cell.
    private func easeOutBack(_ x: CGFloat) -> CGFloat {
        // Measured: c1 = 0.9 swung 57px past the target on a 1904pt window, enough to
        // lap the neighbouring cell. This is about a third of that.
        let c1: CGFloat = 0.32, c3 = c1 + 1
        let p = x - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    /// How far apart to start successive windows in one reflow.
    ///
    /// Zero: they move as one. A cascade was tried and it does read as choreographed,
    /// but windows sharing an edge then visibly slide out of step with each other, and
    /// the thing that makes a tiling layout feel solid is that neighbours behave as if
    /// they are pushing one another rather than each going its own way.
    private let staggerStep: TimeInterval = 0

    /// How long a new window waits before entering. The windows already on screen move
    /// aside first and the newcomer drops into the space they opened, rather than the
    /// two crossing over each other at the start, which reads as a collision.
    private let newWindowDelay: TimeInterval = 0.10

    /// Matches what macOS's own tiling takes (measured 330ms for TextEdit, 355ms for Safari).
    /// A scroll step: short enough that a second key press lands after it, not inside it.
    static let moveDuration: CFTimeInterval = 0.16
    /// A reflow, where sizes change and windows trade places. Hyprland's default.
    static let reflowDuration: CFTimeInterval = 0.33

    struct Transition {
        let windowID: CGWindowID
        let element: AXUIElement
        let startFrame: CGRect
        let targetFrame: CGRect
        var isNewWindow: Bool = false
    }

    /// Cubic bezier curve evaluator (same math as CSS/Hyprland beziers).
    struct BezierCurve {
        let p1x: CGFloat, p1y: CGFloat
        let p2x: CGFloat, p2y: CGFloat

        func evaluate(_ x: CGFloat) -> CGFloat {
            guard x > 0 else { return 0 }
            guard x < 1 else { return 1 }

            var t = x
            for _ in 0..<8 {
                let bx = bezierComponent(t, p1: p1x, p2: p2x)
                let dbx = bezierDerivative(t, p1: p1x, p2: p2x)
                if abs(dbx) < 1e-7 { break }
                t -= (bx - x) / dbx
                t = max(0, min(1, t))
            }
            return bezierComponent(t, p1: p1y, p2: p2y)
        }

        private func bezierComponent(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
            let mt = 1.0 - t
            return 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t
        }

        private func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
            let mt = 1.0 - t
            return 3.0 * mt * mt * p1 + 6.0 * mt * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
        }
    }

    // MARK: - Public API

    // Delayed popin state

    /// Move windows to their target positions.
    /// Position moves are instant (atomic batchSetFrames).
    /// New windows get a GPU-composited popin scale + fade-in after a short
    /// delay to let existing windows finish resizing first (avoids overlap
    /// with slow apps like Messages).
    /// Move windows to their target positions.
    ///
    /// Every window walks from its current frame to its target over its own duration,
    /// paced by the display link. This is the same thing macOS's own tiling does: measured
    /// on this machine, Apple animates the real window frame at roughly 115 updates/sec for
    /// a light window and 73/sec for Safari. There is no compositor shortcut available to
    /// us, because SLSSetWindowTransform and CGSSetWindowAlpha both no-op on windows owned
    /// by another process, so the frame is the only thing that actually moves.
    func animate(_ transitions: [Transition]) {
        // Take over whatever is still in the air rather than stopping it.
        //
        // This began with cancelAll, so every key press threw away a half finished
        // animation and started the ease again from its fast opening. One press is
        // invisible; six in a row is a pulse, and no amount of frame rate hides it. A
        // window already travelling is now pointed at the new place instead, carrying the
        // speed it had, so a fast scroll is one continuous movement that keeps changing
        // its mind about where it ends.
        glideLock.lock()
        let inFlight = Dictionary(glides.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        glideLock.unlock()

        guard !transitions.isEmpty else { cancelAll(); return }

        let targets = transitions.map { (element: $0.element, frame: $0.targetFrame) }

        guard enabled else {
            cancelAll()
            AccessibilityBridge.batchSetFrames(targets)
            return
        }

        let now = CACurrentMediaTime()

        var steps: [Glide] = []
        var pids = Set<pid_t>()
        for t in transitions {
            var pid: pid_t = 0
            AXUIElementGetPid(t.element, &pid)

            // Already moving: send it somewhere else instead of starting it over. Even
            // when it is passing through the new target this instant, or it would carry
            // on to the old one.
            if let live = inFlight[t.windowID] {
                retarget(live, to: t.targetFrame, now: now)
                steps.append(live)
                pids.insert(pid)
                continue
            }

            let from = t.startFrame.width > 1 ? t.startFrame
                                              : (AccessibilityBridge.getFrame(of: t.element) ?? t.targetFrame)
            // Nothing to watch if it is already there.
            guard abs(from.origin.x - t.targetFrame.origin.x) > 1
                || abs(from.origin.y - t.targetFrame.origin.y) > 1
                || abs(from.width - t.targetFrame.width) > 1
                || abs(from.height - t.targetFrame.height) > 1 else { continue }
            pids.insert(pid)
            // A new arrival leads and may swing past its mark; the others follow in a
            // short cascade, which reads as choreography rather than everything lurching
            // at once. Both are free: it only changes when each write is issued.
            steps.append(Glide(windowID: t.windowID, element: t.element,
                               from: from, to: t.targetFrame,
                               delay: t.isNewWindow ? newWindowDelay : Double(steps.count) * staggerStep,
                               overshoot: t.isNewWindow))
        }

        guard !steps.isEmpty else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }

        startAnimation(steps, targets: targets, pids: pids)
    }

    // MARK: - Frame Glide

    /// A reference type because the animation learns about the window as it runs.
    /// Rate of change of a frame, in points per second.
    struct Motion {
        var dx: CGFloat = 0, dy: CGFloat = 0, dw: CGFloat = 0, dh: CGFloat = 0
        var isStill: Bool { abs(dx) < 1 && abs(dy) < 1 && abs(dw) < 1 && abs(dh) < 1 }
    }

    final class Glide {
        let windowID: CGWindowID
        let element: AXUIElement
        var from: CGRect
        var to: CGRect
        /// When this window started its current leg. Each glide keeps its own clock, so
        /// one window can be given a new target without disturbing the others.
        var startedAt: CFTimeInterval = 0
        /// How fast it was already travelling when the current leg began, in points per
        /// second. Nil for a standing start, which keeps the ordinary ease.
        var entryVelocity: Motion?
        /// The window travels without changing size, so kAXSize is never written.
        var moveOnly: Bool
        /// How long this window takes. A scroll along the strip wants to be over before
        /// the next key arrives; a reflow, where windows change size and swap places, is
        /// worth watching. One duration for both meant every scroll was still running when
        /// the next one cancelled it, so the curve restarted from its fast opening again
        /// and again, which reads as a pulse rather than as motion.
        var duration: CFTimeInterval
        /// Set once the app has demonstrated it will not take the size we ask for.
        /// Fixed-size windows and windows that snap to a character grid, like terminals,
        /// otherwise cost a full resize per frame and ignore every one of them.
        var sizeRefused = false
        /// Whether the first write has been checked against what the app actually did.
        var constraintChecked = false
        /// Seconds to wait before this window starts moving. Offsetting each window a
        /// little makes a reflow read as choreographed rather than mechanical, and it
        /// costs nothing: the writes are simply spread out.
        var delay: TimeInterval = 0
        /// Whether this window may swing slightly past its target and settle back.
        /// Only new arrivals do; a neighbour overshooting would lap into the window
        /// beside it, which in a tiling layout reads as a mistake rather than as life.
        var overshoot = false

        init(windowID: CGWindowID, element: AXUIElement, from: CGRect, to: CGRect,
             delay: TimeInterval = 0, overshoot: Bool = false) {
            self.delay = delay
            self.overshoot = overshoot
            self.windowID = windowID
            self.element = element
            self.from = from
            self.to = to
            let onlyMoves = abs(from.width - to.width) < 2 && abs(from.height - to.height) < 2
            self.moveOnly = onlyMoves
            self.duration = onlyMoves ? Animator.moveDuration : Animator.reflowDuration
        }
    }

    private var glides: [Glide] = []
    private var glideTargets: [(element: AXUIElement, frame: CGRect)] = []
    private var restoreEnhancedUI: Set<pid_t> = []
    private var displayLink: CVDisplayLink?
    private let glideLock = NSLock()
    private var busyWindows = Set<CGWindowID>()
    /// Bumped whenever the glides change hands, so a finishing tick queued for an
    /// older animation is recognised and ignored.
    private var glideGeneration = 0
    /// Concurrent so a slow app blocks only its own window, not the whole frame.
    /// Each app is a separate AX server, so these genuinely overlap.
    private let axQueue = DispatchQueue(label: "com.paneless.axglide", attributes: .concurrent)

    private func startAnimation(_ steps: [Glide],
                                targets: [(element: AXUIElement, frame: CGRect)],
                                pids: Set<pid_t>) {
        // Let the applications animate themselves whenever nothing is being resized.
        //
        // AXEnhancedUserInterface eases position and snaps size, which is why it is not
        // the general answer. But a scroll along the strip changes no sizes at all, so the
        // one thing it does badly never comes up, and the one thing it does well is
        // exactly what is wanted: 110fps from a single round trip per application instead
        // of a synchronous write per window per frame, on a main thread that has to reach
        // every other window in the same 8.33ms.
        // Hand an isolated move to the application, and take the reins when it is not
        // isolated.
        //
        // The two are good at different things. One write and the application eases the
        // window itself at around 110fps in its own process, where ours writes to every
        // visible window every frame, three hundred and sixty synchronous messages a
        // second down a single thread. But the application's curve is its own: a second
        // key press restarts it and there is no way in from outside, while ours can be
        // pointed somewhere new while it moves. So the application gets the first step,
        // and the moment a second arrives before the first has landed, we take over.
        glideLock.lock()
        let alreadyMoving = !glides.isEmpty
        glideLock.unlock()
        let handOver = appDrivenAnimation == "always"
            || (appDrivenAnimation == "moves"
                && steps.allSatisfy { $0.moveOnly }
                && !alreadyMoving
                && appDrivenWork == nil)
        if handOver {
            startAppDrivenAnimation(steps, pids: pids)
        } else {
            // Taking over from an application mid-animation: clear its bookkeeping first,
            // or the attribute we turned on to let it animate would be restored on top of
            // our own frames, and it would go on easing against every one of them.
            if appDrivenWork != nil {
                appDrivenWork?.cancel()
                appDrivenWork = nil
                AccessibilityBridge.setEnhancedUI(pids: appDrivenRestore, enabled: false)
                appDrivenRestore = []
            }
            startGlide(steps, targets: targets, pids: pids)
        }
    }

    // MARK: - App-driven animation

    /// How long to leave AXEnhancedUserInterface on. The apps' own animation measured
    /// ~225ms; this leaves margin without holding the attribute a moment longer than
    /// needed, since it makes apps build and maintain their whole accessibility tree.
    private let appDrivenSettle: TimeInterval = 0.45
    private var appDrivenRestore: Set<pid_t> = []
    private var appDrivenWork: DispatchWorkItem?

    /// Give each app its destination once and let it animate itself.
    ///
    /// Every other window manager turns AXEnhancedUserInterface off before writing a
    /// frame, because windows then "keep animating" and a read-back mid-flight returns
    /// a value that is still moving, which breaks their verify-and-correct loops. We
    /// want the animation, so we turn it on instead. Measured on Ghostty and Safari:
    /// one write produces 22-27 frames over ~225ms, about 110fps, from a single IPC
    /// round trip rather than one per frame.
    ///
    /// What it does not do is animate size: of 56 observed changes only 2 were resizes.
    /// Position eases, size snaps.
    private func startAppDrivenAnimation(_ steps: [Glide], pids: Set<pid_t>) {
        appDrivenWork?.cancel()
        // Only restore the apps we actually changed, so an app that legitimately has
        // this on, with VoiceOver running for instance, is left alone.
        appDrivenRestore.formUnion(AccessibilityBridge.setEnhancedUI(pids: pids, enabled: true))
        isAnimating = true
        onAnimationActive?(true)

        for step in steps {
            AccessibilityBridge.setFrameDuringAnimation(of: step.element, to: step.to)
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            AccessibilityBridge.setEnhancedUI(pids: self.appDrivenRestore, enabled: false)
            self.appDrivenRestore = []
            self.appDrivenWork = nil
            self.isAnimating = false
            self.onAnimationActive?(false)
        }
        appDrivenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + appDrivenSettle, execute: work)
    }

    private func startGlide(_ steps: [Glide],
                            targets: [(element: AXUIElement, frame: CGRect)],
                            pids: Set<pid_t>) {
        glideLock.lock()
        let now = CACurrentMediaTime()
        for step in steps where step.startedAt == 0 { step.startedAt = now }
        // Only the windows named here change course. Anything else still in the air
        // keeps going: the other screen's windows, or a column on its way out that the
        // next scroll had no reason to mention. Replacing the whole set left those
        // frozen wherever they happened to be.
        let named = Set(steps.map { $0.windowID })
        glides = glides.filter { !named.contains($0.windowID) } + steps
        glideTargets = glideTargets.filter { old in
            !targets.contains { CFEqual($0.element, old.element) }
        } + targets
        glideGeneration += 1
        glideLock.unlock()

        // A hung app must not be able to stall the loop for the multi-second AX default.
        // A glide that only moves a window gets a tight deadline; one that resizes keeps
        // the generous one it needs.
        //
        // Every write here is synchronous, so an application that takes its time holds up
        // the frame for all the others too. One timeout of a quarter of a second covered
        // both cases, which is thirty frames' worth at 120Hz for a write that measures
        // 0.2 to 2ms. This is a bound on the damage a hung application can do rather than
        // a measured win: 30ms is still fifteen times what a move needs, while a resize is
        // 25 to 53ms on Safari and would be cut off by anything tighter.
        for step in steps {
            AccessibilityBridge.limitMessagingTime(of: step.element, to: step.moveOnly ? 0.03 : 0.25)
        }

        // Pay every resize once, here, rather than forty times during the animation.
        // The window snaps to its final size and then travels at full frame rate.
        if sizeOnce {
            for step in steps where !step.moveOnly {
                var size = step.to.size
                if let v = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(step.element, kAXSizeAttribute as CFString, v)
                }
                step.sizeRefused = true
            }
        }

        // Off for the duration, so the apps don't animate against us. Added to, not
        // assigned: a takeover mid-glide finds the attribute already off and would
        // otherwise forget who to hand it back to.
        restoreEnhancedUI.formUnion(AccessibilityBridge.setEnhancedUI(pids: pids, enabled: false))
        isAnimating = true

        // A link already running picks the new glides up on its next tick. Starting
        // another per call leaked one running link for every key pressed mid-glide.
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link = link else {
            AccessibilityBridge.batchSetFrames(targets)
            finishGlide()
            return
        }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.glideTick()
            return kCVReturnSuccess
        }
        displayLink = link
        onAnimationActive?(true)
        CVDisplayLinkStart(link)
    }

    /// Where a glide should be at `u`, its own progress from 0 to 1.
    ///
    /// A standing start keeps the ordinary ease. One that was given a new target while
    /// already moving carries the speed it had into a cubic Hermite, which begins at
    /// exactly that speed and still arrives at rest. Restarting the ease instead made the
    /// window leap forward again from its fast opening, and over a quick scroll that
    /// repeats often enough to read as a pulse rather than as movement.
    private func frame(of g: Glide, at u: CGFloat) -> CGRect {
        guard let v = g.entryVelocity, !v.isStill else {
            let e = g.overshoot ? easeOutBack(u) : easeOut.evaluate(u)
            return CGRect(
                x: g.from.origin.x + (g.to.origin.x - g.from.origin.x) * e,
                y: g.from.origin.y + (g.to.origin.y - g.from.origin.y) * e,
                width: g.from.width + (g.to.width - g.from.width) * e,
                height: g.from.height + (g.to.height - g.from.height) * e)
        }
        let d = CGFloat(g.duration)
        let u2 = u * u, u3 = u2 * u
        let carry = u3 - 2 * u2 + u     // what the speed it arrived with is still worth
        let reach = 3 * u2 - 2 * u3     // how much of the remaining distance is covered
        func axis(_ p0: CGFloat, _ p1: CGFloat, _ v0: CGFloat) -> CGFloat {
            p0 + v0 * d * carry + (p1 - p0) * reach
        }
        return CGRect(
            x: axis(g.from.origin.x, g.to.origin.x, v.dx),
            y: axis(g.from.origin.y, g.to.origin.y, v.dy),
            width: axis(g.from.width, g.to.width, v.dw),
            height: axis(g.from.height, g.to.height, v.dh))
    }

    /// How fast a glide is travelling at `u`, read off the curve itself so it stays right
    /// whichever curve that is.
    private func motion(of g: Glide, at u: CGFloat) -> Motion {
        let step: CGFloat = 0.01
        let lo = max(0, u - step), hi = min(1, u + step)
        let dt = (hi - lo) * CGFloat(g.duration)
        guard dt > 0 else { return Motion() }
        let a = frame(of: g, at: lo), b = frame(of: g, at: hi)
        return Motion(dx: (b.origin.x - a.origin.x) / dt,
                      dy: (b.origin.y - a.origin.y) / dt,
                      dw: (b.width - a.width) / dt,
                      dh: (b.height - a.height) / dt)
    }

    /// Point a glide somewhere new without stopping it first.
    private func retarget(_ g: Glide, to target: CGRect, now: CFTimeInterval) {
        let u = min(max(CGFloat((now - g.startedAt - g.delay) / g.duration), 0), 1)
        let here = frame(of: g, at: u)
        g.entryVelocity = motion(of: g, at: u)
        g.from = here
        g.to = target
        g.startedAt = now
        g.delay = 0
        g.overshoot = false
        g.moveOnly = abs(here.width - target.width) < 2 && abs(here.height - target.height) < 2
        g.duration = g.moveOnly ? Animator.moveDuration : Animator.reflowDuration
    }

    private func glideTick() {
        glideLock.lock()
        let steps = glides
        let generation = glideGeneration
        glideLock.unlock()

        guard !steps.isEmpty else { return }

        let now = CACurrentMediaTime()
        // Every window keeps its own clock, so one can be sent somewhere new without
        // disturbing the timing of the others.
        if steps.allSatisfy({ now - $0.startedAt >= $0.duration + $0.delay }) {
            DispatchQueue.main.async { [weak self] in
                self?.finishGlide(commit: true, generation: generation)
            }
            return
        }

        for g in steps {
            // Each window runs its own clock, offset by its place in the reflow.
            let own = min(max(CGFloat((now - g.startedAt - g.delay) / g.duration), 0), 1)
            guard own > 0 else { continue }
            // Skip any window still busy with its previous write. A slow app then simply
            // updates less often instead of backing up a queue of stale frames.
            glideLock.lock()
            let busy = busyWindows.contains(g.windowID)
            if !busy { busyWindows.insert(g.windowID) }
            glideLock.unlock()
            guard !busy else { continue }

            let rect = frame(of: g, at: own)
            guard AccessibilityBridge.isPlausibleFrame(rect) else {
                glideLock.lock(); busyWindows.remove(g.windowID); glideLock.unlock()
                continue
            }

            let wantsSize = !g.moveOnly && !g.sizeRefused
            axQueue.async { [weak self] in
                AccessibilityBridge.setFrameDuringAnimation(of: g.element, to: rect, setSize: wantsSize)

                // Ask once whether the app is actually honouring the size. If it gave us
                // something else, it is constrained, and every further resize this
                // animation would be paid for and thrown away.
                if wantsSize && !g.constraintChecked {
                    g.constraintChecked = true
                    if let actual = AccessibilityBridge.getFrame(of: g.element),
                       abs(actual.width - rect.width) > 2 || abs(actual.height - rect.height) > 2 {
                        g.sizeRefused = true
                    }
                }

                guard let self = self else { return }
                self.glideLock.lock()
                self.busyWindows.remove(g.windowID)
                self.glideLock.unlock()
            }
        }
    }

    /// `generation` is the animation a finishing tick was watching. The tick queues
    /// this to the main thread, and by the time it runs a key press may have started a
    /// new animation, or a workspace switch cancelled the old one. Committing the
    /// targets of either would snap the fresh animation to its end, or put windows just
    /// parked off-screen straight back at their old frames.
    private func finishGlide(commit: Bool = false, generation: Int? = nil) {
        glideLock.lock()
        let stale = generation.map { $0 != glideGeneration } ?? false
        if !stale { glideGeneration += 1 }
        let finished = glides
        glideLock.unlock()
        if stale { return }

        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        let targets = glideTargets
        if commit && !targets.isEmpty {
            // Land exactly on the target, whatever the last interpolated frame was.
            AccessibilityBridge.batchSetFrames(targets)
        }
        // The tight timeout was for the animation. Left in place it capped every later
        // call on these windows, including the one that parks them on a switch.
        for g in finished {
            AccessibilityBridge.limitMessagingTime(of: g.element, to: 0)
        }
        if !restoreEnhancedUI.isEmpty {
            AccessibilityBridge.setEnhancedUI(pids: restoreEnhancedUI, enabled: true)
            restoreEnhancedUI = []
        }
        glideLock.lock()
        glides = []
        glideTargets = []
        busyWindows.removeAll()
        glideLock.unlock()
        isAnimating = false
        onAnimationActive?(false)
    }

    /// Snap remaining windows to new positions + animate closing window
    /// with popout shrink + fade.
    /// Close a window and flow the remaining ones into the space it leaves.
    ///
    /// The closing window itself cannot be animated: shrinking or fading it would need
    /// SLSSetWindowTransform or CGSSetWindowAlpha, and both are no-ops on windows owned
    /// by another process. So it goes at once, and the windows that remain glide into
    /// their new frames, which is where the motion actually reads from.
    func animateWithClose(
        redistributeTransitions: [Transition],
        closingWindowID: CGWindowID,
        closingFrame: CGRect,
        closingElement: AXUIElement? = nil,
        completion: @escaping () -> Void
    ) {
        cancelAll()

        // Shrink the window before it goes, when we are the ones closing it.
        //
        // Only possible on Paneless's own close binding: a window closed with Cmd+W is
        // gone by the time we hear about it, and intercepting Cmd+W is not an option
        // because in a browser it closes a tab rather than a window. Scaling would be
        // the natural way to do this and is not available to us, so the frame itself is
        // stepped down. It is a handful of resizes on a window that is about to cease
        // existing, so the usual cost of a resize does not matter here.
        if enabled, let element = closingElement, closingFrame.width > 1 {
            let steps = 6
            let duration = 0.11
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let scale = 1.0 - 0.22 * t
                let w = closingFrame.width * scale, h = closingFrame.height * scale
                let rect = CGRect(x: closingFrame.midX - w / 2, y: closingFrame.midY - h / 2,
                                  width: w, height: h)
                DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) {
                    AccessibilityBridge.setFrameDuringAnimation(of: element, to: rect)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { completion() }
        } else {
            // Close first so the gap is real before anything moves into it.
            completion()
        }

        guard enabled, !redistributeTransitions.isEmpty else {
            if !redistributeTransitions.isEmpty {
                AccessibilityBridge.batchSetFrames(
                    redistributeTransitions.map { (element: $0.element, frame: $0.targetFrame) })
            }
            return
        }

        let targets = redistributeTransitions.map { (element: $0.element, frame: $0.targetFrame) }
        var steps: [Glide] = []
        var pids = Set<pid_t>()
        for t in redistributeTransitions {
            let from = t.startFrame.width > 1 ? t.startFrame
                                              : (AccessibilityBridge.getFrame(of: t.element) ?? t.targetFrame)
            guard abs(from.origin.x - t.targetFrame.origin.x) > 1
                || abs(from.origin.y - t.targetFrame.origin.y) > 1
                || abs(from.width - t.targetFrame.width) > 1
                || abs(from.height - t.targetFrame.height) > 1 else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(t.element, &pid)
            pids.insert(pid)
            // A new arrival leads and may swing past its mark; the others follow in a
            // short cascade, which reads as choreography rather than everything lurching
            // at once. Both are free: it only changes when each write is issued.
            steps.append(Glide(windowID: t.windowID, element: t.element,
                               from: from, to: t.targetFrame,
                               delay: t.isNewWindow ? newWindowDelay : Double(steps.count) * staggerStep,
                               overshoot: t.isNewWindow))
        }

        guard !steps.isEmpty else {
            AccessibilityBridge.batchSetFrames(targets)
            return
        }
        startAnimation(steps, targets: targets, pids: pids)
    }

    // MARK: - Cleanup

    func cancelAll() {
        // Let an app-driven animation finish its restore rather than stranding the
        // attribute on; a queued restore is cheap and leaving it set is not.
        if let work = appDrivenWork {
            work.cancel()
            appDrivenWork = nil
            AccessibilityBridge.setEnhancedUI(pids: appDrivenRestore, enabled: false)
            appDrivenRestore = []
            isAnimating = false
        }

        // Stop any frame glide. Don't commit: whoever cancelled is about to set
        // its own targets, and committing here would fight them.
        if displayLink != nil || !glides.isEmpty {
            finishGlide()
        } else {
            // Nothing to stop, but a finishing tick may still be queued for the last
            // animation. Make sure it finds itself out of date.
            glideLock.lock()
            glideGeneration += 1
            glideLock.unlock()
        }
        isAnimating = false
    }

}
