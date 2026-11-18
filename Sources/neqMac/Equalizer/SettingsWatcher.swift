import Foundation

// Watch both the document and its directory: editors use in-place writes and atomic replacement.
final class SettingsWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let changed: (Bool) -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var edited = false

    init(url: URL, queue: DispatchQueue, changed: @escaping (Bool) -> Void) {
        self.url = url
        self.queue = queue
        self.changed = changed
    }

    func arm() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        var directory = url.deletingLastPathComponent()
        while !watch(directory, file: false) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        _ = watch(url, file: true)
    }

    private func watch(_ path: URL, file: Bool) -> Bool {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            edited = edited || file
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let fileEvent = edited
                edited = false
                arm()
                changed(fileEvent)
            }
            pending = work
            queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
        }
        sources.append(source)
        source.resume()
        return true
    }

    deinit {
        pending?.cancel()
        sources.forEach { $0.cancel() }
    }
}
