import AppKit
import AVFoundation
import Combine

@MainActor
final class DictationController {
    private let settings: SettingsStore
    private let shortcut = GlobalDictationShortcut()
    private let audio = DictationAudio()
    private let runner = HermesHandoffRunner()
    private let model = HermesVoiceCapsuleModel()
    private lazy var capsule = HermesVoiceCapsuleWindowController(model: model)
    private var subscriptions = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var generation = UUID()
    private var destination: DictationInsertion?
    private var destinationFailure: String?
    private var activeDevice: String?
    private var startedAt: Date?
    private var requesting = false
    private var stopRequested = false
    private var enabled = false

    init(settings: SettingsStore) {
        self.settings = settings
        model.isDictation = true
    }

    func start() {
        shortcut.onAction = { [weak self] in self?.handle($0) }
        shortcut.onFailure = { [weak self] in
            self?.fail(DictationFailure(message: "Keyboard monitoring was interrupted. Try the shortcut again."))
        }
        settings.$dictationEnabled.combineLatest(settings.$dictationMode, settings.$dictationShiftKey)
            .sink { [weak self] enabled, mode, key in
                guard let self else { return }
                cancel()
                shortcut.stop()
                self.enabled = enabled
                shortcut.state = DictationShortcutState(mode: mode, key: key)
                model.stopHint = mode == .hold ? "Release Shift" : "Double-press Shift"
                registerShortcut()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .dictationPermissionsChanged)
            .sink { [weak self] _ in self?.registerShortcut() }.store(in: &subscriptions)
        DictationMicrophoneMonitor.shared.$devices.dropFirst().sink { [weak self] devices in
            guard let self, let activeDevice, !devices.contains(where: { $0.id == activeDevice }) else { return }
            cancel()
            fail(DictationFailure(message: "The recording microphone disconnected. Reconnect it or try again with the fallback microphone."))
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.shortcut.applicationChanged()
            }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.cancel() }.store(in: &subscriptions)
    }

    private func registerShortcut() {
        guard enabled else { settings.dictationStatus = ""; return }
        guard DictationPermissions.current().isReady else {
            shortcut.stop()
            settings.dictationStatus = "Finish setting up dictation access to start."
            return
        }
        settings.dictationStatus = shortcut.start() ? "Ready" : "Keyboard access has changed. Quit and reopen Aegis to apply it."
    }

    func stop() {
        enabled = false
        shortcut.stop()
        cancel()
        subscriptions.removeAll()
    }

    private func handle(_ action: DictationShortcutState.Action) {
        switch action {
        case .start:
            guard operation == nil, startedAt == nil, !requesting else { shortcut.reset(); return }
            begin()
        case .stop:
            if requesting { stopRequested = true }
            else if startedAt != nil { finish() }
        case .cancel: cancel()
        }
    }

    private func begin() {
        guard enabled else { return }
        dismissal?.cancel()
        do {
            destination = try DictationInsertion.capture()
            destinationFailure = nil
        } catch let error as DictationCaptureError {
            fail(error)
            return
        } catch {
            destination = nil
            destinationFailure = error.localizedDescription
        }
        generation = UUID()
        let token = generation
        requesting = true
        stopRequested = false
        model.phase = .requestingPermission
        model.level = 0
        model.projectName = "Dictation"
        capsule.present()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let granted = await HermesMicrophonePermission.request()
                guard token == generation, !Task.isCancelled else { return }
                guard granted else { throw HermesHandoffError.microphoneDenied }
                if stopRequested { cancel(); return }
                let preference = settings.dictationMicrophoneID
                let devices = await Task.detached { DictationMicrophone.available() }.value
                guard token == generation, !Task.isCancelled else { return }
                guard let device = DictationMicrophone.resolve(preference: preference, devices: devices) else {
                    throw HermesHandoffError.microphoneUnavailable
                }
                activeDevice = device.id
                model.projectName = device.name
                try await audio.start(device: device.deviceID, level: { [weak self] level in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.model.level = level
                    }
                }, failure: { [weak self] in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.cancel()
                        self.fail(HermesHandoffError.recordingFailed)
                    }
                })
                guard token == generation, !Task.isCancelled else { return }
                requesting = false
                operation = nil
                startedAt = Date()
                model.phase = .recording
                settings.dictationStatus = DictationMicrophoneMonitor.shared.status(preference: preference)
                if stopRequested { finish(); return }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            } catch {
                guard token == generation else { return }
                requesting = false
                await audio.cancel()
                guard token == generation else { return }
                operation = nil
                fail(error)
            }
        }
    }

    private func finish() {
        guard let startedAt else { return }
        self.startedAt = nil
        activeDevice = nil
        timeout?.cancel()
        shortcut.reset()
        let duration = Date().timeIntervalSince(startedAt)
        let token = generation
        let target = destination
        let targetFailure = destinationFailure
        model.phase = .transcribing
        model.level = 0
        settings.dictationStatus = "Transcribing…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let file = await audio.stop(), duration >= 0.25 else { throw HermesHandoffError.noSpeech }
                guard let installation = await Task.detached(operation: { HermesHandoffConfiguration.installation() }).value else {
                    throw HermesHandoffError.installationMissing
                }
                let transcript = try await runner.transcribe(audioFile: file, installation: installation)
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                do {
                    guard let target else {
                        throw DictationFailure(message: targetFailure ?? "There was no text field selected when recording started.")
                    }
                    model.phase = .submitting
                    try await target.insert(transcript)
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    model.phase = .sent
                    settings.dictationStatus = "Text inserted"
                    dismiss(after: 1.2)
                } catch {
                    guard token == generation, !Task.isCancelled else { throw CancellationError() }
                    try DictationTranscriptController.shared.append(transcript)
                    model.phase = .transcriptReady
                    settings.dictationStatus = "Copied to clipboard. \(error.localizedDescription)"
                    dismiss(after: 2)
                }
            } catch {
                if token == generation && !Task.isCancelled { fail(error) }
            }
            await audio.removeRecording()
            if token == generation { operation = nil }
        }
    }

    private func cancel() {
        generation = UUID()
        operation?.cancel()
        // Keep the operation occupied until cleanup completes, so old work cannot remove a new recording.
        let previous = operation
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            await runner.stop()
            await previous?.value
            await audio.cancel()
            if token == generation { operation = nil }
        }
        timeout?.cancel()
        dismissal?.cancel()
        requesting = false
        stopRequested = false
        startedAt = nil
        activeDevice = nil
        destination = nil
        destinationFailure = nil
        shortcut.reset()
        capsule.dismiss()
    }

    private func fail(_ error: Error) {
        shortcut.reset()
        activeDevice = nil
        model.level = 0
        model.phase = .failed(error.localizedDescription)
        settings.dictationStatus = error.localizedDescription
        capsule.present()
        dismiss(after: 5)
    }

    private func dismiss(after seconds: Double) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.capsule.dismiss()
        }
    }
}

enum HermesMicrophonePermission {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
