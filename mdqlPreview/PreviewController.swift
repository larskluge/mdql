import Cocoa
import QuickLookUI
import Quartz
import WebKit
import os

class PreviewController: NSViewController, QLPreviewingController {
    let controller = MarkdownWebController()
    private var xpcConnection: NSXPCConnection?

    /// Injectable URL opener. Default uses the XPC service to open in the default browser.
    var openURL: (URL) -> Void {
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

        // Set up XPC connection to unsandboxed service (URL opening + file reading)
        let connection = NSXPCConnection(serviceName: "com.mdql.app.open-url")
        connection.remoteObjectInterface = NSXPCInterface(with: OpenURLProtocol.self)
        connection.resume()
        self.xpcConnection = connection

        controller.openURL = { [weak self] url in
            guard let proxy = self?.xpcProxy else { return }
            proxy.open(url) { _ in }
        }
        controller.readFile = { [weak self] url, completion in
            guard let document = self?.controller.documentURL,
                  let proxy = self?.xpcProxy else { completion(nil); return }
            proxy.readFile(at: url.path, previewing: document.path) { content, _ in
                DispatchQueue.main.async { completion(content) }
            }
        }
        controller.interactive = true
        controller.toggleCheckbox = { [weak self] offset, checked, completion in
            guard let url = self?.controller.fileURL,
                  let document = self?.controller.documentURL,
                  let proxy = self?.xpcProxy else { completion(.failed); return }
            proxy.toggleCheckbox(at: url.path, offset: offset, checked: checked, previewing: document.path) { outcome in
                DispatchQueue.main.async { completion(outcome) }
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

    private var xpcProxy: OpenURLProtocol? {
        xpcConnection?.remoteObjectProxyWithErrorHandler({ error in
            Self.log.error("XPC call to the open-url service failed: \(error.localizedDescription, privacy: .public)")
        }) as? OpenURLProtocol
    }

    private static let log = Logger(subsystem: "com.mdql.app", category: "preview")
}
