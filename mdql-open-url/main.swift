import Foundation

let delegate = OpenURLDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
