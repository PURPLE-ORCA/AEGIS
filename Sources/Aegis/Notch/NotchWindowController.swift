import AppKit
import SwiftUI
import Combine

enum NotchPanelTransitionPolicy {
    static func duration(for state: NotchState) -> TimeInterval {
        if case .collapsed = state { return 0 }
        if case .finished = state { return NotchMotion.finishedCardOpenDuration }
        return NotchMotion.panelResizeDuration
    }
}

final class NotchWindowController: NSWindowController {
    private let viewModel: NotchViewModel
    private let sessionStore: SessionStore
    private let settingsStore: SettingsStore
    private let rateLimitStore: RateLimitStore
    private var cancellables = Set<AnyCancellable>()
    private var trackingArea: NSTrackingArea?

    init(sessionStore: SessionStore, settingsStore: SettingsStore, rateLimitStore: RateLimitStore) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.rateLimitStore = rateLimitStore
        self.viewModel = NotchViewModel()

        let initialFrame = ScreenDetector.notchPanelFrame(
            panelSize: NotchViewModel.collapsedSize
        )
        let panel = NotchPanel(contentRect: initialFrame)
        super.init(window: panel)

        print("[Aegis] Notch screen: \(ScreenDetector.notchScreen.frame), hasNotch: \(ScreenDetector.hasNotch)")
        print("[Aegis] Panel frame: \(initialFrame)")

        let contentView = NotchContentView(
            viewModel: viewModel,
            sessionStore: sessionStore,
            rateLimitStore: rateLimitStore,
            settingsStore: settingsStore,
            onPermissionRespond: { [weak self] sessionId, action in
                self?.sessionStore.respondToPermission(sessionId: sessionId, action: action)
            },
            onOpenSettings: {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
        )

        let hostingView = ClickThroughHostingView(rootView: contentView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]

        // Keep NSHostingView one level below the window's content view. Even
        // with empty sizingOptions, a direct hosting content view still asks
        // AppKit to refresh window size extrema during transform updates. That
        // can recurse into the active constraint pass and terminate the app.
        let contentContainer = NSView(frame: hostingView.frame)
        contentContainer.autoresizesSubviews = true
        contentContainer.addSubview(hostingView)
        panel.contentView = contentContainer

        // Ordering once is required before applying the custom window level.
        // Keep it transparent until presence policy decides whether this
        // launch actually has anything worth showing.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.isReleasedWhenClosed = false

        // Set level AFTER ordering front so it sticks above menu bar
        panel.applyNotchLevel()

        // Set frame AFTER ordering front, bypassing constraint
        let frame = ScreenDetector.notchPanelFrame(panelSize: NotchViewModel.collapsedSize)
        panel.setFrame(frame, display: true)
        Log.info("Panel frame after setFrame: \(panel.frame)")

        // Reposition window when state changes
        viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.repositionWindow(for: state)
            }
            .store(in: &cancellables)

