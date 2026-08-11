import Foundation

enum Log {
    private static let sink = AsyncLogSink(
        writer: FileLogWriter(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".caesura-island/debug.log"),
            maxBytes: 2 * 1_024 * 1_024
        )
    )

    static func info(_ message: String) {
        enqueue(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        enqueue(level: "ERROR", message: message)
    }

    static func shutdown() {
        sink.shutdown()
    }

    private static func enqueue(level: String, message: String) {
        sink.enqueue(date: Date(), level: level, message: message)
    }
}

final class AsyncLogSink {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let writer: FileLogWriter
    private let makeFormatter: () -> LogLineFormatter
    private var formatter: LogLineFormatter?

    init(
        writer: FileLogWriter,
        makeFormatter: @escaping () -> LogLineFormatter = { LogLineFormatter() },
        label: String = "com.caesura-island.logger"
    ) {
        self.writer = writer
        self.makeFormatter = makeFormatter
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.queue.setSpecific(key: queueKey, value: ())
    }

    func enqueue(date: Date, level: String, message: String) {
        queue.async { [self] in
            if formatter == nil {
                formatter = makeFormatter()
            }
            guard let formatter else { return }
            writer.write(formatter.line(date: date, level: level, message: message))
        }
    }

    func shutdown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            writer.close()
        } else {
            queue.sync { writer.close() }
        }
    }
}

final class LogLineFormatter {
    private let dateFormatter: DateFormatter

    init(locale: Locale? = nil, timeZone: TimeZone? = nil) {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        if let locale { formatter.locale = locale }
        if let timeZone { formatter.timeZone = timeZone }
        self.dateFormatter = formatter
    }

    func line(date: Date, level: String, message: String) -> String {
        "[\(dateFormatter.string(from: date))] [\(level)] \(message)\n"
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
