import Foundation
import Combine

enum CompanionState: String, CaseIterable, Equatable {
    case idle
    case observing
    case working
    case attention
    case success
    case failure

    var atlasRow: Int {
        switch self {
        case .idle: return 0
        case .observing: return 8
        case .working: return 7
        case .attention: return 6
        case .success: return 3
        case .failure: return 5
        }
    }

    var frameCount: Int {
        switch self {
        case .idle: return 6
        case .observing: return 6
        case .working: return 6
        case .attention: return 6
        case .success: return 4
        case .failure: return 8
        }
    }

    var frameInterval: Duration {
        switch self {
        case .idle: return .milliseconds(420)
        case .observing: return .milliseconds(360)
        case .working: return .milliseconds(180)
        case .attention: return .milliseconds(260)
        case .success: return .milliseconds(220)
        case .failure: return .milliseconds(300)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "Mysa is idle"
        case .observing: return "Mysa is observing"
        case .working: return "Mysa is working"
        case .attention: return "Mysa needs your attention"
        case .success: return "Mysa reports success"
        case .failure: return "Mysa reports a failure"
        }
    }
}

enum CompanionStatePolicy {
    static func resolve(
        statuses: [SessionStatus],
        hasSessions: Bool,
        transient: CompanionState?
    ) -> CompanionState {
        if statuses.contains(.waitingPermission) { return .attention }
        if statuses.contains(.error) { return .failure }
        if statuses.contains(where: { $0 == .thinking || $0 == .toolUse }) { return .working }
        if transient == .success { return .success }
        if hasSessions { return .observing }
        return .idle
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var state: CompanionState = .idle
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var isWindowVisible = false

    private var sessions: [String: Session] = [:]
    private var transientState: CompanionState?
    private var transientTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(sessionStore: SessionStore) {
        sessionStore.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.sessions = sessions
                self?.refreshState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .store(in: &cancellables)
    }

    deinit {
        transientTask?.cancel()
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .sessionEnded,
             .statusChanged(_, .idle):
            showTransient(.success, duration: .seconds(2))
        default:
            break
        }
    }

    private func showTransient(_ state: CompanionState, duration: Duration) {
        transientTask?.cancel()
        transientState = state
        refreshState()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.transientState = nil
            self?.refreshState()
        }
    }

    private func refreshState() {
        state = CompanionStatePolicy.resolve(
            statuses: sessions.values.map(\.status),
            hasSessions: sessions.values.contains(where: { $0.status != .completed }),
            transient: transientState
        )
    }
}
