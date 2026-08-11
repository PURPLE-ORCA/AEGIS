import Foundation
import XCTest
@testable import CaesuraIsland

final class FileEventMonitorTests: XCTestCase {
    func testRecursiveMonitorReportsNewTranscript() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("new-session.jsonl")
        let received = expectation(description: "new transcript event")
        received.assertForOverFulfill = false
        let monitor = makeMonitor(root: root) { paths in
            if paths.contains(transcript.path) { received.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }

        try Data("{}\n".utf8).write(to: transcript)

        wait(for: [received], timeout: 3)
    }

    func testRecursiveMonitorReportsTranscriptAppend() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("active-session.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let received = expectation(description: "transcript append event")
        received.assertForOverFulfill = false
        let monitor = makeMonitor(root: root) { paths in
            if paths.contains(transcript.path) { received.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        wait(for: [received], timeout: 3)
    }

    func testMonitorRecoversWhenRootAppearsAfterStart() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("sessions", isDirectory: true)
        let received = expectation(description: "late root event")
        received.assertForOverFulfill = false
        let monitor = makeMonitor(root: root) { paths in
            if paths.contains(where: { $0 == root.path || $0.hasPrefix(root.path + "/") }) {
                received.fulfill()
            }
        }
        monitor.start()
        defer { monitor.stop() }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("late-session.jsonl"))

        wait(for: [received], timeout: 3)
    }

    func testEarlyFilterRejectsUnrelatedFilesAndDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = makeHermesMonitor(root: root) { _ in }
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let directoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)

        let paths = monitor.filteredPaths(for: [
            FileSystemEvent(path: root.appendingPathComponent("history.json").path, flags: fileFlag),
            FileSystemEvent(path: root.appendingPathComponent("cache", isDirectory: true).path, flags: directoryFlag),
        ])

        XCTAssertTrue(paths.isEmpty)
    }

    func testEarlyFilterAcceptsOnlyHermesDatabaseFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = makeHermesMonitor(root: root) { _ in }
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let expected = ["state.db", "state.db-wal", "state.db-shm"].map {
            root.appendingPathComponent($0).path
        }

        let paths = monitor.filteredPaths(for: expected.map {
            FileSystemEvent(path: $0, flags: fileFlag)
        })

        XCTAssertEqual(paths, expected.sorted())
    }

    func testRecoveryFlagsBypassEarlyFilter() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = makeHermesMonitor(root: root) { _ in }
        let recoveryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

        let paths = monitor.filteredPaths(for: [
            FileSystemEvent(path: root.appendingPathComponent("unrelated").path, flags: recoveryFlag),
        ])

        XCTAssertEqual(paths, [root.path])
    }

    private func makeMonitor(root: URL, onChange: @escaping ([String]) -> Void) -> FileEventMonitor {
        FileEventMonitor(
            root: root,
            label: "dev.caesura.island.tests.\(UUID().uuidString)",
            recursive: true,
            includeFile: { $0.pathExtension == "jsonl" },
            onChange: onChange
        )
    }

    private func makeHermesMonitor(root: URL, onChange: @escaping ([String]) -> Void) -> FileEventMonitor {
        let databasePaths = Set(["state.db", "state.db-wal", "state.db-shm"].map {
            root.appendingPathComponent($0).path
        })
        return FileEventMonitor(
            root: root,
            label: "dev.caesura.island.tests.hermes.\(UUID().uuidString)",
            includeEvent: { path, _ in databasePaths.contains(path) },
            includeFile: { _ in true },
            onChange: onChange
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caesura-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
