import Foundation
import AVFoundation
import Darwin

private struct HermesTranscriptionPayload: Decodable {
    let success: Bool
    let transcript: String
    let error: String
    let importMilliseconds: Double?
    let transcriptionMilliseconds: Double?
}

actor HermesHandoffRunner {
    private var transcriptions: [UUID: Process] = [:]
    private var activeSubmissions: [UUID: Process] = [:]

    func transcribe(audioFile: URL, installation: HermesInstallation) async throws -> String {
        let recording = try AVAudioFile(forReading: audioFile)
        guard recording.length > 0 else {
            throw HermesHandoffError.recordingEmpty
        }
        let plan = HermesHandoffProcessPlanner.transcriptionPlan(
            installation: installation,
            audioFile: audioFile
        )
        let started = ProcessInfo.processInfo.systemUptime
        let output = try await runToCompletion(plan)
        let totalMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        guard let payload = transcriptionPayload(from: output),
              payload.success else {
            let detail = transcriptionPayload(from: output)?.error
            throw HermesHandoffError.transcriptionFailed(detail)
        }
        if let imports = payload.importMilliseconds, let transcription = payload.transcriptionMilliseconds {
            Log.info(String(format: "Dictation timing total_ms=%.1f import_ms=%.1f transcription_ms=%.1f process_and_io_ms=%.1f",
                totalMilliseconds, imports, transcription, max(0, totalMilliseconds - imports - transcription)))
        }
        let transcript = payload.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw HermesHandoffError.noSpeech }
        return transcript
    }

    func submit(
        transcript: String,
        installation: HermesInstallation,
        workingDirectory: URL,
        target: HermesHandoffTarget
    ) async throws {
        let plan = HermesHandoffProcessPlanner.submissionPlan(
            installation: installation,
            workingDirectory: workingDirectory,
            target: target
        )
        let process = Process()
        let input = Pipe()
        let identifier = UUID()

        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.currentDirectory
        process.environment = Self.hermesEnvironment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.submissionFinished(identifier: identifier, status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            activeSubmissions[identifier] = process
            if let data = transcript.data(using: .utf8) {
                try input.fileHandleForWriting.write(contentsOf: data)
            }
            try input.fileHandleForWriting.close()
            try await Task.sleep(for: .milliseconds(350))
            if !process.isRunning, process.terminationStatus != 0 {
                activeSubmissions[identifier] = nil
                throw HermesHandoffError.submissionFailed
            }
            Log.info("Hermes voice handoff started target=\(target.rawValue) cwd=\(workingDirectory.path)")
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw HermesHandoffError.submissionFailed
        }
    }

    func stop() {
        for identifier in transcriptions.keys { cancelTranscription(identifier) }
        for process in activeSubmissions.values where process.isRunning {
            process.terminate()
        }
        activeSubmissions.removeAll()
    }

    private func submissionFinished(identifier: UUID, status: Int32) {
        activeSubmissions[identifier] = nil
        if status == 0 {
            Log.info("Hermes voice handoff completed")
        } else {
            Log.error("Hermes voice handoff exited status=\(status)")
        }
    }

    private func transcriptionPayload(from data: Data) -> HermesTranscriptionPayload? {
        if let direct = try? JSONDecoder().decode(HermesTranscriptionPayload.self, from: data) {
            return direct
        }
        for line in data.split(separator: 0x0A).reversed() {
            if let payload = try? JSONDecoder().decode(HermesTranscriptionPayload.self, from: Data(line)) {
                return payload
            }
        }
        return nil
    }

    private func cancelTranscription(_ identifier: UUID) {
        guard let process = transcriptions[identifier], process.isRunning else { return }
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func runToCompletion(_ plan: HermesHandoffProcessPlan) async throws -> Data {
        try Task.checkCancellation()
        let identifier = UUID()
        let process = Process()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-transcription-\(identifier).log")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: url)
        defer {
            transcriptions[identifier] = nil
            try? output.close()
            try? FileManager.default.removeItem(at: url)
        }
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.currentDirectory
        process.environment = Self.hermesEnvironment
        process.standardOutput = output
        process.standardError = output
        transcriptions[identifier] = process
        let deadline = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            cancelTranscription(identifier)
        }
        defer { deadline.cancel() }
        // A file avoids blocking the child on a full stdout pipe before termination.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HermesHandoffError.transcriptionFailed(nil))
                    }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: HermesHandoffError.installationMissing) }
            }
        } onCancel: {
            Task { await self.cancelTranscription(identifier) }
        }
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }

    private static var hermesEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Match the official Hermes launcher. Python path injection can make
        // the managed venv import modules from an unrelated active project.
        environment["PYTHONPATH"] = nil
        environment["PYTHONHOME"] = nil
        return environment
    }
}
