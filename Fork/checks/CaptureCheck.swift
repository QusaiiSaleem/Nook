// Licensed under GPL-3.0. See LICENSE.
//
// Loads a page in an off-screen WKWebView, asks WebKit for the full-page PDF the way
// Capture Full Page does, renders it with the shipped `BrowserManager.pngImage(fromPDF:scale:)`
// logic (copied below, keep in step), and checks the image is taller than the window.
// swiftc -parse-as-library Fork/checks/CaptureCheck.swift -o /tmp/capturecheck && /tmp/capturecheck <url> <out.png>
//
import AppKit
import PDFKit
import WebKit

@main
@MainActor
struct CaptureCheck {
    static func main() async throws {
        let args = CommandLine.arguments
        let url = URL(string: args.count > 1 ? args[1] : "https://en.wikipedia.org/wiki/Web_browser")!
        let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/capture-check.png")
        _ = NSApplication.shared
        let viewport = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: viewport, styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: viewport)
        window.contentView = webView
        let loader = Loader()
        webView.navigationDelegate = loader
        webView.load(URLRequest(url: url))
        try await loader.wait()
        try await Task.sleep(for: .seconds(2))
        let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
        guard let png = pngImage(fromPDF: pdf, scale: 2), let rep = NSBitmapImageRep(data: png) else { fatalError("no image") }
        try png.write(to: out)
        print("viewport \(Int(viewport.height)) pt tall; capture \(rep.pixelsWide)x\(rep.pixelsHigh) px = \(rep.pixelsHigh / 2) pt tall at 2x -> \(out.path)")
        precondition(rep.pixelsHigh / 2 > Int(viewport.height) * 2, "capture is not a full page")
        print("CaptureCheck passed")
    }

    // Same as BrowserManager.pngImage(fromPDF:scale:).
    static func pngImage(fromPDF data: Data, scale: CGFloat) -> Data? {
        guard let document = PDFDocument(data: data) else { return nil }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        let sizes = pages.map { $0.bounds(for: .mediaBox).size }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height }
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(scale, 32_000 / height, 16_000 / width)
        guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        var top = height
        for (page, size) in zip(pages, sizes) {
            top -= size.height
            context.saveGState()
            context.translateBy(x: 0, y: top)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws { try await withCheckedThrowingContinuation { continuation = $0 } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
