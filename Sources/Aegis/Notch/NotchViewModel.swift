import SwiftUI
import Combine

enum NotchState: Equatable {
    case collapsed
    case expanded
    case finished(sessionId: String)
    case permission(sessionId: String)
    case question(sessionId: String)
}

@MainActor
final class NotchViewModel: ObservableObject {
    enum AutoCollapseDecision: Equatable {
        case collapse
        case rearm(TimeInterval)
        case pause
    }

    static let expandedMouseExitDelay: TimeInterval = 0
    static let finishedCardVisibilityDuration: TimeInterval = 6
    static let finishedHoverCeiling: TimeInterval = 30
    static let autoCollapseRearmInterval: TimeInterval = 0.6

    // MARK: - Published State
    @Published var state: NotchState = .collapsed
    /// Content currently mounted in SwiftUI. During collapse this deliberately
    /// trails `state` until AppKit reaches the compact frame, preventing the
    /// expanded panel from becoming empty while it is still visibly large.
    @Published private(set) var presentedState: NotchState = .collapsed
    @Published var isHovered = false
    /// A completion notification outlives the provider's live session entry.
    /// Keep the value snapshot that triggered the popup so a fast session
    /// removal can never leave the finished window rendering an empty fallback.
    @Published private(set) var finishedSessionSnapshot: Session?

    // MARK: - Dimensions
    // Vibe Island uses Y=0 (screen top) with large windows.
    // Heights INCLUDE the notch/menu bar overlap (~32pt on top).
    // Computed properties so they re-evaluate when display parameters change.
    static var notchOverlap: CGFloat { ScreenDetector.hasNotch ? ScreenDetector.notchHeight : 0 }

    // Size adapts to the OS-reported notch cutout (safeAreaInsets.top + auxiliary
    // top areas). Width extends ~50pt beyond the notch on each side so the
    // mascot and session count have room. Height is notch height + small buffer.
    static var collapsedSize: NSSize {
        // No hardware notch (external display / older Mac): render a real bar
        // hanging from the top-center instead of a 5pt hover sliver, which read
        // as "smushed". NotchShape gives it the flat-top/rounded-bottom look.
        guard ScreenDetector.hasNotch else { return NSSize(width: 230, height: 32) }
        let width = max(280, ScreenDetector.notchWidth + 100)
        let height = ScreenDetector.notchHeight
        return NSSize(width: width, height: height)
    }
    static let expandedWidth: CGFloat = 600
    // Permission: wide enough for details
    static let permissionSize = NSSize(width: 600, height: 380)
    // Question: taller for multiple questions
    static let questionSize = NSSize(width: 600, height: 480)
    // Finished notification: one glanceable message card below the hardware
    // notch. Details expand only after the user clicks the card.
    static var finishedSize: NSSize {
        NSSize(width: 600, height: max(104, notchOverlap + 76))
    }

    // Dynamic content heights — measured by their views as content changes.
    @Published var dynamicExpandedHeight: CGFloat? = nil
    @Published var dynamicPermissionHeight: CGFloat? = nil
    @Published var dynamicFinishedHeight: CGFloat? = nil

    var currentSize: NSSize {
        switch state {
        case .collapsed:
            return Self.collapsedSize
        case .expanded:
            return NSSize(
                width: Self.expandedWidth,
                height: dynamicExpandedHeight ?? Self.collapsedSize.height
            )
        case .finished:
            return NSSize(width: 600, height: dynamicFinishedHeight ?? Self.finishedSize.height)
        case .permission:
            return NSSize(width: 600, height: dynamicPermissionHeight ?? Self.permissionSize.height)
        case .question:
            return Self.questionSize
        }
    }

    /// Compute the height needed for a permission view with the given content.
    static func computePermissionHeight(filePath: String?, contentLines: Int?, hasDescription: Bool) -> CGFloat {
        var h: CGFloat = 0
        h += 10 + 14   // top bar (rate limits/sound/gear) + spacing
        h += 12 + 22 + 10 // session header (mascot+title+badge) + spacing
        h += 22 + 10    // tool pill + subtitle row + spacing
        if filePath != nil {
            h += 30 + 8 // path row + spacing
        }
        if let lines = contentLines, lines > 0 {
            let bodyHeight = min(CGFloat(lines) * 14 + 20, 240)
            h += 24 + bodyHeight + 0 // content header + body
        } else if hasDescription {
            h += 24 + 50
        }
        h += 12 + 36 + 12 // spacer + buttons + bottom padding
        return min(max(h, 200), 600)
    }

    static func permissionHeight(for session: Session) -> CGFloat {
        guard let pending = session.pendingPermission else { return permissionSize.height }
        var contentLines: Int? = nil
        if let oldStr = pending.oldString, let newStr = pending.newString {
            contentLines = oldStr.components(separatedBy: "\n").count + newStr.components(separatedBy: "\n").count
        } else if let content = pending.content, !content.isEmpty {
            contentLines = estimateVisualLines(content)
        } else if pending.filePath == nil, let desc = pending.description, !desc.isEmpty {
            contentLines = estimateVisualLines(desc)
        }
        let hasDescription = (pending.description?.isEmpty == false) && pending.filePath == nil
        return computePermissionHeight(
            filePath: pending.filePath,
            contentLines: contentLines,
            hasDescription: hasDescription
        )
    }

    private static func estimateVisualLines(_ text: String) -> Int {
        let charsPerLine = 72
        var lines = 0
        for line in text.components(separatedBy: "\n") {
            lines += max(1, (line.count + charsPerLine - 1) / charsPerLine)
        }
        return lines
    }

