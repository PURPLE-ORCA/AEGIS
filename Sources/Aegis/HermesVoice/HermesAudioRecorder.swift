import AVFoundation
import Foundation
import AudioToolbox
import CoreAudio

final class HermesAudioRecorder {
    private lazy var engine = AVAudioEngine()
    private var tapInstalled = false
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var configurationObserver: NSObjectProtocol?

    var isRecording: Bool { engine.isRunning }

    func start(deviceID: AudioDeviceID? = nil, levelHandler: @escaping (Double) -> Void,
               failureHandler: (() -> Void)? = nil) throws -> URL {
        guard !engine.isRunning else {
            throw HermesHandoffError.recordingFailed
        }

        engine = AVAudioEngine()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-hermes-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("utterance-\(UUID().uuidString).wav")
        let input = engine.inputNode
        if var deviceID {
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw HermesHandoffError.microphoneUnavailable
            }
        }
        // Device selection updates the hardware format before the engine's cached output format.
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw HermesHandoffError.microphoneUnavailable
        }

        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        self.audioFile = file
        self.outputURL = url

        var levelThrottle = VoiceLevelThrottle()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                Log.error("Voice recording write failed: \(error.localizedDescription)")
                failureHandler?()
                return
            }
            if levelThrottle.shouldPublish(frames: Int(buffer.frameLength), sampleRate: format.sampleRate) {
                levelHandler(Self.normalizedLevel(from: buffer))
            }
        }

        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak engine = engine] _ in
                guard let engine else { return }
                let currentFormat = engine.inputNode.inputFormat(forBus: 0)
                guard Self.configurationRequiresStop(isRunning: engine.isRunning,
                    originalFormat: format, currentFormat: currentFormat) else { return }
                Log.error("Voice recording interrupted: running=\(engine.isRunning) input=\(currentFormat)")
                failureHandler?()
            }
            return url
        } catch {
            Log.error("Voice recording start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            tapInstalled = false
            audioFile = nil
            cleanupFile()
            throw HermesHandoffError.recordingFailed
        }
    }

    @discardableResult
    func stop() -> URL? {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        if let audioFile {
            Log.info("Voice recording captured frames=\(audioFile.length) sampleRate=\(audioFile.processingFormat.sampleRate)")
        }
        audioFile = nil
        return outputURL
    }

    func cancel() {
        _ = stop()
        audioFile = nil
        cleanupFile()
    }

    func removeRecording() {
        cleanupFile()
    }

    private func cleanupFile() {
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    static func configurationRequiresStop(isRunning: Bool, originalFormat: AVAudioFormat,
                                          currentFormat: AVAudioFormat) -> Bool {
        !isRunning || !originalFormat.isEqual(currentFormat)
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Double(max(0, min(1, (decibels + 55) / 55)))
    }
}

struct VoiceLevelThrottle {
    private var accumulatedFrames = 0

    mutating func shouldPublish(frames: Int, sampleRate: Double) -> Bool {
        accumulatedFrames += frames
        guard Double(accumulatedFrames) >= sampleRate / 30 else { return false }
        accumulatedFrames = 0
        return true
    }
}
