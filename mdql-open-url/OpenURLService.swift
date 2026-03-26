import Cocoa

class OpenURLService: NSObject, OpenURLProtocol {
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        let result = NSWorkspace.shared.open(url)
        reply(result)
    }

    func readFile(at path: String, withReply reply: @escaping (String?, String?) -> Void) {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            reply(content, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }
}