    var isExpanded: Bool {
        state != .collapsed
    }

    var isPresentingExpandedContent: Bool {
        presentedState != .collapsed
    }

    // MARK: - Auto-collapse
    private var autoCollapseTask: Task<Void, Never>?
    private var finishedAutoCollapseDeadline: Date?
    private(set) var suppressedQuestionSessionIDs: Set<String> = []

    func expand(holdSeconds: Double? = nil) {
        guard state == .collapsed else { return }
        dynamicExpandedHeight = nil
        presentedState = .expanded
        state = .expanded
        scheduleAutoCollapse(delay: holdSeconds ?? Self.autoCollapseRearmInterval)
    }

    func collapse() {
        guard state != .collapsed else { return }
        state = .collapsed
        finishedAutoCollapseDeadline = nil
        autoCollapseTask?.cancel()
    }

    /// Called by the window controller only after the compact frame is in
    /// place. If another presentation interrupted the shrink, its content wins.
    func completeCollapsePresentation() {
        guard state == .collapsed else { return }
        presentedState = .collapsed
        finishedSessionSnapshot = nil
    }

    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    func cancelAutoCollapse() {
        autoCollapseTask?.cancel()
    }

    func updateFinishedContentHeight(_ height: CGFloat) {
        let fitted = FinishedReplyWindowLayout.fittedHeight(height)
        guard abs((dynamicFinishedHeight ?? Self.finishedSize.height) - fitted) > 0.5 else { return }
        dynamicFinishedHeight = fitted
    }

    func updateExpandedContentHeight(_ height: CGFloat) {
        let fitted = min(
            SessionListWindowLayout.maximumHeight,
            max(1, height)
        )
        guard abs((dynamicExpandedHeight ?? Self.collapsedSize.height) - fitted) > 0.5 else {
            return
        }
        dynamicExpandedHeight = fitted
    }

    func showFinished(session: Session) {
        autoCollapseTask?.cancel()
        finishedAutoCollapseDeadline = Date().addingTimeInterval(Self.finishedHoverCeiling)
        finishedSessionSnapshot = session
        dynamicFinishedHeight = Self.finishedSize.height
        let finishedState = NotchState.finished(sessionId: session.id)
        presentedState = finishedState
        state = finishedState
        scheduleAutoCollapse(delay: Self.finishedCardVisibilityDuration)
    }

    func showPermission(sessionId: String, contentHeight: CGFloat? = nil) {
        autoCollapseTask?.cancel()
        finishedSessionSnapshot = nil
        dynamicPermissionHeight = contentHeight
        let permissionState = NotchState.permission(sessionId: sessionId)
        presentedState = permissionState
        state = permissionState
    }

    func dismissPermission() {
        collapse()
    }

    func showQuestion(sessionId: String) {
        autoCollapseTask?.cancel()
        finishedSessionSnapshot = nil
        suppressedQuestionSessionIDs.remove(sessionId)
        let questionState = NotchState.question(sessionId: sessionId)
        presentedState = questionState
        state = questionState
    }

    func dismissQuestion() {
        collapse()
    }

    func suppressQuestion(sessionId: String) {
        suppressedQuestionSessionIDs.insert(sessionId)
        collapse()
    }

    /// Called after a user closes an expanded reply. It starts a fresh bounded
    /// dismissal window instead of leaving the compact result open forever.
    func resumeFinishedAutoCollapse() {
        guard case .finished = state else { return }
        finishedAutoCollapseDeadline = Date().addingTimeInterval(Self.finishedHoverCeiling)
        scheduleAutoCollapse(delay: Self.finishedCardVisibilityDuration)
    }

    private func scheduleAutoCollapse(delay: Double) {
        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, isExpanded else { return }
            switch Self.autoCollapseDecision(
                state: state,
                isHovered: isHovered,
                finishedDeadline: finishedAutoCollapseDeadline,
                now: Date()
            ) {
            case .collapse:
                collapse()
            case .rearm(let nextDelay):
                scheduleAutoCollapse(delay: nextDelay)
            case .pause:
                break
            }
        }
    }

    static func autoCollapseDecision(
        state: NotchState,
        isHovered: Bool,
        finishedDeadline: Date?,
        now: Date
    ) -> AutoCollapseDecision {
        switch state {
        case .collapsed, .permission, .question:
            return .pause
        case .finished:
            guard let finishedDeadline else { return .collapse }
            let remaining = finishedDeadline.timeIntervalSince(now)
            guard remaining > 0 else { return .collapse }
            return isHovered ? .rearm(min(Self.autoCollapseRearmInterval, remaining)) : .collapse
        case .expanded:
            return isHovered ? .rearm(Self.autoCollapseRearmInterval) : .collapse
        }
    }

    static func autoCollapseDelayAfterMouseExit(for state: NotchState) -> TimeInterval? {
        switch state {
        case .expanded, .finished:
            return Self.expandedMouseExitDelay
        case .collapsed, .permission, .question:
            return nil
        }
    }

    func mouseEntered() {
        isHovered = true
        // Don't cancel auto-collapse for finished notifications — they should always auto-dismiss
        if case .finished = state { return }
        autoCollapseTask?.cancel()
    }

    func mouseExited() {
        isHovered = false
        guard let delay = Self.autoCollapseDelayAfterMouseExit(for: state) else { return }
        scheduleAutoCollapse(delay: delay)
    }
}
