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

    func readFile(at path: String, previewing documentPath: String, withReply reply: @escaping (String?, MarkdownEncoding, String?) -> Void) {
        let file: URL
        switch permittedFile(path, previewing: documentPath, to: "read") {
        case .success(let permitted): file = permitted
        case .failure(let error): return reply(nil, .utf8, error.reason)
        }
        switch MarkdownText.read(file) {
        case .success(let text): reply(text.string, text.encoding, nil)
        case .failure(let error): reply(nil, .utf8, error.reason)
        }
    }

    /// Writes only `path`, the file the preview shows, and only when the
    /// preview may read it: never a file outside the previewed document's
    /// folder, nor one that is not Markdown.
    func toggleCheckbox(at path: String, offset: Int, checked: Bool, previewing documentPath: String, withReply reply: @escaping (CheckboxToggleOutcome, String?) -> Void) {
        let result: CheckboxToggleResult
        switch permittedFile(path, previewing: documentPath, to: "write") {
        case .success(let file): result = CheckboxToggle.toggle(fileAt: file, offset: offset, checked: checked)
        case .failure(let error): result = .failed(error)
        }
        reply(result.reply.outcome, result.reply.reason)
    }

    private func permittedFile(_ path: String, previewing documentPath: String, to action: String) -> Result<URL, PlainError> {
        do {
            return .success(try AccessPolicy.file(URL(fileURLWithPath: path), previewing: URL(fileURLWithPath: documentPath)))
        } catch let refusal as AccessPolicy.Refusal {
            AccessPolicy.log.error("Refused to \(action, privacy: .public) \(path, privacy: .public) for the preview of \(documentPath, privacy: .public): \(String(describing: refusal), privacy: .public)")
            return .failure(PlainError(refusal.plainReason(naming: (path as NSString).lastPathComponent)))
        } catch {
            AccessPolicy.log.error("Refused to \(action, privacy: .public) \(path, privacy: .public) for the preview of \(documentPath, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(PlainError(describing: error))
        }
    }
}
