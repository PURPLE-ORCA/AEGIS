import Foundation

enum HermesHandoffTarget: String, CaseIterable, Identifiable {
    case newSession
    case latestInDirectory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newSession:
            return "New session"
        case .latestInDirectory:
            return "Latest in folder"
        }
    }

    var capsuleLabel: String {
        switch self {
        case .newSession:
            return "New"
        case .latestInDirectory:
            return "Latest"
        }
    }
}

struct HermesInstallation: Equatable {
    let rootDirectory: URL
    let pythonExecutable: URL
}

enum HermesHandoffConfiguration {
    static let defaultShortcutLabel = "Control–Option–Space"

    static func preferredWorkingDirectory(
        homeDirectory: URL,
        fileExists: (URL) -> Bool
    ) -> URL {
        let vault = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("PURPLE-VAULT", isDirectory: true)
        return fileExists(vault) ? vault : homeDirectory
    }

    static func installation(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> HermesInstallation? {
        let roots = [
            homeDirectory.appendingPathComponent(".hermes/hermes-agent", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/share/hermes/hermes-agent", isDirectory: true),
        ]

        for root in roots {
            let candidates = [
                root.appendingPathComponent("venv/bin/python"),
                root.appendingPathComponent(".venv/bin/python"),
            ]
            if let python = candidates.first(where: fileExists) {
                return HermesInstallation(rootDirectory: root, pythonExecutable: python)
            }
        }
        return nil
    }

    static func validatedWorkingDirectory(_ rawPath: String) throws -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HermesHandoffError.invalidWorkingDirectory
        }
        return url
    }
}

enum HermesHandoffError: LocalizedError {
    case installationMissing
    case invalidWorkingDirectory
    case microphoneDenied
    case microphoneUnavailable
    case recordingFailed
    case noSpeech
    case transcriptionFailed(String?)
    case submissionFailed

    var errorDescription: String? {
        switch self {
        case .installationMissing:
            return "Hermes is not ready on this Mac."
        case .invalidWorkingDirectory:
            return "Choose an available working folder in Settings."
        case .microphoneDenied:
            return "Allow microphone access in System Settings."
        case .microphoneUnavailable:
            return "No microphone is available."
        case .recordingFailed:
            return "The recording could not be completed."
        case .noSpeech:
            return "No speech was detected."
        case .transcriptionFailed(let detail):
            return detail?.isEmpty == false ? detail : "Hermes could not transcribe the recording."
        case .submissionFailed:
            return "The handoff could not be sent to Hermes."
        }
    }
}

struct HermesHandoffProcessPlan: Equatable {
    let executable: URL
    let arguments: [String]
    let currentDirectory: URL
}

enum HermesHandoffProcessPlanner {
    static let transcriptionScript = """
import json
import sys
from tools.voice_mode import transcribe_recording

result = transcribe_recording(sys.argv[1])
print(json.dumps({
    "success": bool(result.get("success")),
    "transcript": (result.get("transcript") or "").strip(),
    "error": str(result.get("error") or "")
}))
"""

    // The utterance is read from stdin so private prompt text never appears in
    // the child process arguments or a shell command line.
    static let submissionScript = """
import sys
from hermes_cli.main import main

prompt = sys.stdin.read().strip()
if not prompt:
    raise SystemExit(64)

args = ["hermes", "chat", "--query", prompt, "--quiet", "--in", sys.argv[1], "--source", "desktop"]
if sys.argv[2] == "latest":
    args.extend(["--resume", "latest"])
sys.argv = args
raise SystemExit(main())
"""

    static func transcriptionPlan(
        installation: HermesInstallation,
        audioFile: URL
    ) -> HermesHandoffProcessPlan {
        HermesHandoffProcessPlan(
            executable: installation.pythonExecutable,
            arguments: ["-c", transcriptionScript, audioFile.path],
            currentDirectory: installation.rootDirectory
        )
    }

    static func submissionPlan(
        installation: HermesInstallation,
        workingDirectory: URL,
        target: HermesHandoffTarget
    ) -> HermesHandoffProcessPlan {
        HermesHandoffProcessPlan(
            executable: installation.pythonExecutable,
            arguments: [
                "-c",
                submissionScript,
                workingDirectory.path,
                target == .latestInDirectory ? "latest" : "new",
            ],
            currentDirectory: installation.rootDirectory
        )
    }
}
