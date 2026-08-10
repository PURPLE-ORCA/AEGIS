import CoreServices
import Foundation

final class FileEventMonitor {
    private let root: URL
    private let queue: DispatchQueue
    private let recursive: Bool
    private let includeFile: (URL) -> Bool
    private let onChange: ([String]) -> Void
    private let queueKey = DispatchSpecificKey<Void>()

    private var stream: FSEventStreamRef?
    private var watchedRoot: URL?
    private var retargetPending = false

    init(
        root: URL,
        label: String,
        recursive: Bool = false,
        includeFile: @escaping (URL) -> Bool,
        onChange: @escaping ([String]) -> Void
    ) {
        self.root = root.standardizedFileURL
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.recursive = recursive
        self.includeFile = includeFile
        self.onChange = onChange
        self.queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        syncOnQueue {
            guard stream == nil else { return }
            startStream()
        }
    }

    func stop() {
        syncOnQueue { stopStream() }
    }

    private func startStream() {
        let target = nearestExistingAncestor(of: root)
        watchedRoot = target

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [target.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedRoot = nil
        retargetPending = false
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, eventCount, eventPaths, eventFlags, _ in
        guard let clientInfo else { return }
        let monitor = Unmanaged<FileEventMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        monitor.handle(paths: paths, flags: eventFlags, count: eventCount)
    }

    private func handle(
        paths: [String],
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        let rootPath = root.path
        var changed = Set<String>()

        for index in 0..<min(count, paths.count) {
            let path = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
            let eventFlags = flags[index]
            let mustRescan = eventFlags & FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs |
                    kFSEventStreamEventFlagUserDropped |
                    kFSEventStreamEventFlagKernelDropped |
                    kFSEventStreamEventFlagRootChanged
            ) != 0

            if mustRescan {
                changed.insert(rootPath)
                continue
            }
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            if !recursive, path != rootPath {
                let relative = String(path.dropFirst(rootPath.count + 1))
                guard !relative.contains("/") else { continue }
            }

            let url = URL(fileURLWithPath: path)
            let isDirectory = eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if path == rootPath || isDirectory || includeFile(url) {
                changed.insert(path)
            }
        }

        if !changed.isEmpty {
            onChange(changed.sorted())
        }
        retargetToRootWhenAvailable()
    }

    private func retargetToRootWhenAvailable() {
        guard watchedRoot?.path != root.path,
              FileManager.default.fileExists(atPath: root.path),
              !retargetPending else { return }
        retargetPending = true
        queue.async { [weak self] in
            guard let self else { return }
            self.stopStream()
            self.startStream()
            self.retargetPending = false
        }
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }

    private func syncOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    deinit {
        stop()
    }
}
