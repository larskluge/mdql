import Cocoa
import WebKit

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: mdql-screenshot <input.md> <output.png> [width] [height]\n", stderr)
    exit(1)
}
let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let width = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3]) ?? 1200) : 1200
let height = CommandLine.arguments.count > 4 ? CGFloat(Double(CommandLine.arguments[4]) ?? 900) : 900

let inputURL = URL(fileURLWithPath: inputPath)

class Screenshotter: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let outputPath: String
    let width: CGFloat
    let height: CGFloat

    init(outputPath: String, width: CGFloat, height: CGFloat) {
        self.outputPath = outputPath
        self.width = width
        self.height = height
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func load(html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image else {
                fputs("Snapshot error: \(error?.localizedDescription ?? "unknown")\n", stderr)
                exit(1)
            }
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                fputs("PNG conversion failed\n", stderr)
                exit(1)
            }
            let outURL = URL(fileURLWithPath: self.outputPath)
            do {
                try pngData.write(to: outURL)
            } catch {
                fputs("Failed to write PNG: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            print("Screenshot saved to \(self.outputPath)")
            exit(0)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fputs("Navigation failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

do {
    let html = try MarkdownRenderer.render(fileAt: inputURL)
    let screenshotter = Screenshotter(outputPath: outputPath, width: width, height: height)
    screenshotter.load(html: html)
    withExtendedLifetime(screenshotter) {
        RunLoop.main.run()
    }
} catch {
    fputs("Failed to render: \(error)\n", stderr)
    exit(1)
}
