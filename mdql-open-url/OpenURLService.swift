import Cocoa

/// The extension's hands outside its sandbox, and the last check on them:
/// whatever the extension forwards from a page, this opens, reads and writes
/// only what `AccessPolicy` allows, and logs each refusal.
class OpenURLService: NSObject, OpenURLProtocol {
    private let opener: (URL) -> Bool

    init(opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.opener = opener
    }

    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        reply(AccessPolicy.open(url, with: opener))
    }

    func readFile(at path: String, previewing documentPath: String, withReply reply: @escaping (String?, String?) -> Void) {
        guard let file = permittedFile(path, previewing: documentPath, to: "read") else {
            reply(nil, "mdql may not read \(path) for the preview of \(documentPath)")
            return
        }
        do {
            reply(try String(contentsOf: file, encoding: .utf8), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    /// Writes only `path`, the file the preview shows, and only when the
    /// preview may read it: never a file outside the previewed document's
    /// folder, nor one that is not Markdown.
    func toggleCheckbox(at path: String, offset: Int, checked: Bool, previewing documentPath: String, withReply reply: @escaping (CheckboxToggleOutcome) -> Void) {
        guard let file = permittedFile(path, previewing: documentPath, to: "write") else {
            reply(.failed)
            return
        }
        reply(CheckboxToggle.toggle(fileAt: file, offset: offset, checked: checked))
    }

    private func permittedFile(_ path: String, previewing documentPath: String, to action: String) -> URL? {
        do {
            return try AccessPolicy.file(URL(fileURLWithPath: path), previewing: URL(fileURLWithPath: documentPath))
        } catch {
            AccessPolicy.log.error("Refused to \(action, privacy: .public) \(path, privacy: .public) for the preview of \(documentPath, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
