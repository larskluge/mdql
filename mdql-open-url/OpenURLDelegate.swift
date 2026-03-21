import Foundation

class OpenURLDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OpenURLProtocol.self)
        connection.exportedObject = OpenURLService()
        connection.resume()
        return true
    }
}
