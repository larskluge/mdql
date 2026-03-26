import Foundation

@objc protocol OpenURLProtocol {
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)
    func readFile(at path: String, withReply reply: @escaping (String?, String?) -> Void)
}
