import Foundation

/// Watches one file and calls back after it changes, once per burst of writes,
/// recovering when an editor replaces the file by renaming another over it.
///
/// A file moved or deleted is not given up on: the watcher says it is missing,
/// watches its folder until a file is back at its path, then says so, watches
/// that one and calls back. A folder it may not watch (the Quick Look sandbox
/// grants the file alone) it checks once a second instead.
///
/// Main-queue only: `start`, `stop`, the source's events and the callbacks all
/// run there, so the source, the pending work and `isWatching` are only ever
/// touched from one thread, and no callback comes after `stop` returns.
final class FileWatcher {
    private let url: URL
    private let callback: () -> Void

    /// Told false when the file is no longer at its path, true when it is back.
    var availabilityChanged: ((Bool) -> Void)?

    /// The file's source, or its folder's while the file is missing.
    private var source: DispatchSourceFileSystemObject?
    private var coalesceWorkItem: DispatchWorkItem?
    private var attachWorkItem: DispatchWorkItem?
    private(set) var isWatching = false
    private(set) var isMissing = false

    /// How long a replaced file gets to settle before it is opened again.
    private static let settleDelay: TimeInterval = 0.05
    /// How often a missing file is looked for when its folder can't be watched.
    private static let retryInterval: TimeInterval = 1

    init(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isWatching else { return }
        isWatching = true
        attach()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        isWatching = false
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        attachWorkItem?.cancel()
        attachWorkItem = nil
        source?.cancel() // its cancel handler closes the descriptor
        source = nil
    }

    deinit {
        // Nothing else holds the watcher by now, so nothing else can touch its state.
        coalesceWorkItem?.cancel()
        attachWorkItem?.cancel()
        source?.cancel()
    }

    /// Watches the file if it is at its path, else its folder until it is.
    private func attach() {
        guard isWatching, source == nil else { return }

        let fileDescriptor = open(url.path, O_EVTONLY)
        if fileDescriptor >= 0 {
            watchFile(fileDescriptor)
            if isMissing {
                isMissing = false
                availabilityChanged?(true)
                scheduleCallback()
            }
            return
        }

        // Nothing at the path to read: no update until something is back.
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        if !isMissing {
            isMissing = true
            availabilityChanged?(false)
        }
        let folderDescriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard folderDescriptor >= 0 else {
            attach(after: Self.retryInterval)
            return
        }
        watch(folderDescriptor, for: [.write, .rename, .delete]) { [weak self] _ in
            self?.reattach()
        }
        // The file may have come back before the folder was watched, which
        // then saw nothing happen: look again in a moment.
        if access(url.path, F_OK) == 0 {
            attach(after: Self.retryInterval)
        }
    }

    private func watchFile(_ fileDescriptor: Int32) {
        watch(fileDescriptor, for: [.write, .rename, .delete, .attrib]) { [weak self] flags in
            guard let self else { return }
            if flags.contains(.rename) || flags.contains(.delete) {
                // Replaced (vim, sed -i), moved or deleted: let a replacement
                // settle, then open whatever is at the path now.
                self.attach(after: Self.settleDelay)
            }
            self.scheduleCallback()
        }
    }

    private func watch(_ fileDescriptor: Int32, for events: DispatchSource.FileSystemEvent,
                       handler: @escaping (DispatchSource.FileSystemEvent) -> Void) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(source.data)
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        self.source = source
        source.resume()
    }

    private func reattach() {
        source?.cancel()
        source = nil
        attach()
    }

    /// Stops watching whatever is watched now, and attaches again after `delay`.
    private func attach(after delay: TimeInterval) {
        source?.cancel()
        source = nil
        attachWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isWatching else { return }
            self.attachWorkItem = nil
            self.attach()
        }
        attachWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
