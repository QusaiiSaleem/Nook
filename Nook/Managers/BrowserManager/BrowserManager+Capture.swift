// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Capture.swift
//  Nook
//
//  Capture Full Page, as in Arc: the whole page, top to bottom, as a PNG saved through the
//  downloads list and copied to the clipboard. WebKit renders the full page into a PDF
//  (`WKWebView.pdf(configuration:)`, no scrolling), which is drawn into one tall image.
//

import AppKit
import OSLog
import PDFKit
import WebKit
import NookWeb

extension BrowserManager {
    private static let captureLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Capture")

    /// Captures the page the window shows, in full.
    func captureFullPage(in windowState: BrowserWindowState) {
        guard let session = tabs.selectedSession(in: windowState), let webView = session.webView else { return }
        let scale = webView.window?.backingScaleFactor ?? 2
        Task { @MainActor in
            do {
                let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
                guard let png = Self.pngImage(fromPDF: pdf, scale: scale) else {
                    Self.captureLog.error("Capture: no image from the page's PDF")
                    return
                }
                downloadManager.saveCompletedFile(png, suggestedFilename: Self.captureFilename(for: session), originalURL: session.url, from: webView.window)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                windowState.copyToastText = "Full page captured"
                windowState.isShowingCopyURLToast = true
                try? await Task.sleep(for: .seconds(2))
                windowState.isShowingCopyURLToast = false
                windowState.copyToastText = nil
            } catch {
                Self.captureLog.error("Capture failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Every page of the PDF stacked into one PNG. The scale drops for very long pages so the
    /// image stays within what Core Graphics and image viewers handle.
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

    private static func captureFilename(for session: PageSession) -> String {
        let name = session.title.isEmpty ? (session.url.host ?? "Page") : session.title
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        return "\(name) \(stamp.replacingOccurrences(of: ":", with: ".")).png"
    }
}
