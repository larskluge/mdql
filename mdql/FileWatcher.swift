import Foundation

class FileWatcher {
    private let url: URL
    private let callback: () -> Void
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var coalesceWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.mdql.filewatcher", qos: .utility)
    private(set) var isWatching = false

    init(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback
    }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        startMonitoring()
    }

    func stop() {
        isWatching = false
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    deinit {
        stop()
    }

    private func startMonitoring() {
        guard isWatching else { return }

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                // File was atomically replaced (vim, sed -i, etc.)
                // Close old descriptor, re-open at same path
                self.restartMonitoring()
            }
            self.scheduleCallback()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        self.source = source
        source.resume()
    }

    private func restartMonitoring() {
        source?.cancel()
        source = nil
        // Small delay to let the new file settle
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startMonitoring()
        }
    }

    private func scheduleCallback() {
        coalesceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isWatching else { return }
            DispatchQueue.main.async {
                self.callback()
            }
        }
        coalesceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}
