import Foundation

/// What the Quick Look extension asks of the unsandboxed XPC service. The
/// service keeps no state between calls (launchd may relaunch it at any
/// time), so each file call names `documentPath`, the file Quick Look asked
/// to preview, whose folder bounds what `AccessPolicy` lets the call touch.
/// A failure replies why, in plain words for a notice.
@objc protocol OpenURLProtocol {
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)
    func readFile(at path: String, previewing documentPath: String, withReply reply: @escaping (_ text: String?, _ encoding: MarkdownEncoding, _ failure: String?) -> Void)
    func toggleCheckbox(at path: String, offset: Int, checked: Bool, previewing documentPath: String, withReply reply: @escaping (_ outcome: CheckboxToggleOutcome, _ failure: String?) -> Void)
}