        // SwiftUI owns the session-card height animation. Follow its measured
        // presentation directly so AppKit does not start a competing tween for
        // every intermediate frame.
        viewModel.$dynamicExpandedHeight
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.repositionExpandedContentWindow()
            }
            .store(in: &cancellables)

        // The notch is ambient status UI, not an always-on launcher. Keep the
        // panel entirely off-screen when there is no running/actionable work,
        // while still allowing transient results and decisions to surface.
        Publishers.CombineLatest(sessionStore.$sessions, viewModel.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, state in
                self?.reconcileWindowPresence(state: state)
            }
            .store(in: &cancellables)

        // Reposition when dynamic content height changes (e.g. expand button)
        Publishers.CombineLatest(viewModel.$dynamicPermissionHeight, viewModel.$dynamicFinishedHeight)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.repositionWindow()
            }
            .store(in: &cancellables)

        reconcileWindowPresence(state: viewModel.state)
        panel.alphaValue = 1

        // Watch for display changes
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.repositionWindow()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func handleSessionEvent(_ event: SessionEvent) {
        Task { @MainActor in
            // If the user is mid-decision on another prompt, leave the UI
            // alone — the queue drain after they respond will pick the next
            // pending one (sorted by enqueue time). Swapping mid-tap races
            // the button and applies the wrong decision to the wrong session
            // (issue #7).
            let isAlreadyDeciding: Bool = {
                if case .permission = viewModel.state { return true }
                if case .question = viewModel.state { return true }
                return false
            }()

            switch event {
            case .permissionRequested(let sessionId):
                guard DecisionPresentationPolicy.shouldPresentPermission(
                    state: viewModel.state,
                    autoExpandEnabled: settingsStore.autoExpandOnPermission
                ), !isAlreadyDeciding else { return }
                let height = computePermissionHeight(sessionId: sessionId)
                viewModel.showPermission(sessionId: sessionId, contentHeight: height)
            case .questionAsked(let sessionId):
                guard !isAlreadyDeciding else { return }
                viewModel.showQuestion(sessionId: sessionId)
            case .statusChanged(let sessionId, let status) where status == .idle:
                // The agent finished — show a focused notification card.
                if !viewModel.isExpanded, let session = sessionStore.sessions[sessionId] {
                    viewModel.showFinished(session: session)
                }
            case .pendingDismissedExternally(let sessionId):
                // Permission/question was answered in the terminal — dismiss
                switch viewModel.state {
                case .permission(let id) where id == sessionId,
                     .question(let id) where id == sessionId:
                    // Show next pending if any, else collapse
                    if let next = sessionStore.nextPendingPermission() {
                        let h = sessionStore.sessions[next].map { NotchViewModel.permissionHeight(for: $0) }
                        viewModel.showPermission(sessionId: next, contentHeight: h)
                    } else if let next = sessionStore.nextPendingQuestion(
                        excluding: viewModel.suppressedQuestionSessionIDs
                    ) {
                        viewModel.showQuestion(sessionId: next)
                    } else {
                        viewModel.collapse()
                    }
                default:
                    break
                }
            default:
                break
            }
        }
    }

    private var animationDisplayLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: TimeInterval = NotchMotion.panelResizeDuration
    private var animationStartSize: NSSize = .zero
    private var animationDeltaW: CGFloat = 0
    private var animationDeltaH: CGFloat = 0
    private var animationCompletion: (() -> Void)?
    private var awaitsInitialExpandedMeasurement = false

    private func reconcileWindowPresence(state: NotchState) {
        guard let panel = window else { return }
        let activeSessionCount = sessionStore.activeSessions.count

        if NotchPresencePolicy.shouldCollapse(
            state: state,
            activeSessionCount: activeSessionCount
        ) {
            viewModel.collapse()
            return
        }

        if NotchPresencePolicy.shouldShow(
            state: state,
            activeSessionCount: activeSessionCount
        ) {
            if !panel.isVisible {
                if case .collapsed = state {
                    snapPanelToCollapsedFrame(panel)
                }
                panel.orderFrontRegardless()
                (panel as? NotchPanel)?.applyNotchLevel()
            }
        } else {
            cancelPanelAnimation()
            if case .collapsed = state {
                viewModel.completeCollapsePresentation()
                snapPanelToCollapsedFrame(panel)
            }
            panel.orderOut(nil)
        }
    }

    private func repositionWindow(for state: NotchState? = nil) {
        guard let panel = window else { return }
        let transitionState = state ?? viewModel.state

        if case .expanded = transitionState,
           viewModel.dynamicExpandedHeight == nil {
            // Expanded content must be mounted before SwiftUI can report its
            // fitted height. Hold the current frame for that one measurement,
            // then resize width and height as a single continuity transition.
            cancelPanelAnimation()
            awaitsInitialExpandedMeasurement = true
            anchorCurrentFrameToScreenTop(panel)
            return
        }

        awaitsInitialExpandedMeasurement = false
        let target = viewModel.currentSize
        // Always snap the window to the (possibly new) notch screen's
        // top-center first. Without this, a resolution change that
        // doesn't alter our panel size leaves the window pinned at its
        // old absolute coordinates — i.e. off-screen on the new
        // resolution. Then run the size animation as usual.
        anchorCurrentFrameToScreenTop(panel)
        animatePanelToSize(
            target,
            duration: NotchPanelTransitionPolicy.duration(for: transitionState),
            completion: collapseCompletion(for: transitionState)
        )
    }

    private func repositionExpandedContentWindow() {
        guard case .expanded = viewModel.state,
              let panel = window else { return }

        let target = viewModel.currentSize
        if awaitsInitialExpandedMeasurement {
            awaitsInitialExpandedMeasurement = false
            animatePanelToSize(
                target,
                duration: NotchPanelTransitionPolicy.duration(for: .expanded)
            )
            return
        }

        cancelPanelAnimation()
        let screen = ScreenDetector.notchScreen.frame
        panel.setFrame(
            NSRect(
                x: screen.midX - target.width / 2,
                y: screen.maxY - target.height,
                width: target.width,
                height: target.height
            ),
            display: false
        )
    }

    /// Display-link-driven frame animation. Stays in lock-step with the
    /// screen's vsync (typically 60–120Hz depending on display) so we never
    /// schedule a frame the compositor can't show. Previously this was a
    /// `Timer.scheduledTimer` at 60Hz with `display: true`, which forced
    /// synchronous full-window redraws and could jank when anything else
    /// touched the main thread mid-expand.
    private func animatePanelToSize(
        _ targetSize: NSSize,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        guard let panel = window else { return }
        cancelPanelAnimation()

        if duration == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let screen = ScreenDetector.notchScreen.frame
            panel.setFrame(
                NSRect(
                    x: screen.midX - targetSize.width / 2,
                    y: screen.maxY - targetSize.height,
                    width: targetSize.width,
                    height: targetSize.height
                ),
                display: false
            )
            completion?()
            return
        }

        let startSize = panel.frame.size
        let dw = targetSize.width - startSize.width
        let dh = targetSize.height - startSize.height
        if abs(dw) < 0.5 && abs(dh) < 0.5 {
            completion?()
            return
        }

        animationStart = CACurrentMediaTime()
        animationDuration = duration
        animationStartSize = startSize
        animationDeltaW = dw
        animationDeltaH = dh
        animationCompletion = completion

        let link = panel.displayLink(target: self, selector: #selector(stepAnimation(_:)))
        link.add(to: .main, forMode: .common)
        animationDisplayLink = link
    }

    @objc private func stepAnimation(_ link: CADisplayLink) {
        guard let panel = window else {
            link.invalidate()
            animationDisplayLink = nil
            return
        }
        let elapsed = CACurrentMediaTime() - animationStart
        let t = min(elapsed / animationDuration, 1.0)
        let eased = NotchMotion.panelResizeProgress(t)
        let w = animationStartSize.width + animationDeltaW * eased
        let h = animationStartSize.height + animationDeltaH * eased
        let screen = ScreenDetector.notchScreen.frame
        // Anchor TOP edge to screen top, expand width from center
        let x = screen.midX - w / 2
        let y = screen.maxY - h
        // `display: false` lets Core Animation coalesce drawing — the
        // compositor still paints in sync with the next vsync.
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        if t >= 1.0 {
            link.invalidate()
            animationDisplayLink = nil
            let completion = animationCompletion
            animationCompletion = nil
            completion?()
        }
    }

    private func cancelPanelAnimation() {
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        animationCompletion = nil
    }

    private func collapseCompletion(for state: NotchState) -> (() -> Void)? {
        guard case .collapsed = state else { return nil }
        return { [weak self] in
            self?.viewModel.completeCollapsePresentation()
        }
    }

    private func anchorCurrentFrameToScreenTop(_ panel: NSWindow) {
        let screen = ScreenDetector.notchScreen.frame
        let size = panel.frame.size
        panel.setFrame(
            NSRect(
                x: screen.midX - size.width / 2,
                y: screen.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func snapPanelToCollapsedFrame(_ panel: NSWindow) {
        cancelPanelAnimation()
        let screen = ScreenDetector.notchScreen.frame
        let size = NotchViewModel.collapsedSize
        panel.setFrame(
            NSRect(
                x: screen.midX - size.width / 2,
                y: screen.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func computePermissionHeight(sessionId: String) -> CGFloat {
        guard let session = sessionStore.sessions[sessionId],
              let pending = session.pendingPermission else {
            return NotchViewModel.permissionSize.height
        }
        let filePath = pending.filePath
        var contentLines: Int? = nil
        if let oldStr = pending.oldString, let newStr = pending.newString {
            contentLines = oldStr.components(separatedBy: "\n").count + newStr.components(separatedBy: "\n").count
        } else if let content = pending.content, !content.isEmpty {
            contentLines = estimateVisualLines(content)
        } else if filePath == nil, let desc = pending.description, !desc.isEmpty {
            // Bash command (or other) — estimate wrapped lines from char width
            contentLines = estimateVisualLines(desc)
        }
        let hasDescription = (pending.description?.isEmpty == false) && filePath == nil
        return NotchViewModel.computePermissionHeight(
            filePath: filePath,
            contentLines: contentLines,
            hasDescription: hasDescription
        )
    }

    /// Estimate the number of rendered lines accounting for wrap at ~72 chars
    /// (600pt window width minus padding/line numbers, 11pt monospaced font).
    private func estimateVisualLines(_ text: String) -> Int {
        let charsPerLine = 72
        var lines = 0
        for line in text.components(separatedBy: "\n") {
            lines += max(1, (line.count + charsPerLine - 1) / charsPerLine)
        }
        return lines
    }

}

enum DecisionPresentationPolicy {
    static func shouldPresentPermission(
        state: NotchState,
        autoExpandEnabled: Bool
    ) -> Bool {
        switch state {
        case .collapsed:
            return autoExpandEnabled
        case .permission, .question:
            return false
        case .expanded, .finished:
            return true
        }
    }
}

enum NotchPresencePolicy {
    static func shouldCollapse(state: NotchState, activeSessionCount: Int) -> Bool {
        guard activeSessionCount == 0 else { return false }
        if case .expanded = state { return true }
        return false
    }

    static func shouldShow(state: NotchState, activeSessionCount: Int) -> Bool {
        switch state {
        case .finished, .permission, .question:
            return true
        case .collapsed, .expanded:
            return activeSessionCount > 0
        }
    }
}
