import Cocoa
import QuickLookUI
import Quartz
import WebKit

class PreviewController: NSViewController, QLPreviewingController {
    private let controller = MarkdownWebController()
    private var xpcConnection: NSXPCConnection?

    /// Injectable URL opener. Default uses the XPC service to open in the default browser.
    var openURL: (URL) -> Void {
        get { controller.openURL }
        set { controller.openURL = newValue }
    }

    /// Currently displayed file URL (after navigation, this is the URL of the
    /// most-recently shown file, not necessarily the initial one).
    var fileURL: URL? { controller.fileURL }

    deinit {
        xpcConnection?.invalidate()
    }

    override func loadView() {
        controller.webView.autoresizingMask = [.width, .height]
        self.view = controller.webView
        preferredContentSize = MarkdownRenderer.previewSize

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
            guard let proxy = self?.xpcProxy else { completion(nil); return }
            proxy.readFile(at: url.path) { content, _ in
                DispatchQueue.main.async { completion(content) }
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
    func handleOpenURL(_ urlString: String, background: Bool) {
        controller.handleOpenURL(urlString, background: background)
    }

    /// Handles an openMarkdown action. Exposed for testing.
    func handleOpenMarkdown(_ urlString: String) {
        controller.handleOpenMarkdown(urlString)
    }

    private var xpcProxy: OpenURLProtocol? {
        xpcConnection?.remoteObjectProxyWithErrorHandler({ _ in }) as? OpenURLProtocol
    }
}
