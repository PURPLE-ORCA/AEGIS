import AVFoundation
import Foundation

final class HermesAudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var levelHandler: ((Double) -> Void)?

    var isRecording: Bool { engine.isRunning }

    func start(levelHandler: @escaping (Double) -> Void) throws -> URL {
        guard !engine.isRunning else {
            throw HermesHandoffError.recordingFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aegis-hermes-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("utterance-\(UUID().uuidString).caf")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw HermesHandoffError.microphoneUnavailable
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.audioFile = file
        self.outputURL = url
        self.levelHandler = levelHandler

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                return
            }
            self.levelHandler?(Self.normalizedLevel(from: buffer))
        }

        do {
            engine.prepare()
            try engine.start()
            return url
        } catch {
            input.removeTap(onBus: 0)
            cleanupFile()
            throw HermesHandoffError.recordingFailed
        }
    }

    @discardableResult
    func stop() -> URL? {
        guard engine.isRunning else { return outputURL }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        levelHandler = nil
        return outputURL
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioFile = nil
        levelHandler = nil
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
