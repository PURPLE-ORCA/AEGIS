import XCTest
@testable import Aegis

final class HermesHandoffConfigurationTests: XCTestCase {
    func testPreferredWorkingDirectoryUsesPurpleVaultWhenPresent() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        let result = HermesHandoffConfiguration.preferredWorkingDirectory(
            homeDirectory: home,
            fileExists: { $0.path == "/Users/tester/Documents/PURPLE-VAULT" }
        )

        XCTAssertEqual(result.path, "/Users/tester/Documents/PURPLE-VAULT")
    }

    func testPreferredWorkingDirectoryFallsBackToHome() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        let result = HermesHandoffConfiguration.preferredWorkingDirectory(
            homeDirectory: home,
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, home)
    }

    func testInstallationResolverFindsStandardHermesVenv() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let expected = "/Users/tester/.hermes/hermes-agent/venv/bin/python"

        let installation = HermesHandoffConfiguration.installation(
            homeDirectory: home,
            fileExists: { $0.path == expected }
        )

        XCTAssertEqual(installation?.pythonExecutable.path, expected)
        XCTAssertEqual(installation?.rootDirectory.path, "/Users/tester/.hermes/hermes-agent")
    }

    func testSubmissionPlanKeepsPrivatePromptOutOfArguments() {
        let installation = HermesInstallation(
            rootDirectory: URL(fileURLWithPath: "/opt/hermes"),
            pythonExecutable: URL(fileURLWithPath: "/opt/hermes/venv/bin/python")
        )
        let secretPrompt = "private spoken request"

        let plan = HermesHandoffProcessPlanner.submissionPlan(
            installation: installation,
            workingDirectory: URL(fileURLWithPath: "/work/vault"),
            target: .latestInDirectory
        )

        XCTAssertFalse(plan.arguments.contains(where: { $0.contains(secretPrompt) }))
        XCTAssertEqual(plan.arguments.suffix(2), ["/work/vault", "latest"])
        XCTAssertTrue(HermesHandoffProcessPlanner.submissionScript.contains("sys.stdin.read"))
    }

    func testNewSessionPlanDoesNotResumeLatest() {
        let installation = HermesInstallation(
            rootDirectory: URL(fileURLWithPath: "/opt/hermes"),
            pythonExecutable: URL(fileURLWithPath: "/opt/hermes/venv/bin/python")
        )

        let plan = HermesHandoffProcessPlanner.submissionPlan(
            installation: installation,
            workingDirectory: URL(fileURLWithPath: "/work/vault"),
            target: .newSession
        )

        XCTAssertEqual(plan.arguments.last, "new")
    }
}
