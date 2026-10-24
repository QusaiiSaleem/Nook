// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/DevMCPServer/Testing/GIFRecorder.swift \
//         scripts/tests/GIFRecorderCheck.swift -o /tmp/gif && /tmp/gif
//
//  MCP `record_*`: the GIF holds every frame it was given, at most 800 px wide; the recorder
//  refuses frames past its length (4 fps for 60 s is 240 frames); encoding never holds the main
//  thread (the person's browser) and a recording ends on the clock even when frames fail.

import CoreGraphics
import Foundation
import ImageIO

@main
struct GIFRecorderCheck {
    @MainActor static func main() async throws {
        try await gif_has_its_frames()
        try await writing_leaves_the_main_thread_free()
        await recording_ends_by_the_clock()
        print("GIFRecorderCheck passed")
    }

    @MainActor static func gif_has_its_frames() async throws {
        let recorder = GIFRecorder()
        for shade in [0.2, 0.5, 0.8] { precondition(recorder.add(solid(width: 1600, height: 1000, shade: shade))) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID().uuidString).gif")
        let frames = try await recorder.write(to: file)
        precondition(frames == 3, "frames \(frames)")
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { preconditionFailure("not an image file") }
        precondition(CGImageSourceGetCount(source) == 3, "file holds \(CGImageSourceGetCount(source)) frames")
        let width = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        precondition(width == 800, "frame width \(String(describing: width))")

        let full = GIFRecorder(width: 100, fps: 4, maxSeconds: 60)
        let frame = solid(width: 100, height: 60, shade: 0.5)
        for index in 1...240 { precondition(full.add(frame), "frame \(index) refused") }
        precondition(!full.add(frame), "the 241st frame was taken")
    }

    /// The main thread is the person's browser: adding frames and writing the GIF must not hold it.
    @MainActor static func writing_leaves_the_main_thread_free() async throws {
        let recorder = GIFRecorder(fps: 10, maxSeconds: 60)
        let frames = (0..<60).map { noise(width: 1600, height: 1000, seed: $0) }
        let addStart = Date()
        for frame in frames { precondition(recorder.add(frame)) }
        let adding = Date().timeIntervalSince(addStart)
        precondition(adding < 0.15, "adding 60 frames held the main thread for \(adding) s")

        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(20)) }
        }
        let start = Date()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gif-free-\(UUID().uuidString).gif")
        let written = try await recorder.write(to: file)
        let took = Date().timeIntervalSince(start)
        ticker.cancel()
        precondition(written == 60, "frames \(written)")
        precondition(took > 0.2, "the write was too quick (\(took) s) to show anything")
        precondition(Double(ticks) >= took / 0.02 * 0.5, "the main thread ticked \(ticks) times in \(took) s: the write held it")
    }

    /// Frames that fail, or never come, must not keep a recording going.
    @MainActor static func recording_ends_by_the_clock() async {
        let failing = GIFRecorder(fps: 10, maxSeconds: 1)
        var start = Date()
        await failing.record { nil }
        precondition(Date().timeIntervalSince(start) < 2, "failing frames kept recording for \(Date().timeIntervalSince(start)) s")

        let hanging = GIFRecorder(fps: 10, maxSeconds: 1)
        start = Date()
        await hanging.record { try? await Task.sleep(for: .seconds(100)); return nil }
        precondition(Date().timeIntervalSince(start) < 3, "a frame that never came kept recording for \(Date().timeIntervalSince(start)) s")

        let working = GIFRecorder(fps: 10, maxSeconds: 1)
        await working.record { solid(width: 200, height: 100, shade: 0.4) }
        precondition(working.count >= 5 && working.count <= 11, "1 s at 10 fps gave \(working.count) frames")
    }

    static func solid(width: Int, height: Int, shade: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: shade, green: 0.3, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Detailed frames, so encoding them costs what a real page's frames cost.
    static func noise(width: Int, height: Int, seed: Int) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for _ in 0..<400 {
            context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                         blue: CGFloat(seed % 10) / 10, alpha: 1))
            context.fill(CGRect(x: .random(in: 0...width, using: &generator), y: .random(in: 0...height, using: &generator), width: 120, height: 40))
        }
        return context.makeImage()!
    }
}
