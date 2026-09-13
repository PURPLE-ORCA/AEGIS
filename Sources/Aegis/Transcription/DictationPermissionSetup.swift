import AppKit
import AVFoundation
import SwiftUI

struct DictationPermissions: Equatable {
    var accessibility: Bool
    var keyboard: Bool
    var microphone: Bool
    var isReady: Bool { accessibility && keyboard && microphone }
    var next: DictationPermission? {
        if !accessibility { return .accessibility }
        if !keyboard { return .keyboard }
        if !microphone { return .microphone }
        return nil
    }
    static func current() -> Self {
        Self(accessibility: AXIsProcessTrusted(), keyboard: CGPreflightListenEventAccess(),
             microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }
    func allows(_ permission: DictationPermission) -> Bool {
        switch permission {
        case .accessibility: return accessibility
        case .keyboard: return keyboard
        case .microphone: return microphone
        }
    }
}

enum DictationPermission: String, CaseIterable {
    case accessibility, keyboard, microphone
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .keyboard: return "Input Monitoring"
        case .microphone: return "Microphone"
        }
    }
    var reason: String {
        switch self {
        case .accessibility: return "Insert your words into the app you're using."
        case .keyboard: return "Recognize the Shift shortcut while you use other apps."
        case .microphone: return "Record your voice when you start dictation."
        }
    }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .keyboard: pane = "Privacy_ListenEvent"
        case .microphone: pane = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

extension Notification.Name {
    static let dictationPermissionsChanged = Notification.Name("Aegis.dictationPermissionsChanged")
}

@MainActor
final class DictationPermissionSetup: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DictationPermissionSetup()
    @Published private(set) var permissions = DictationPermissions.current()
    @Published private(set) var selected: DictationPermission = .accessibility
    @Published private(set) var showRecovery = false
    @Published private(set) var openingError: String?
    private var panel: NSPanel?
    private var timer: Timer?

    var applicationURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    func refresh(revealRecovery: Bool = false) {
        let current = DictationPermissions.current()
        if current.isReady { showRecovery = false }
        else if revealRecovery { showRecovery = true }
        guard permissions != current else { return }
        permissions = current
        NotificationCenter.default.post(name: .dictationPermissionsChanged, object: nil)
    }

    func show() {
        refresh()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 620),
                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Set up dictation"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 620))
            let host = NSHostingView(rootView: DictationPermissionSetupView(setup: self))
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            self.panel = panel
        }
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel?.setFrameOrigin(NSPoint(x: frame.maxX - 356, y: frame.midY - 310))
        }
        panel?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let next = permissions.next { open(next) }
    }

    func open(_ permission: DictationPermission) {
        selected = permission
        openingError = nil
        if permission == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task {
                _ = await HermesMicrophonePermission.request()
                refresh()
                if !permissions.microphone { openSettings(permission) }
            }
        } else {
            openSettings(permission)
        }
    }

    private func openSettings(_ permission: DictationPermission) {
        if !NSWorkspace.shared.open(permission.settingsURL) {
            openingError = "Open System Settings, then Privacy & Security > \(permission.title)."
        }
    }

    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

private struct DictationPermissionSetupView: View {
    @ObservedObject var setup: DictationPermissionSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setup.permissions.isReady ? "You're ready to dictate" : "Give dictation access")
                .font(.title2.weight(.semibold))
            Text(setup.permissions.isReady ? "Return to a text field and use your dictation shortcut to begin." : "Allow these permissions once. Aegis checks them as you go.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                ForEach(DictationPermission.allCases, id: \.self) { permission in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: setup.permissions.allows(permission) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(setup.permissions.allows(permission) ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(permission.title).fontWeight(.medium)
                            Text(permission.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(setup.permissions.allows(permission) ? "Allowed" : "Open") { setup.open(permission) }
                            .disabled(setup.permissions.allows(permission))
                            .accessibilityLabel("Open \(permission.title) settings")
                    }
                }
            }
            Divider()
            if setup.permissions.isReady {
                Label("All permissions allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if setup.selected == .microphone {
                Text("Turn on Aegis in Microphone settings. If macOS asks you to quit and reopen Aegis, choose that option.")
                    .font(.callout)
            } else {
                if let url = setup.applicationURL {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Aegis").fontWeight(.semibold)
                            Text("Drag into \(setup.selected.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .onDrag { NSItemProvider(object: url as NSURL) }
                    .accessibilityLabel("Aegis app. Drag into the \(setup.selected.title) app list.")
                    Button("Show Aegis in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Text("Drop Aegis into the app list, then turn its switch on. If it's already listed, turn it on. You can also use the + button to add Aegis.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if setup.showRecovery && !setup.permissions.isReady {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Already switched on?").fontWeight(.medium)
                    Text("Remove Aegis with the − button, then drag this copy back and enable it. macOS can keep an old app entry after an update.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let error = setup.openingError { Text(error).font(.callout).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            HStack {
                Button("Check again") { setup.refresh(revealRecovery: true) }
                Spacer()
                if let next = setup.permissions.next, setup.permissions.allows(setup.selected) {
                    Button("Continue") { setup.open(next) }.buttonStyle(.borderedProminent)
                } else {
                    Button(setup.permissions.isReady ? "Done" : "Later") { setup.close() }
                }
            }
        }
        .padding(22)
        .frame(width: 340, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
