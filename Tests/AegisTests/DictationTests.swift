import XCTest
import AppKit
import AVFoundation
import UniformTypeIdentifiers
@testable import Aegis

final class DictationTests: XCTestCase {
    func testDefaultsPreserveExistingPreferencesAndLegacyHandoff() {
        let name = "AegisDictationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "hermesVoiceHandoffEnabled")
        SettingsStore.registerDictationDefaults(defaults)
        XCTAssertFalse(defaults.bool(forKey: "dictationEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "dictationMuteWhileRecording"))
        XCTAssertEqual(defaults.string(forKey: "dictationMode"), "toggle")
        XCTAssertEqual(defaults.string(forKey: "dictationShiftKey"), "either")
        XCTAssertEqual(defaults.string(forKey: "dictationMicrophoneID"), "")
        defaults.set("missing-device", forKey: "dictationMicrophoneID")
        defaults.set("hold", forKey: "dictationMode")
        defaults.set(true, forKey: "dictationEnabled")
        SettingsStore.registerDictationDefaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: "dictationEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "hermesVoiceHandoffEnabled"))
        XCTAssertEqual(defaults.string(forKey: "dictationMode"), "hold")
        XCTAssertEqual(defaults.string(forKey: "dictationMicrophoneID"), "missing-device")
    }

    @MainActor
    func testStopDuringMicrophonePreparationAllowsRetryBeforeOldRequestReturns() async {
        _ = NSApplication.shared
        var pending: [CheckedContinuation<Bool, Never>] = []
        let controller = DictationController(settings: SettingsStore(), requestMicrophone: {
            await withCheckedContinuation { pending.append($0) }
        })
        controller.prepareMicrophone()
        while pending.isEmpty { await Task.yield() }
        let oldOperation = controller.operation
        controller.handle(.stop)
        XCTAssertFalse(controller.requesting)
        XCTAssertNil(controller.operation)
        controller.prepareMicrophone()
        while pending.count < 2 { await Task.yield() }
        let retry = controller.operation
        pending.removeFirst().resume(returning: true)
        await oldOperation?.value
        XCTAssertTrue(controller.requesting, "A late callback must not change the retry")
        XCTAssertNotNil(controller.operation)
        controller.handle(.stop)
        pending.removeFirst().resume(returning: false)
        await retry?.value
        XCTAssertFalse(controller.requesting)
        XCTAssertNil(controller.operation)
        controller.stop()
    }

    @MainActor
    func testMicrophonePreparationDeadlineReleasesOperationAndAllowsRetry() async throws {
        _ = NSApplication.shared
        var pending: [CheckedContinuation<Bool, Never>] = []
        let settings = SettingsStore()
        let controller = DictationController(settings: settings, preparationLimit: .milliseconds(20), requestMicrophone: {
            await withCheckedContinuation { pending.append($0) }
        })
        controller.prepareMicrophone()
        while pending.isEmpty { await Task.yield() }
        let oldOperation = controller.operation
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.requesting)
        XCTAssertNil(controller.operation)
        XCTAssertTrue(settings.dictationStatus.contains("took too long"))
        controller.prepareMicrophone()
        while pending.count < 2 { await Task.yield() }
        let retry = controller.operation
        XCTAssertTrue(controller.requesting)
        pending.removeFirst().resume(returning: true)
        await oldOperation?.value
        XCTAssertTrue(controller.requesting)
        controller.handle(.stop)
        pending.removeFirst().resume(returning: false)
        await retry?.value
        controller.stop()
    }

    private func tap(_ state: inout DictationShortcutState, key: UInt16 = 56, at time: Double) -> DictationShortcutState.Action? {
        XCTAssertNil(state.shift(code: key, down: true, at: time))
        return state.shift(code: key, down: false, at: time + 0.05)
    }

    func testDoubleTapEitherShiftTogglesStartAndStop() {
        var state = DictationShortcutState()
        XCTAssertNil(tap(&state, at: 1))
        XCTAssertEqual(tap(&state, key: 60, at: 1.2), .start)
        XCTAssertTrue(state.recording)
        XCTAssertNil(tap(&state, key: 60, at: 2))
        XCTAssertEqual(tap(&state, key: 60, at: 2.2), .stop)
        XCTAssertFalse(state.recording)
        XCTAssertNil(tap(&state, at: 3))
        XCTAssertNil(tap(&state, at: 4))
    }

    func testHoldStartsOnceAndStopsOnRelease() {
        var state = DictationShortcutState(mode: .hold, key: .right)
        XCTAssertNil(state.shift(code: 60, down: true, at: 1))
        XCTAssertNil(state.holdElapsed(at: 1.1))
        XCTAssertEqual(state.holdElapsed(at: 1.3), .start)
        XCTAssertNil(state.shift(code: 60, down: true, at: 1.4))
        XCTAssertNil(state.holdElapsed(at: 1.5))
        XCTAssertEqual(state.shift(code: 60, down: false, at: 2), .stop)
        XCTAssertNil(state.shift(code: 60, down: false, at: 2.1))
    }

    func testTypingCombinationsAndSimultaneousShiftDoNotToggle() {
        var state = DictationShortcutState()
        XCTAssertNil(tap(&state, at: 1))
        XCTAssertNil(state.shift(code: 56, down: true, at: 1.2))
        XCTAssertNil(state.combination())
        XCTAssertNil(state.shift(code: 56, down: false, at: 1.3))
        XCTAssertNil(tap(&state, at: 1.4))
        state.reset()
        XCTAssertNil(state.shift(code: 56, down: true, at: 2))
        XCTAssertNil(state.shift(code: 60, down: true, at: 2.01))
        XCTAssertNil(state.shift(code: 56, down: false, at: 2.1))
        XCTAssertNil(state.shift(code: 60, down: false, at: 2.2))
        XCTAssertNil(tap(&state, at: 2.3))
        state.reset()
        XCTAssertNil(state.shift(code: 56, down: true, at: 3, modified: true))
        XCTAssertNil(state.shift(code: 56, down: false, at: 3.1))
        XCTAssertNil(tap(&state, at: 3.2))
        XCTAssertFalse(state.recording)
    }

    func testHoldTypingCancelsAndResetDiscardsPendingTap() {
        var state = DictationShortcutState(mode: .hold)
        XCTAssertNil(state.shift(code: 56, down: true, at: 1))
        XCTAssertNil(state.combination())
        XCTAssertNil(state.holdElapsed(at: 1.3))
        state.reset()
        XCTAssertNil(state.shift(code: 56, down: true, at: 2))
        XCTAssertEqual(state.holdElapsed(at: 2.3), .start)
        XCTAssertEqual(state.combination(), .cancel)
        XCTAssertNil(state.shift(code: 56, down: false, at: 2.4))
        state = DictationShortcutState()
        XCTAssertNil(tap(&state, at: 3))
        state.reset()
        XCTAssertNil(tap(&state, at: 3.2))
    }

    func testMicrophoneFallbackRetainsPreferenceAndReconnects() {
        let headphones = DictationMicrophone(id: "headset", deviceID: 1, name: "Headset", builtIn: false)
        let builtIn = DictationMicrophone(id: "mac", deviceID: 2, name: "MacBook Microphone", builtIn: true)
        let preference = "headset"
        XCTAssertEqual(DictationMicrophone.resolve(preference: "", devices: [headphones, builtIn]), builtIn)
        XCTAssertEqual(DictationMicrophone.resolve(preference: preference, devices: [builtIn]), builtIn)
        XCTAssertEqual(preference, "headset")
        XCTAssertEqual(DictationMicrophone.resolve(preference: preference, devices: [headphones, builtIn]), headphones)
        XCTAssertNil(DictationMicrophone.resolve(preference: preference, devices: []))
    }

    @MainActor
    func testCapsuleUsesDictationCompletionAndFailureLabels() {
        let model = HermesVoiceCapsuleModel()
        model.isDictation = true
        XCTAssertEqual(model.title, "Ready")
        model.phase = .submitting
        XCTAssertEqual(model.title, "Inserting text…")
        model.phase = .sent
        XCTAssertEqual(model.title, "Text inserted")
        model.phase = .failed("Microphone disconnected")
        XCTAssertEqual(model.title, "Dictation stopped")
        XCTAssertEqual(model.phase.detail, "Microphone disconnected")
        model.isDictation = false
        model.phase = .sent
        XCTAssertEqual(model.title, "Sent to Hermes")
    }
    func testRunnerDrainsLargeOutputAndReturnsTranscript() async throws {
        let directory = try makeTranscriber("print('x' * 100_000)\n    return {'success': True, 'transcript': 'Dictation test'}")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HermesHandoffRunner()
        let text = try await runner.transcribe(audioFile: directory.appendingPathComponent("test.wav"),
            installation: HermesInstallation(rootDirectory: directory, pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3")))
        XCTAssertEqual(text, "Dictation test")
    }

    func testRunnerCancellationStopsTranscription() async throws {
        let directory = try makeTranscriber("import time\n    time.sleep(30)\n    return {'success': True, 'transcript': 'Must not insert'}")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HermesHandoffRunner()
        let operation = Task {
            try await runner.transcribe(audioFile: directory.appendingPathComponent("test.wav"),
                installation: HermesInstallation(rootDirectory: directory, pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3")))
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = Date()
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancelled transcription returned a transcript")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    private func makeTranscriber(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-dictation-test-\(UUID())")
        let tools = directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try "".write(to: tools.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        try "def transcribe_recording(path):\n    \(body)\n".write(
            to: tools.appendingPathComponent("voice_mode.py"), atomically: true, encoding: .utf8)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("test.wav"), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = 0.1 }
        try file.write(from: buffer)
        return directory
    }

    func testPermissionSetupAdvancesOnlyWhenAccessIsGranted() {
        var permissions = DictationPermissions(accessibility: false, keyboard: false, microphone: false)
        XCTAssertEqual(permissions.next, .accessibility)
        XCTAssertFalse(permissions.isReady)
        permissions.accessibility = true
        XCTAssertEqual(permissions.next, .keyboard)
        permissions.keyboard = true
        XCTAssertEqual(permissions.next, .microphone)
        XCTAssertFalse(permissions.isReady)
        permissions.microphone = true
        XCTAssertTrue(permissions.isReady)
        XCTAssertNil(permissions.next)
        permissions.accessibility = false
        XCTAssertFalse(permissions.isReady)
        XCTAssertEqual(permissions.next, .accessibility)
    }

    func testPermissionDragProvidesAppFileURL() {
        let url = URL(fileURLWithPath: "/Applications/Aegis.app", isDirectory: true)
        let provider = NSItemProvider(object: url as NSURL)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(DictationPermission.accessibility.settingsURL.fragment, nil)
        XCTAssertEqual(DictationPermission.accessibility.settingsURL.query, "Privacy_Accessibility")
    }

    func testRunningRecorderIgnoresUnchangedConfigurationNotification() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let sameFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertFalse(HermesAudioRecorder.configurationRequiresStop(
            isRunning: true, originalFormat: format, currentFormat: sameFormat))
    }

    func testRecorderStopsForStoppedEngineOrChangedInputFormat() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertTrue(HermesAudioRecorder.configurationRequiresStop(
            isRunning: false, originalFormat: format, currentFormat: format))
        let changed = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        XCTAssertTrue(HermesAudioRecorder.configurationRequiresStop(
            isRunning: true, originalFormat: format, currentFormat: changed))
    }

    func testDictationKeepsItsOriginalSelectionAcrossApplicationChanges() throws {
        var shortcut = DictationShortcutState()
        XCTAssertNil(tap(&shortcut, at: 1))
        XCTAssertEqual(tap(&shortcut, at: 1.2), .start)
        shortcut.applicationChanged()
        XCTAssertTrue(shortcut.recording)
        XCTAssertNil(tap(&shortcut, at: 2))
        XCTAssertEqual(tap(&shortcut, at: 2.2), .stop)

        let snapshot = DictationInsertionSnapshot(text: "Hello 🌍 world", selection: NSRange(location: 9, length: 5))
        XCTAssertEqual(try snapshot.replacingSelection(with: "Aegis", currentText: "Hello 🌍 world"), "Hello 🌍 Aegis")
    }

    @MainActor
    func testUnavailableDestinationPreservesTextInsteadOfOverwritingEdits() throws {
        let snapshot = DictationInsertionSnapshot(text: "Original", selection: NSRange(location: 8, length: 0))
        XCTAssertThrowsError(try snapshot.replacingSelection(with: " words", currentText: "Edited"))
        let invalid = DictationInsertionSnapshot(text: "Original", selection: NSRange(location: Int.max, length: 1))
        XCTAssertThrowsError(try invalid.replacingSelection(with: " words", currentText: "Original"))
        let transcripts = DictationTranscriptController()
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try transcripts.append("First transcript", clipboard: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "First transcript")
        try transcripts.append("Second transcript", clipboard: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "Second transcript")
        XCTAssertEqual(transcripts.text, "First transcript\n\nSecond transcript")
    }

    func testEmptyRecordingFailsBeforeTranscription() async throws {
        let directory = try makeTranscriber("raise RuntimeError('Empty audio must not reach transcription')")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("empty.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do { _ = try AVAudioFile(forWriting: audio, settings: format.settings) }
        do {
            _ = try await HermesHandoffRunner().transcribe(audioFile: audio,
                installation: HermesInstallation(rootDirectory: directory, pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3")))
            XCTFail("Empty audio was accepted")
        } catch HermesHandoffError.recordingEmpty {
            // The recorder failure is kept distinct from a valid recording containing no speech.
        }
    }

    @MainActor
    func testInsertionWaitsForFocusToSettleAfterSwitchingApps() async throws {
        var checks = 0
        try await DictationInsertion.waitForStableFocus {
            checks += 1
            if checks == 8 {
                throw DictationFailure(message: "Desktop is still switching")
            }
        }
        XCTAssertGreaterThanOrEqual(checks, 21)
    }

    @MainActor
    func testInsertionStopsWhenOriginalFieldNeverRegainsFocus() async {
        do {
            try await DictationInsertion.waitForStableFocus {
                throw DictationFailure(message: "Original field is unavailable")
            }
            XCTFail("Insertion must not proceed without stable focus")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not settle focus"))
        }
    }

    func testMeterThrottlingKeepsUpdatesBelowThirtyPerSecond() {
        var throttle = VoiceLevelThrottle()
        var updates = 0
        for _ in 0..<46 {
            if throttle.shouldPublish(frames: 1024, sampleRate: 48_000) { updates += 1 }
        }
        XCTAssertEqual(updates, 23)
        XCTAssertFalse(throttle.shouldPublish(frames: 0, sampleRate: 48_000))
    }

    @MainActor
    func testPasteVerificationWaitsForDelayedEditorUpdate() async throws {
        var reads = 0
        let verified = try await DictationInsertion.verifyPaste(before: "Original", expected: "Original words") {
            reads += 1
            return reads < 24 ? "Original" : "Original words"
        }
        XCTAssertTrue(verified)
        XCTAssertEqual(reads, 24)
    }

    @MainActor
    func testPasteVerificationRejectsUnexpectedEditsWithoutRetrying() async throws {
        var reads = 0
        let verified = try await DictationInsertion.verifyPaste(before: "Original", expected: "Original words") {
            reads += 1
            return "User edit"
        }
        XCTAssertFalse(verified)
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testSnapshotAllowsMissingReadbackAndPreservesKnownTextGuard() async throws {
        let verified = try await DictationInsertion.verifyPaste(before: nil, expected: nil) { nil }
        XCTAssertFalse(verified)
        let unreadable = DictationInsertionSnapshot(text: nil, selection: nil)
        XCTAssertNil(try unreadable.replacingSelection(with: " words", currentText: nil))
        let noCursor = DictationInsertionSnapshot(text: "Original", selection: nil)
        XCTAssertNil(try noCursor.replacingSelection(with: " words", currentText: "Original"))
        XCTAssertThrowsError(try noCursor.replacingSelection(with: " words", currentText: "Edited"))
    }

    func testEffectiveRangePrefersLiveCaretOverStaleSnapshot() {
        // User kept typing position: caret at end when pasting starts.
        XCTAssertEqual(
            DictationInsertionSnapshot.effectiveInsertionRange(
                snapshotSelection: NSRange(location: 8, length: 0),
                snapshotText: "Original",
                liveSelection: NSRange(location: 8, length: 0),
                currentText: "Original"),
            NSRange(location: 8, length: 0))
        // User moved the caret mid-dictation: respect where they are now.
        XCTAssertEqual(
            DictationInsertionSnapshot.effectiveInsertionRange(
                snapshotSelection: NSRange(location: 8, length: 0),
                snapshotText: "Original",
                liveSelection: NSRange(location: 3, length: 2),
                currentText: "Original"),
            NSRange(location: 3, length: 2))
    }

    func testEffectiveRangeRestoresSnapshotWhenRefocusCollapsesCaretToStart() {
        // Programmatic refocus commonly resets the caret to 0; the snapshot (end
        // of the user's lines) is the intended position, not the start.
        let text = "Line one\nLine two\nLine three"
        let end = (text as NSString).length
        XCTAssertEqual(
            DictationInsertionSnapshot.effectiveInsertionRange(
                snapshotSelection: NSRange(location: end, length: 0),
                snapshotText: text,
                liveSelection: NSRange(location: 0, length: 0),
                currentText: text),
            NSRange(location: end, length: 0))
        XCTAssertEqual(
            DictationInsertionSnapshot.replacing(
                NSRange(location: end, length: 0), in: text, with: " dictated"),
            text + " dictated")
    }

    func testEffectiveRangeFallsBackToEndWhenNoCursorIsExposed() {
        let text = "Line one\nLine two"
        let end = (text as NSString).length
        // Field exposes text but no cursor: append at the end, never at the start.
        XCTAssertEqual(
            DictationInsertionSnapshot.effectiveInsertionRange(
                snapshotSelection: nil,
                snapshotText: text,
                liveSelection: nil,
                currentText: text),
            NSRange(location: end, length: 0))
        // Live caret unreadable but the snapshot survived: keep it.
        XCTAssertEqual(
            DictationInsertionSnapshot.effectiveInsertionRange(
                snapshotSelection: NSRange(location: 4, length: 0),
                snapshotText: text,
                liveSelection: nil,
                currentText: text),
            NSRange(location: 4, length: 0))
        // Nothing readable anywhere: no forced position.
        XCTAssertNil(
            DictationInsertionSnapshot.effectiveInsertionRange(
                snapshotSelection: nil,
                snapshotText: nil,
                liveSelection: nil,
                currentText: nil))
    }

    @MainActor
    func testRecordingMuteRestoresOnlyPreviouslyAudibleOutputs() throws {
        var muted: [UInt32: Bool] = [1: false, 2: true]
        let output = DictationOutputMute(devices: { [1, 2, 1] },
            readMute: { muted[$0]! }, writeMute: { muted[$0] = $1 })
        try output.mute()
        XCTAssertEqual(muted, [1: true, 2: true])
        try output.mute()
        output.restore()
        output.restore()
        XCTAssertEqual(muted, [1: false, 2: true])
    }

    @MainActor
    func testRecordingMuteRollsBackIfAnOutputCannotBeMuted() {
        var muted: [UInt32: Bool] = [1: false, 2: false]
        var writes = 0
        let output = DictationOutputMute(devices: { [1, 2] }, readMute: { muted[$0]! }, writeMute: { device, value in
            if value {
                writes += 1
                if writes == 2 { throw DictationFailure(message: "Output unavailable") }
            }
            muted[device] = value
        })
        XCTAssertThrowsError(try output.mute())
        XCTAssertEqual(muted, [1: false, 2: false])
        var failRestore = true
        let unavailable = DictationOutputMute(devices: { [1] }, readMute: { muted[$0]! }, writeMute: { device, value in
            if !value && failRestore { throw DictationFailure(message: "Output disconnected") }
            muted[device] = value
        })
        try? unavailable.mute()
        XCTAssertFalse(unavailable.restore())
        failRestore = false
        XCTAssertTrue(unavailable.restore())
        XCTAssertEqual(muted[1], false)
    }

}
