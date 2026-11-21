import Foundation

/// Watches one file and calls back after it changes, once per burst of writes,
/// recovering when an editor replaces the file by renaming another over it.
///
/// Main-queue only: `start`, `stop`, the source's events and the callback all
/// run there, so the source, the pending callback and `isWatching` are only
/// ever touched from one thread, and no callback comes after `stop` returns.
final class FileWatcher {
    private let url: URL
    private let callback: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var coalesceWorkItem: DispatchWorkItem?
    private(set) var isWatching = false

    init(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isWatching else { return }
        isWatching = true
        startMonitoring()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        isWatching = false
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        source?.cancel() // its cancel handler closes the descriptor
        source = nil
    }

    deinit {
        // Nothing else holds the watcher by now, so nothing else can touch its state.
        coalesceWorkItem?.cancel()
        source?.cancel()
    }

    private func startMonitoring() {
        guard isWatching, source == nil else { return }

        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
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

        source.setCancelHandler {
            close(fileDescriptor)
        }

        self.source = source
        source.resume()
    }

    private func restartMonitoring() {
        source?.cancel()
        source = nil
        // Small delay to let the new file settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startMonitoring()
        }
    }

    private func scheduleCallback() {
        coalesceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isWatching else { return }
            self.coalesceWorkItem = nil
            self.callback()
        }
        coalesceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}
