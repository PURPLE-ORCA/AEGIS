import Foundation
import XCTest
@testable import CaesuraIsland

final class ProviderInstallerHermesTests: XCTestCase {
    func testInstallsHooksIntoRootAndNamedProfileConfigsWithoutRemovingForeignHooks() throws {
        let hermesRoot = try makeHermesRoot()
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        let profileRoot = hermesRoot.appendingPathComponent("profiles/orcanee", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let rootConfig = hermesRoot.appendingPathComponent("config.yaml")
        let profileConfig = profileRoot.appendingPathComponent("config.yaml")
        let original = """
        model: test-model
        hooks:
          pre_tool_call:
            - command: '/usr/local/bin/foreign-hook'
              timeout: 12
        """
        try original.write(to: rootConfig, atomically: true, encoding: .utf8)
        try original.write(to: profileConfig, atomically: true, encoding: .utf8)

        let descriptor = try XCTUnwrap(ProviderInstaller.descriptors.first { $0.source == "hermes" })
        let command = "/tmp/caesura-island-hermes-bridge"
        XCTAssertTrue(ProviderInstaller.installHermesYAML(
            descriptor,
            hermesRoot: hermesRoot,
            launcherCommand: command
        ))

        for config in [rootConfig, profileConfig] {
            let installed = try String(contentsOf: config, encoding: .utf8)
            XCTAssertTrue(installed.contains("/usr/local/bin/foreign-hook"))
            XCTAssertTrue(installed.contains(command))
            XCTAssertTrue(FileManager.default.fileExists(atPath: config.appendingPathExtension("bak").path))
        }
    }

    func testProfileOnlyInstallationIsIdempotent() throws {
        let hermesRoot = try makeHermesRoot()
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        let profileRoot = hermesRoot.appendingPathComponent("profiles/isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let profileConfig = profileRoot.appendingPathComponent("config.yaml")
        try "model: test-model\n".write(to: profileConfig, atomically: true, encoding: .utf8)

        let descriptor = try XCTUnwrap(ProviderInstaller.descriptors.first { $0.source == "hermes" })
        let command = "/tmp/caesura-island-hermes-bridge"
        XCTAssertTrue(ProviderInstaller.installHermesYAML(
            descriptor,
            hermesRoot: hermesRoot,
            launcherCommand: command
        ))
        let firstInstall = try Data(contentsOf: profileConfig)
        XCTAssertTrue(ProviderInstaller.installHermesYAML(
            descriptor,
            hermesRoot: hermesRoot,
            launcherCommand: command
        ))

        XCTAssertEqual(try Data(contentsOf: profileConfig), firstInstall)
    }

    private func makeHermesRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caesura-hermes-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
