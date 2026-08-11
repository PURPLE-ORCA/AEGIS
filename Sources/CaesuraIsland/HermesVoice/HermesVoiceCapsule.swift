import AppKit
import SwiftUI

enum HermesVoiceHandoffPhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case transcribing
    case submitting
    case sent
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Hold to speak"
        case .requestingPermission:
            return "Microphone access"
        case .recording:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .submitting:
            return "Sending to Hermes…"
        case .sent:
            return "Sent to Hermes"
        case .failed:
            return "Handoff stopped"
        }
    }

    var symbol: String {
        switch self {
        case .idle, .requestingPermission, .recording:
            return "mic.fill"
        case .transcribing, .submitting:
            return "waveform"
        case .sent:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        }
    }

    var accent: Color {
        switch self {
        case .recording:
            return Color(red: 0.77, green: 0.45, blue: 1)
        case .sent:
            return Color(red: 0.35, green: 0.86, blue: 0.64)
        case .failed:
            return Color(red: 1, green: 0.42, blue: 0.45)
        default:
            return Color(red: 0.63, green: 0.42, blue: 1)
        }
    }

    var detail: String? {
        if case .failed(let message) = self { return message }
        if case .requestingPermission = self { return "Confirm once, then keep holding" }
        return nil
    }
}

@MainActor
final class HermesVoiceCapsuleModel: ObservableObject {
    @Published var phase: HermesVoiceHandoffPhase = .idle
    @Published var level: Double = 0
    @Published var target: HermesHandoffTarget = .newSession
    @Published var projectName = "PURPLE-VAULT"
}

struct HermesVoiceCapsuleView: View {
    @ObservedObject var model: HermesVoiceCapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(model.phase.accent.opacity(0.17))
                    .overlay(Circle().stroke(model.phase.accent.opacity(0.45), lineWidth: 1))
                Image(systemName: model.phase.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.phase.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: isProcessing && !reduceMotion)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.phase.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let detail = model.phase.detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                } else if model.phase == .recording {
                    levelMeter
                } else {
                    Text("\(model.target.capsuleLabel) · \(model.projectName)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if model.phase == .recording {
                Text("RELEASE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(model.phase.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(model.phase.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 15)
        .frame(width: 330, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.035, green: 0.028, blue: 0.055).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(model.phase.accent.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: model.phase.accent.opacity(0.22), radius: 18, y: 8)
        )
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.phase.title)
        .accessibilityValue(model.phase.detail ?? "\(model.target.displayName), \(model.projectName)")
    }

    private var isProcessing: Bool {
        model.phase == .transcribing || model.phase == .submitting
    }

    private var levelMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<10, id: \.self) { index in
                Capsule()
                    .fill(indexThreshold(index) <= model.level ? model.phase.accent : Color.white.opacity(0.13))
                    .frame(width: 3, height: meterHeight(index))
            }
        }
        .frame(height: 12, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: model.level)
    }

    private func indexThreshold(_ index: Int) -> Double {
        Double(index + 1) / 10
    }

    private func meterHeight(_ index: Int) -> CGFloat {
        let shape: [CGFloat] = [4, 6, 9, 12, 8, 11, 7, 10, 6, 4]
        return shape[index]
    }
}

@MainActor
final class HermesVoiceCapsuleWindowController: NSWindowController {
    init(model: HermesVoiceCapsuleModel) {
        let frame = NSRect(x: 0, y: 0, width: 370, height: 108)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: 28)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: HermesVoiceCapsuleView(model: model))
        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        let screen = ScreenDetector.notchScreen
        let x = screen.frame.midX - window.frame.width / 2
        let y = screen.frame.maxY - ScreenDetector.notchHeight - window.frame.height - 14
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            window.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            window.animator().alphaValue = 0
        } completionHandler: {
            DispatchQueue.main.async { window.orderOut(nil) }
        }
    }
}
