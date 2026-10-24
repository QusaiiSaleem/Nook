// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Components/AreaCapture/AreaCaptureRenderer.swift scripts/tests/AreaCaptureRendererCheck.swift \
//         -o /tmp/acr && /tmp/acr
//
//  Capture Area's picture: the crop at full pixel scale, with arrows and highlights drawn where
//  they were placed (top-left points), not mirrored.

import CoreGraphics
import Foundation

@main
struct AreaCaptureRendererCheck {
    static func main() {
        // A 200×100 pt page snapshot at 2× (400×200 px), white.
        let page = solid(width: 400, height: 200, white: 1)
        let red = CGColor(red: 0.96, green: 0, blue: 0, alpha: 1)
        let yellow = CGColor(red: 1, green: 0.85, blue: 0, alpha: 0.35)
        let crop = CGRect(x: 50, y: 25, width: 100, height: 50)
        let marks: [CaptureMark] = [
            .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 10)),
            .highlight([CGPoint(x: 10, y: 40), CGPoint(x: 90, y: 40)])
        ]
        guard let out = AreaCaptureRenderer.render(page, crop: crop, scale: 2, marks: marks, arrowColor: red, highlightColor: yellow)
        else { preconditionFailure("no image") }

        precondition(out.width == 200 && out.height == 100, "crop at 2×: \(out.width)×\(out.height)")
        let arrow = pixel(out, x: 100, y: 20)          // (50, 10) pt: on the arrow, near the top
        precondition(arrow.r > 200 && arrow.g < 60 && arrow.b < 60, "arrow pixel \(arrow)")
        let mark = pixel(out, x: 100, y: 80)           // (50, 40) pt: on the highlight, near the bottom
        precondition(mark.r > 230 && mark.g > 200 && mark.b < 200, "highlight pixel \(mark)")
        let clear = pixel(out, x: 100, y: 50)          // between them: untouched white
        precondition(clear.r > 250 && clear.g > 250 && clear.b > 250, "untouched pixel \(clear)")

        // The arrowhead's wings sit behind the tip, one on each side of the line.
        let (left, right) = AreaCaptureRenderer.arrowHead(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), length: 10)
        precondition(left.x < 100 && right.x < 100 && left.y * right.y < 0, "wings \(left) \(right)")
        print("AreaCaptureRendererCheck passed")
    }

    static func solid(width: Int, height: Int, white: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// RGBA at (x, y) with y counted from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}
