import Foundation

enum Log {
    private static let queue = DispatchQueue(
        label: "com.caesura-island.logger",
        qos: .utility
    )
    private static let writer = FileLogWriter(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".caesura-island/debug.log"),
        maxBytes: 2 * 1_024 * 1_024
    )

    static func info(_ message: String) {
        enqueue(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        enqueue(level: "ERROR", message: message)
    }

    static func shutdown() {
        queue.sync {
            writer.close()
        }
    }

    private static func enqueue(level: String, message: String) {
        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        queue.async {
            writer.write(line)
        }
    }
}

/// Queue-confined file writer with one reusable handle and a single rotated
/// backup. `Log` owns the production queue; the concrete writer is exposed to
/// tests so rotation can be verified without touching the user's log.
final class FileLogWriter {
    let url: URL
    let maxBytes: UInt64

    private var handle: FileHandle?
    private var currentBytes: UInt64 = 0

    init(url: URL, maxBytes: UInt64) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        prepareHandle(forAdditionalBytes: UInt64(data.count))
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentBytes += UInt64(data.count)
        } catch {
            close()
        }
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        currentBytes = 0
    }

    private func prepareHandle(forAdditionalBytes bytes: UInt64) {
        if handle == nil { openHandle() }
        if currentBytes > 0, currentBytes + bytes > maxBytes {
            rotate()
            openHandle()
        }
    }

    private func openHandle() {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        do {
            currentBytes = try opened.seekToEnd()
            handle = opened
        } catch {
            try? opened.close()
        }
    }

    private func rotate() {
        close()
        let manager = FileManager.default
        let backup = url.appendingPathExtension("1")
        try? manager.removeItem(at: backup)
        try? manager.moveItem(at: url, to: backup)
    }
}
