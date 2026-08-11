import AVFoundation
import Combine
import Foundation

@MainActor
final class HermesVoiceHandoffController {
    private let settingsStore: SettingsStore
    private let hotKey = GlobalPushToTalkHotKey()
    private let recorder = HermesAudioRecorder()
    private let runner = HermesHandoffRunner()
    private let capsuleModel = HermesVoiceCapsuleModel()
    private lazy var capsuleWindow = HermesVoiceCapsuleWindowController(model: capsuleModel)
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyHeld = false
    private var recordingStartedAt: Date?
    private var autoStopTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        hotKey.onPress = { [weak self] in self?.pushToTalkPressed() }
        hotKey.onRelease = { [weak self] in self?.pushToTalkReleased() }

        settingsStore.$hermesVoiceHandoffEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyEnabledState(enabled)
            }
            .store(in: &cancellables)
    }

    func stop() {
        hotKey.unregister()
        autoStopTask?.cancel()
        dismissTask?.cancel()
        handoffTask?.cancel()
        recorder.cancel()
        capsuleWindow.dismiss()
        Task { await runner.stop() }
    }

    private func applyEnabledState(_ enabled: Bool) {
        if enabled {
            if hotKey.register() {
                Log.info("Hermes push-to-talk registered: \(HermesHandoffConfiguration.defaultShortcutLabel)")
            } else {
                Log.error("Hermes push-to-talk shortcut is unavailable")
            }
        } else {
            hotKey.unregister()
            cancelCurrentHandoff()
        }
    }

    private func pushToTalkPressed() {
        guard settingsStore.hermesVoiceHandoffEnabled,
              !hotKeyHeld,
              handoffTask == nil else { return }
        hotKeyHeld = true
        dismissTask?.cancel()
        updateCapsuleContext()
        capsuleModel.phase = .requestingPermission
        capsuleModel.level = 0
        capsuleWindow.present()

        Task { [weak self] in
            guard let self else { return }
            let granted = await requestMicrophoneAccess()
            guard hotKeyHeld else {
                capsuleWindow.dismiss()
                return
            }
            guard granted else {
                hotKeyHeld = false
                showFailure(HermesHandoffError.microphoneDenied)
                return
            }
            beginRecording()
        }
    }

    private func pushToTalkReleased() {
        guard hotKeyHeld else { return }
        hotKeyHeld = false
        guard recorder.isRecording else { return }
        finishRecording()
    }

    private func beginRecording() {
        do {
            _ = try recorder.start { [weak self] level in
                DispatchQueue.main.async {
                    self?.capsuleModel.level = level
                }
            }
            recordingStartedAt = Date()
            capsuleModel.phase = .recording
            autoStopTask?.cancel()
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.recorder.isRecording else { return }
                    self.hotKeyHeld = false
                    self.finishRecording()
                }
            }
        } catch let error as HermesHandoffError {
            hotKeyHeld = false
            showFailure(error)
        } catch {
            hotKeyHeld = false
            showFailure(HermesHandoffError.recordingFailed)
        }
    }

    private func finishRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil
        let duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil

        guard duration >= 0.25, let audioFile = recorder.stop() else {
            recorder.cancel()
            showFailure(HermesHandoffError.noSpeech)
            return
        }

        capsuleModel.level = 0
        capsuleModel.phase = .transcribing
        let rawDirectory = settingsStore.hermesVoiceWorkingDirectory
        let target = settingsStore.hermesVoiceTarget

        handoffTask = Task { [weak self] in
            guard let self else { return }
            defer {
                recorder.removeRecording()
                handoffTask = nil
            }

            do {
                guard let installation = HermesHandoffConfiguration.installation() else {
                    throw HermesHandoffError.installationMissing
                }
                let workingDirectory = try HermesHandoffConfiguration.validatedWorkingDirectory(rawDirectory)
                let transcript = try await runner.transcribe(
                    audioFile: audioFile,
                    installation: installation
                )
                guard !Task.isCancelled else { return }

                capsuleModel.phase = .submitting
                try await runner.submit(
                    transcript: transcript,
                    installation: installation,
                    workingDirectory: workingDirectory,
                    target: target
                )
                guard !Task.isCancelled else { return }
                capsuleModel.phase = .sent
                scheduleDismiss(after: 1.15)
            } catch is CancellationError {
                capsuleWindow.dismiss()
            } catch let error as HermesHandoffError {
                showFailure(error)
            } catch {
                showFailure(HermesHandoffError.submissionFailed)
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func updateCapsuleContext() {
        capsuleModel.target = settingsStore.hermesVoiceTarget
        let directory = NSString(string: settingsStore.hermesVoiceWorkingDirectory).expandingTildeInPath
        let name = URL(fileURLWithPath: directory).lastPathComponent
        capsuleModel.projectName = name.isEmpty ? "Hermes" : name
    }

    private func showFailure(_ error: HermesHandoffError) {
        capsuleModel.level = 0
        capsuleModel.phase = .failed(error.localizedDescription)
        scheduleDismiss(after: 3.4)
        Log.error("Hermes voice handoff: \(error.localizedDescription)")
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.capsuleWindow.dismiss()
            }
        }
    }

    private func cancelCurrentHandoff() {
        hotKeyHeld = false
        handoffTask?.cancel()
        handoffTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        recorder.cancel()
        capsuleWindow.dismiss()
    }
}
