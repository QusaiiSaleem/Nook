// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/DevMCPServer/Testing/GIFRecorder.swift \
//         scripts/tests/GIFRecorderCheck.swift -o /tmp/gif && /tmp/gif
//
//  MCP `record_*`: the GIF holds every frame it was given, at most 800 px wide, and the recorder
//  refuses frames past its length (4 fps for 60 s is 240 frames).

import CoreGraphics
import Foundation
import ImageIO

@main
struct GIFRecorderCheck {
    static func main() throws {
        let recorder = GIFRecorder()
        for shade in [0.2, 0.5, 0.8] { precondition(recorder.add(solid(width: 1600, height: 1000, shade: shade))) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID().uuidString).gif")
        let frames = try recorder.write(to: file)
        precondition(frames == 3, "frames \(frames)")
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { preconditionFailure("not an image file") }
        precondition(CGImageSourceGetCount(source) == 3, "file holds \(CGImageSourceGetCount(source)) frames")
        let width = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        precondition(width == 800, "frame width \(String(describing: width))")

        let full = GIFRecorder(width: 100, fps: 4, maxSeconds: 60)
        let frame = solid(width: 100, height: 60, shade: 0.5)
        for index in 1...240 { precondition(full.add(frame), "frame \(index) refused") }
        precondition(!full.add(frame), "the 241st frame was taken")
        print("GIFRecorderCheck passed")
    }

    static func solid(width: Int, height: Int, shade: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: shade, green: 0.3, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
