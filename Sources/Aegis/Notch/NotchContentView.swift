import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var rateLimitStore: RateLimitStore
    @ObservedObject var settingsStore: SettingsStore
    let onPermissionRespond: (String, PermissionAction) -> Void
    let onOpenSettings: () -> Void
    @State private var hoverActivationTask: Task<Void, Never>?

    private var theme: NotchTheme { settingsStore.notchThemeID.theme }

    /// The backdrop spider's lenses double as a status readout, so they reflect
    /// the *worst* thing happening across every session — errors outrank pending
    /// approvals, which outrank work in progress.
    private var spiderLens: SpiderLens {
        let statuses = sessionStore.activeSessions.values.map(\.status)
        if statuses.contains(.error) { return .symbiote }
        if statuses.contains(.waitingPermission) { return .alarmed }
        if statuses.contains(.thinking) || statuses.contains(.toolUse) { return .narrow }
        return .wide
    }

    var body: some View {
        ZStack {
            NotchBackground(
                theme: theme,
                isExpanded: viewModel.isPresentingExpandedContent,
                cornerRadius: viewModel.isPresentingExpandedContent ? 20 : 17,
                drawBorder: false,
                creatureLens: spiderLens,
                // Legs only twitch while something is actually running — an idle
                // notch stays perfectly still (this is a transparent overlay, so
                // every animated frame recomposites the whole window area).
                creatureAnimates: spiderLens == .narrow
            )

            content
                .clipped()
                .opacity(viewModel.hidesOutgoingContentDuringCollapse ? 0 : 1)
                .animation(nil, value: viewModel.hidesOutgoingContentDuringCollapse)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(NotchShape(cornerRadius: viewModel.isPresentingExpandedContent ? 20 : 14))
        // Window edge border ON TOP of the content so cards/wells that reach the
        // panel bottom tuck under it instead of spilling over the rounded edge
        // (z-order fix — most visible with the thick Pixel/Brutalist borders).
        .overlay {
            if viewModel.isPresentingExpandedContent, theme.windowStroke != nil {
                NotchBorderShape(cornerRadius: viewModel.isPresentingExpandedContent ? 20 : 14)
                    .stroke(theme.windowStroke ?? .clear, lineWidth: theme.windowStrokeWidth * 2)
            }
        }
        .environment(\.notchTheme, theme)
        .onHover { hovering in
            if hovering {
                viewModel.mouseEntered()
                if settingsStore.expandOnHover, case .collapsed = viewModel.state {
                    hoverActivationTask?.cancel()
                    if ScreenDetector.hasSecondaryDisplay {
                        hoverActivationTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled, viewModel.isHovered,
                                  case .collapsed = viewModel.state else { return }
                            activateCollapsed()
                        }
                    } else {
                        // Standalone Mac: fastest path. No delay and no Task.
                        activateCollapsed()
                    }
                }
            } else {
                hoverActivationTask?.cancel()
                hoverActivationTask = nil
                viewModel.mouseExited()
            }
        }
        .onDisappear { hoverActivationTask?.cancel() }
    }

    private func activateCollapsed() {
        guard !showNextPending() else { return }
        guard !sessionStore.activeSessions.isEmpty else { return }
        viewModel.expand(holdSeconds: 2.0)
    }

    /// Surface the next queued decision (oldest-first): a permission routes to
    /// PermissionView, otherwise a question. Returns false
    /// when nothing is pending so callers can fall back (collapse / expand).
    @discardableResult
    private func showNextPending() -> Bool {
        let store = sessionStore
        if let next = store.nextPendingPermission() {
            let h = store.sessions[next].map { NotchViewModel.permissionHeight(for: $0) }
            viewModel.showPermission(sessionId: next, contentHeight: h)
            return true
        } else if let next = store.nextPendingQuestion(
            excluding: viewModel.suppressedQuestionSessionIDs
        ) {
            viewModel.showQuestion(sessionId: next)
            return true
        }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.presentedState {
        case .collapsed:
            Button(action: activateCollapsed) {
                CollapsedNotchView(sessionStore: sessionStore, rateLimitStore: rateLimitStore)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Aegis")
            .accessibilityHint("Shows active sessions and pending decisions")

        case .expanded:
            SessionListView(
                sessionStore: sessionStore,
                rateLimitStore: rateLimitStore,
                settingsStore: settingsStore,
                onCollapse: { viewModel.collapse() },
                onOpenSettings: onOpenSettings,
                onContentHeightChange: { height in
                    viewModel.updateExpandedContentHeight(height)
                }
            )

        case .finished(let sessionId):
            if let session = sessionStore.sessions[sessionId]
                ?? viewModel.finishedSessionSnapshot {
                FinishedView(
                    session: session,
                    onDismiss: { viewModel.collapse() },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: onOpenSettings,
                    onToggleExpand: { expanded in
                        if expanded {
                            viewModel.cancelAutoCollapse()
                        } else {
                            viewModel.dynamicFinishedHeight = NotchViewModel.finishedSize.height
                            viewModel.resumeFinishedAutoCollapse()
                        }
                    },
                    onContentHeightChange: { height in
                        viewModel.updateFinishedContentHeight(height)
                    }
                )
            } else {
                Color.clear
                    .onAppear { viewModel.collapse() }
            }

        case .permission(let sessionId):
            if let session = sessionStore.sessions[sessionId],
               let pending = session.pendingPermission {
                PermissionView(
                    session: session,
                    permission: pending,
                    onRespond: { action in
                        onPermissionRespond(sessionId, action)
                        if !showNextPending() { viewModel.dismissPermission() }
                    },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: onOpenSettings,
                    onToggleExpand: { expanded in
                        // Expanded mode = give the window enough room for the bigger ScrollView
                        if expanded {
                            viewModel.dynamicPermissionHeight = 560
                        } else if let s = sessionStore.sessions[sessionId] {
                            viewModel.dynamicPermissionHeight = NotchViewModel.permissionHeight(for: s)
                        }
                    }
                )
            } else {
                CollapsedNotchView(sessionStore: sessionStore, rateLimitStore: rateLimitStore)
            }

        case .question(let sessionId):
            if let session = sessionStore.sessions[sessionId],
               let question = session.pendingQuestion {
                QuestionView(
                    session: session,
                    question: question,
                    onSubmit: { answers in
                        sessionStore.respondToQuestion(sessionId: sessionId, answersByQuestionId: answers)
                        if !showNextPending() { viewModel.dismissQuestion() }
                    },
                    onDeferToTerminal: {
                        sessionStore.deferQuestionToTerminal(sessionId: sessionId)
                        if !showNextPending() { viewModel.dismissQuestion() }
                    },
                    onDismiss: { viewModel.suppressQuestion(sessionId: sessionId) },
                    rateLimitStore: rateLimitStore,
                    settingsStore: settingsStore,
                    onOpenSettings: onOpenSettings
                )
            } else {
                CollapsedNotchView(sessionStore: sessionStore, rateLimitStore: rateLimitStore)
            }
        }
    }
}
