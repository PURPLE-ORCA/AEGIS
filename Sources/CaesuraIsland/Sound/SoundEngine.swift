import AVFoundation
import Foundation

private final class AudioConverterInputState: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var delivered = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !delivered else {
            status.pointee = .noDataNow
            return nil
        }
        delivered = true
        status.pointee = .haveData
        return buffer
    }
}

enum AudioEngineLifecycleState: Equatable {
    case stopped
    case running(generation: Int)
    case idleTeardownPending(generation: Int)
}

struct AudioEngineLifecyclePolicy {
    struct PlaybackRequest: Equatable {
        let generation: Int
        let shouldStartEngine: Bool
    }

    private(set) var state: AudioEngineLifecycleState = .stopped
    private(set) var pendingPlaybackCount = 0
    private var generation = 0

    mutating func requestPlayback() -> PlaybackRequest {
        let shouldStartEngine: Bool

        switch state {
        case .stopped:
            generation += 1
            shouldStartEngine = true
        case .running, .idleTeardownPending:
            shouldStartEngine = false
        }

        pendingPlaybackCount += 1
        state = .running(generation: generation)
        return PlaybackRequest(generation: generation, shouldStartEngine: shouldStartEngine)
    }

    mutating func playbackFinished(generation completedGeneration: Int) -> Bool {
        guard currentGeneration == completedGeneration, pendingPlaybackCount > 0 else { return false }

        pendingPlaybackCount -= 1
        guard pendingPlaybackCount == 0 else { return false }

        state = .idleTeardownPending(generation: completedGeneration)
        return true
    }

    mutating func idleDeadlineReached(generation completedGeneration: Int) -> Bool {
        guard state == .idleTeardownPending(generation: completedGeneration) else { return false }
        invalidateRunningGeneration()
        return true
    }

    mutating func startFailed(generation failedGeneration: Int) {
        guard currentGeneration == failedGeneration else { return }
        invalidateRunningGeneration()
    }

    @discardableResult
    mutating func stop() -> Bool {
        guard state != .stopped else { return false }
        invalidateRunningGeneration()
        return true
    }

    private var currentGeneration: Int? {
        switch state {
        case .stopped:
            return nil
        case .running(let generation), .idleTeardownPending(let generation):
            return generation
        }
    }

    private mutating func invalidateRunningGeneration() {
        generation += 1
        pendingPlaybackCount = 0
        state = .stopped
    }
}

enum SoundEvent: String, CaseIterable {
    case sessionStart = "session-start"
    case sessionEnd = "session-end"
    case toolUse = "tool-use"
    case completion = "completion"
    case error = "error"
    case approvalNeeded = "approval-needed"
    case approvalGranted = "approval-granted"
    case approvalDenied = "approval-denied"
}

@MainActor
final class SoundEngine {
    private static let idleTeardownDelay: Duration = .seconds(2)

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var lifecycle = AudioEngineLifecyclePolicy()
    private var idleTeardownTask: Task<Void, Never>?
    private var soundBuffers: [SoundEvent: AVAudioPCMBuffer] = [:]
    private var enabled = true
    private var volume: Float = 0.7
    private var profile: SoundProfile = .quietGlass
    private var eventVolumes: [String: Float] = [:]
    /// event.rawValue → "default" | "off" | "<library filename>".
    private var assignments: [String: String] = [:]

    init() {}

