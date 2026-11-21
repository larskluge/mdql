import Cocoa
import QuickLookUI
import Quartz
import WebKit
import os

class PreviewController: NSViewController, QLPreviewingController {
    let controller = MarkdownWebController()

    /// Makes the connection to the unsandboxed service (URL opening, file
    /// reading, checkbox writes), on the first call that needs it and again
    /// after one is invalidated. Tests connect to a service of their own.
    var makeConnection: () -> NSXPCConnection = { NSXPCConnection(serviceName: "com.mdql.app.open-url") }

    /// How long a call to the service may go unanswered before it fails.
    var replyTimeout: TimeInterval = 10

    private var xpcConnection: NSXPCConnection?

    /// Fails each call still waiting on the service: the connection was
    /// interrupted or invalidated, so no reply will come.
    private var pendingCalls: [UUID: () -> Void] = [:]

    /// Injectable URL opener. Default uses the XPC service to open in the default browser.
    var openURL: (URL, @escaping (PlainError?) -> Void) -> Void {
        get { controller.openURL }
        set { controller.openURL = newValue }
    }

    /// Currently displayed file URL (after navigation, this is the URL of the
    /// most-recently shown file, not necessarily the initial one).
    var fileURL: URL? { controller.fileURL }

    /// Whether the rendered page reserves room for a host window titlebar.
    /// Always false here — QuickLook draws no chrome. Exposed for testing.
    var appChrome: Bool { controller.appChrome }

    private var appearanceObserver: NSKeyValueObservation?

    deinit {
        xpcConnection?.invalidate()
    }

    override func loadView() {
        controller.webView.autoresizingMask = [.width, .height]
        self.view = controller.webView
        preferredContentSize = MarkdownRenderer.previewSize

        // Full-screen Quick Look hosts the preview in a vibrantDark window, which the
        // web view would inherit: prefers-color-scheme: dark, even in Light Mode.
        // Pin it to the system's appearance instead, and follow that as it changes.
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.initial]) { [weak self] app, _ in
            self?.view.appearance = app.effectiveAppearance
        }

        controller.openURL = { [weak self] url, completion in
            guard let self else { return completion(.helperDidntAnswer) }
            self.call(failure: PlainError.helperDidntAnswer, completion: completion) { service, reply in
                service.open(url) { opened in
                    reply(opened ? nil : PlainError("macOS couldn't open it"))
                }
            }
        }
        controller.readFile = { [weak self] url, completion in
            guard let self, let document = self.controller.documentURL else { return completion(.failure(.helperDidntAnswer)) }
            self.call(failure: .failure(.helperDidntAnswer), completion: completion) { service, reply in
                service.readFile(at: url.path, previewing: document.path) { text, encoding, failure in
                    if let text {
                        reply(.success(MarkdownText(string: text, encoding: encoding)))
                    } else {
                        reply(.failure(PlainError(failure ?? "the file couldn't be read")))
                    }
                }
            }
        }
        controller.interactive = true
        controller.toggleCheckbox = { [weak self] offset, checked, completion in
            guard let self, let url = self.controller.fileURL, let document = self.controller.documentURL else {
                return completion(.failed(.helperDidntAnswer))
            }
            self.call(failure: .failed(.helperDidntAnswer), completion: completion) { service, reply in
                service.toggleCheckbox(at: url.path, offset: offset, checked: checked, previewing: document.path) { outcome, failure in
                    reply(CheckboxToggleResult(outcome: outcome, reason: failure))
                }
            }
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            try controller.loadMarkdownFile(at: url)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    /// Loads and renders a markdown file directly. Exposed for testing.
    @discardableResult
    func loadMarkdownFile(at url: URL) throws -> Bool {
        try controller.loadMarkdownFile(at: url)
    }

    /// Handles an openURL action. Exposed for testing.
    func handleOpenURL(_ urlString: String) {
        controller.handleOpenURL(urlString)
    }

    /// Handles an openMarkdown action. Exposed for testing.
    func handleOpenMarkdown(_ urlString: String) {
        controller.handleOpenMarkdown(urlString)
    }

    // MARK: - XPC

    /// Sends one request to the service and completes it exactly once, on the
    /// main queue: with the service's reply, or with `failure` when the proxy
    /// reports an error, the connection is interrupted or invalidated, or no
    /// reply comes within `replyTimeout`. Never silence.
    private func call<Reply>(failure: Reply, completion: @escaping (Reply) -> Void,
                             _ send: (OpenURLProtocol, @escaping (Reply) -> Void) -> Void) {
        let id = UUID()
        var answered = false
        let finish: (Reply) -> Void = { [weak self] reply in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                self?.pendingCalls[id] = nil
                completion(reply)
            }
        }
        pendingCalls[id] = { finish(failure) }
        let proxy = connection().remoteObjectProxyWithErrorHandler { error in
            Self.log.error("XPC call to the open-url service failed: \(error.localizedDescription, privacy: .public)")
            finish(failure)
        } as? OpenURLProtocol
        guard let proxy else {
            Self.log.error("The open-url service's proxy does not speak OpenURLProtocol")
            return finish(failure)
        }
        send(proxy, finish)
        let timeout = replyTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !answered {
                Self.log.error("The open-url service did not answer within \(timeout, privacy: .public) s")
            }
            finish(failure)
        }
    }

    private func connection() -> NSXPCConnection {
        if let xpcConnection { return xpcConnection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: OpenURLProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Self.log.error("The open-url service's connection was interrupted")
            DispatchQueue.main.async { self?.failPendingCalls() }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            Self.log.error("The open-url service's connection was invalidated")
            DispatchQueue.main.async {
                guard let self else { return }
                if self.xpcConnection === connection { self.xpcConnection = nil }
                self.failPendingCalls()
            }
        }
        connection.resume()
        xpcConnection = connection
        return connection
    }

    private func failPendingCalls() {
        let calls = pendingCalls.values
        pendingCalls.removeAll()
        calls.forEach { $0() }
    }

    private static let log = Logger(subsystem: "com.mdql.app", category: "preview")
}
