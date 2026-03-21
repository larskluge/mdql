import Cocoa

class OpenURLService: NSObject, OpenURLProtocol {
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        let result = NSWorkspace.shared.open(url)
        reply(result)
    }
}
