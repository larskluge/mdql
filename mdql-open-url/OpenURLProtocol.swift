import Foundation

@objc protocol OpenURLProtocol {
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)
}
