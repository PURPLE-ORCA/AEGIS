import CoreServices
import Foundation

final class FileEventMonitor {
    private let root: URL
    private let queue: DispatchQueue
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(root: URL, label: String, onChange: @escaping ([String]) -> Void) {
        self.root = root
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: root.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileEventMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            if count > 0 { monitor.onChange(paths) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.08,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