    func play(_ event: SessionEvent) {
        guard enabled else { return }
        let soundEvent: SoundEvent? = {
            switch event {
            case .sessionStarted: return .sessionStart
            case .sessionEnded: return .sessionEnd
            case .toolStarted: return .toolUse
            case .statusChanged(_, let status) where status == .idle: return .completion
            case .statusChanged(_, let status) where status == .error: return .error
            case .permissionRequested: return .approvalNeeded
            case .permissionResponded(_, let allowed): return allowed ? .approvalGranted : .approvalDenied
            default: return nil
            }
        }()

        guard let soundEvent,
              assignments[soundEvent.rawValue] != "off",
              let buffer = buffer(for: soundEvent) else { return }
        playBuffer(buffer, gain: eventVolume(for: soundEvent))
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            stopAudioEngine()
        }
    }

    func setVolume(_ volume: Float) {
        self.volume = max(0, min(1, volume))
        playerNode?.volume = self.volume
    }

    func setProfile(_ profile: SoundProfile) {
        guard self.profile != profile else { return }
        self.profile = profile
        soundBuffers.removeAll()
    }

    func applyEventVolumes(_ map: [String: Float]) {
        eventVolumes = map.mapValues { max(0, min(1, $0)) }
    }

    /// Apply the per-event assignment map (Default / Off / a library file) and
    /// rebuild the buffers.
    func applyAssignments(_ map: [String: String]) {
        assignments = map
        soundBuffers.removeAll()
    }

    /// Play an event's currently-assigned sound regardless of enabled/off state
    /// (used by the ▶ preview buttons in Settings).
    func preview(_ event: SoundEvent) {
        if let buffer = buffer(for: event) {
            playBuffer(buffer, gain: eventVolume(for: event))
        }
    }

    /// Preview the three semantic cues without changing event assignments.
    func previewProfile(_ profile: SoundProfile) {
        let synthesizer = SoundSynthesizer(profile: profile)
        for event in [SoundEvent.completion, .approvalNeeded, .error] {
            if let buffer = synthesizer.generateSound(for: event) {
                playBuffer(buffer, gain: eventVolume(for: event))
            }
        }
    }

    /// Play a specific library file (preview a "My Sounds" entry).
    func previewFile(_ filename: String) {
        let url = customSoundsDirectory().appendingPathComponent(filename)
        if let buffer = loadAudioFile(url) { playBuffer(buffer, gain: 1) }
    }

    // MARK: - Audio Engine

    func shutdown() {
        stopAudioEngine()
    }

    private func ensureAudioEngineRunning() -> (player: AVAudioPlayerNode, generation: Int)? {
        idleTeardownTask?.cancel()
        idleTeardownTask = nil

        if audioEngine != nil, audioEngine?.isRunning != true {
            lifecycle.stop()
            teardownAudioGraph()
        }

        let request = lifecycle.requestPlayback()
        if !request.shouldStartEngine, let playerNode {
            return (playerNode, request.generation)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            player.volume = volume
            audioEngine = engine
            playerNode = player
            return (player, request.generation)
        } catch {
            engine.stop()
            engine.detach(player)
            lifecycle.startFailed(generation: request.generation)
            print("[CaesuraIsland] Audio engine failed to start: \(error)")
            return nil
        }
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer, gain: Float) {
        guard gain > 0 else { return }
        guard let playback = ensureAudioEngineRunning() else { return }
        let player = playback.player
        let generation = playback.generation
        let playbackBuffer = scaledBuffer(buffer, gain: gain)

        player.scheduleBuffer(playbackBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.playbackFinished(generation: generation)
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func playbackFinished(generation: Int) {
        guard lifecycle.playbackFinished(generation: generation) else { return }

        idleTeardownTask?.cancel()
        idleTeardownTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTeardownDelay)
            guard !Task.isCancelled else { return }
            self?.finishIdleTeardown(generation: generation)
        }
    }

    private func finishIdleTeardown(generation: Int) {
        guard lifecycle.idleDeadlineReached(generation: generation) else { return }
        idleTeardownTask = nil
        teardownAudioGraph()
    }

    private func stopAudioEngine() {
        idleTeardownTask?.cancel()
        idleTeardownTask = nil
        lifecycle.stop()
        teardownAudioGraph()
    }

    private func teardownAudioGraph() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine?.reset()

        if let engine = audioEngine, let player = playerNode, engine.attachedNodes.contains(player) {
            engine.detach(player)
        }

        playerNode = nil
        audioEngine = nil
    }

    // MARK: - Sound Loading

    private func buffer(for event: SoundEvent) -> AVAudioPCMBuffer? {
        if let cached = soundBuffers[event] { return cached }

        let synthesizer = SoundSynthesizer(profile: profile)
        let dir = customSoundsDirectory()
        let supportedExts = ["wav", "mp3", "m4a", "aiff", "caf"]

        let choice = assignments[event.rawValue] ?? "default"
        if choice != "default", choice != "off" {
            let url = dir.appendingPathComponent(choice)
            if FileManager.default.fileExists(atPath: url.path), let buffer = loadAudioFile(url) {
                soundBuffers[event] = buffer
                return buffer
            }
        }

        for ext in supportedExts {
            let url = dir.appendingPathComponent("\(event.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path), let buffer = loadAudioFile(url) {
                soundBuffers[event] = buffer
                return buffer
            }
        }

        let generated = synthesizer.generateSound(for: event)
        soundBuffers[event] = generated
        return generated
    }

    /// Reload all sounds — call after the user drops new files in the sound-packs dir.
    func reloadSounds() {
        soundBuffers.removeAll()
    }

    private func eventVolume(for event: SoundEvent) -> Float {
        max(0, min(1, eventVolumes[event.rawValue] ?? 1))
    }

    private func scaledBuffer(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer {
        guard gain < 0.999,
              let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
              ),
              let sourceChannels = buffer.floatChannelData,
              let destinationChannels = copy.floatChannelData else { return buffer }

        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                destinationChannels[channel][frame] = sourceChannels[channel][frame] * gain
            }
        }
        return copy
    }

    private func customSoundsDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".caesura-island/sound-packs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadAudioFile(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        do { try file.read(into: srcBuffer) } catch {
            print("[CaesuraIsland] Failed to read audio file \(url.lastPathComponent): \(error)")
            return nil
        }

        // Convert to the engine's standard format (mono 44.1kHz) so it plays
        // through our existing AVAudioPlayerNode connection.
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else {
            return srcBuffer
        }
        if srcBuffer.format.isEqual(targetFormat) { return srcBuffer }

        guard let converter = AVAudioConverter(from: srcBuffer.format, to: targetFormat) else {
            return srcBuffer
        }
        let ratio = targetFormat.sampleRate / srcBuffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return srcBuffer
        }
        let inputState = AudioConverterInputState(buffer: srcBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, status in inputState.next(status: status) }
        var error: NSError?
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            print("[CaesuraIsland] Audio convert failed: \(error.localizedDescription)")
            return srcBuffer
        }
        return outBuffer
    }
}
