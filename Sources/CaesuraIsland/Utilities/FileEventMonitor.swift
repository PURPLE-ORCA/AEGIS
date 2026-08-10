import Darwin
import Foundation

final class FileEventMonitor {
    private let root: URL
    private let queue: DispatchQueue
    private let recursive: Bool
    private let includeFile: (URL) -> Bool
    private let onChange: ([String]) -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    init(
        root: URL,
        label: String,
        recursive: Bool = false,
        includeFile: @escaping (URL) -> Bool,
        onChange: @escaping ([String]) -> Void
    ) {
        self.root = root
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.recursive = recursive
        self.includeFile = includeFile
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.refreshSources() }
    }

    func stop() {
        queue.sync {
            for source in sources.values { source.cancel() }
            sources.removeAll()
        }
    }

    private func refreshSources() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var wanted = Set([root.path])

        if recursive,
           let enumerator = FileManager.default.enumerator(
               at: root,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory || includeFile(url) { wanted.insert(url.path) }
            }
        } else if let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            for url in children where includeFile(url) { wanted.insert(url.path) }
        }

        for path in sources.keys where !wanted.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in wanted where sources[path] == nil {
            addSource(path: path)
        }
    }

    private func addSource(path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.onChange([path])
            if source.data.contains(.write) || source.data.contains(.rename) || source.data.contains(.delete) {
                self.refreshSources()
            }
        }
        source.setCancelHandler { close(descriptor) }
        sources[path] = source
        source.resume()
    }

    deinit {
        stop()
    }
}
