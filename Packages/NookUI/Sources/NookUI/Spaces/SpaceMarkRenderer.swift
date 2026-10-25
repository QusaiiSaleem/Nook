// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkRenderer.swift
//  Nook
//
//  Draws the SVG a person picks for a space's mark into a small square PNG, once, off the main
//  thread and within a time limit; only the PNG is kept (`SpaceMark.picture`). The image is sized
//  to the mark before drawing, so an SVG declaring itself 100,000 px wide costs what 64 px costs.
//

#if canImport(AppKit)
import AppKit

enum SpaceMarkRenderer {
    /// The PNG, `pixels` square with the SVG fitted inside, or nil when the SVG does not open or
    /// is not drawn within `deadline` (the drawing cannot be stopped; its result is dropped).
    static func png(fromSVG data: Data, pixels: Int, deadline: Duration = .seconds(1)) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = RenderOnce()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = draw(data, pixels: pixels)
                if once.claim() { continuation.resume(returning: result) }
            }
            let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private static func draw(_ data: Data, pixels: Int) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let side = CGFloat(pixels)
        let scale = min(side / image.size.width, side / image.size.height)
        let fitted = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.size = fitted
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Lets the first of the drawing and its deadline answer.
private final class RenderOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
#endif
