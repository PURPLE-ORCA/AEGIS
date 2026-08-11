import CoreServices
import Foundation

struct FileSystemEvent {
    let path: String
    let flags: FSEventStreamEventFlags
}

final class FileEventMonitor {
    private let root: URL
    private let queue: DispatchQueue
    private let recursive: Bool
    private let includeEvent: ((String, FSEventStreamEventFlags) -> Bool)?
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
        includeEvent: ((String, FSEventStreamEventFlags) -> Bool)? = nil,
        includeFile: @escaping (URL) -> Bool,
        onChange: @escaping ([String]) -> Void
    ) {
        self.root = root.standardizedFileURL
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.recursive = recursive
        self.includeEvent = includeEvent
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
        let events = (0..<min(count, paths.count)).map {
            FileSystemEvent(path: paths[$0], flags: flags[$0])
        }
        let changed = filteredPaths(for: events)

        if !changed.isEmpty {
            onChange(changed)
        }
        retargetToRootWhenAvailable()
    }

    func filteredPaths(for events: [FileSystemEvent]) -> [String] {
        let rootPath = root.path
        var changed = Set<String>()

        for event in events {
            let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
            let eventFlags = event.flags
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
            if let includeEvent, !includeEvent(path, eventFlags) { continue }

            if path == rootPath {
                changed.insert(path)
                continue
            }

            let url = URL(fileURLWithPath: path)
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                changed.insert(path)
                continue
            }
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 {
                if includeFile(url) { changed.insert(path) }
                continue
            }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory || includeFile(url) {
                changed.insert(path)
            }
        }

        return changed.sorted()
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
