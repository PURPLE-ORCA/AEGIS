import Foundation

private struct HermesTranscriptionPayload: Decodable {
    let success: Bool
    let transcript: String
    let error: String
}

actor HermesHandoffRunner {
    private var activeSubmissions: [UUID: Process] = [:]

    func transcribe(audioFile: URL, installation: HermesInstallation) async throws -> String {
        let plan = HermesHandoffProcessPlanner.transcriptionPlan(
            installation: installation,
            audioFile: audioFile
        )
        let output = try await runToCompletion(plan)
        guard let payload = transcriptionPayload(from: output),
              payload.success else {
            let detail = transcriptionPayload(from: output)?.error
            throw HermesHandoffError.transcriptionFailed(detail)
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

    private func runToCompletion(_ plan: HermesHandoffProcessPlan) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = plan.executable
            process.arguments = plan.arguments
            process.currentDirectoryURL = plan.currentDirectory
            process.environment = Self.hermesEnvironment
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HermesHandoffError.transcriptionFailed(nil))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: HermesHandoffError.installationMissing)
            }
        }
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
