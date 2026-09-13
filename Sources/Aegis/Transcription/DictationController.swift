import AppKit
import AVFoundation
import Combine

@MainActor
final class DictationController {
    private let preparationLimit: Duration
    private let requestMicrophone: () async -> Bool
    private let settings: SettingsStore
    private let shortcut = GlobalDictationShortcut()
    private var audio = DictationAudio()
    private let outputMute = DictationOutputMute()
    private let runner = HermesHandoffRunner()
    private let model = HermesVoiceCapsuleModel()
    private lazy var capsule = HermesVoiceCapsuleWindowController(model: model)
    private var subscriptions = Set<AnyCancellable>()
    private(set) var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var generation = UUID()
    private var destination: DictationInsertion?
    private var destinationFailure: String?
    private var destinationNeedsSettling = false
    private var activeDevice: String?
    private var startedAt: Date?
    private(set) var requesting = false
    private var enabled = false

    init(settings: SettingsStore, preparationLimit: Duration = .seconds(10),
         requestMicrophone: @escaping () async -> Bool = HermesMicrophonePermission.request) {
        self.preparationLimit = preparationLimit
        self.requestMicrophone = requestMicrophone
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
                self?.destinationNeedsSettling = true
                self?.shortcut.applicationChanged()
            }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.destinationNeedsSettling = true }.store(in: &subscriptions)
        settings.$dictationMuteWhileRecording.dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled { restoreOutputSound() }
                else if startedAt != nil {
                    do { try outputMute.mute() }
                    catch { cancel(); fail(error) }
                }
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

    func handle(_ action: DictationShortcutState.Action) {
        switch action {
        case .start:
            guard operation == nil, startedAt == nil, !requesting else { shortcut.reset(); return }
            begin()
        case .stop:
            if requesting { cancel() }
            else if startedAt != nil { finish() }
        case .cancel: cancel()
        }
    }

    private func begin() {
        guard enabled else { return }
        dismissal?.cancel()
        do {
            destination = try DictationInsertion.capture()
            destinationNeedsSettling = false
            destinationFailure = nil
        } catch let error as DictationCaptureError {
            fail(error)
            return
        } catch {
            destination = nil
            destinationFailure = error.localizedDescription
        }
        prepareMicrophone()
        capsule.present()
    }

    func prepareMicrophone() {
        let audio = DictationAudio()
        self.audio = audio
        generation = UUID()
        let token = generation
        requesting = true
        model.phase = .requestingPermission
        model.level = 0
        model.projectName = "Dictation"
        settings.dictationStatus = "Preparing microphone…"
        timeout = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: preparationLimit)
            guard !Task.isCancelled, token == generation, requesting else { return }
            Log.error("Dictation preparation timed out")
            cancel()
            fail(DictationFailure(message: "Microphone preparation took too long. Try dictating again."))
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                Log.info("Dictation preparation stage=permission")
                let granted = await requestMicrophone()
                guard token == generation, !Task.isCancelled else { return }
                guard granted else { throw HermesHandoffError.microphoneDenied }
                let preference = settings.dictationMicrophoneID
                Log.info("Dictation preparation stage=devices")
                let devices = await Task.detached { DictationMicrophone.available() }.value
                guard token == generation, !Task.isCancelled else { return }
                guard let device = DictationMicrophone.resolve(preference: preference, devices: devices) else {
                    throw HermesHandoffError.microphoneUnavailable
                }
                activeDevice = device.id
                model.projectName = device.name
                if settings.dictationMuteWhileRecording {
                    Log.info("Dictation preparation stage=mute-output")
                    try outputMute.mute()
                }
                Log.info("Dictation preparation stage=audio-start")
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
                Log.info("Dictation preparation stage=recording")
                timeout?.cancel()
                requesting = false
                operation = nil
                startedAt = Date()
                model.phase = .recording
                settings.dictationStatus = DictationMicrophoneMonitor.shared.status(preference: preference)
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            } catch {
                guard token == generation else { return }
                cancel()
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
                let recordedFile = await audio.stop()
                restoreOutputSound()
                guard let file = recordedFile, duration >= 0.25 else { throw HermesHandoffError.noSpeech }
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
                    let verified = try await target.insert(transcript, requiresSettling: destinationNeedsSettling)
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    if !verified { DictationTranscriptController.shared.retain(transcript) }
                    model.phase = verified ? .sent : .pasteUnverified
                    settings.dictationStatus = verified ? "Text inserted" : "Paste sent. Check the field; your transcript is saved in Transcription settings."
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

    private func restoreOutputSound() {
        settings.dictationAudioStatus = outputMute.restore() ? "" : "Could not restore sound. Unmute your output in macOS Sound settings."
    }

    private func cancel() {
        restoreOutputSound()
        generation = UUID()
        operation?.cancel()
        // Transcription cleanup stays serialized; preparation uses a recorder owned by that attempt.
        let previous = operation
        let audio = audio
        let token = generation
        if requesting {
            // A stalled preparation must not hold the next attempt; its recorder is never reused.
            operation = nil
            self.audio = DictationAudio()
            Task { await audio.cancel() }
        } else {
            operation = Task { [weak self] in
                guard let self else { return }
                await runner.stop()
                await previous?.value
                await audio.cancel()
                if token == generation { operation = nil }
            }
        }
        timeout?.cancel()
        dismissal?.cancel()
        if requesting { settings.dictationStatus = enabled ? "Ready" : "" }
        requesting = false
        startedAt = nil
        activeDevice = nil
        destination = nil
        destinationFailure = nil
        shortcut.reset()
        capsule.dismiss()
    }

    private func fail(_ error: Error) {
        restoreOutputSound()
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
