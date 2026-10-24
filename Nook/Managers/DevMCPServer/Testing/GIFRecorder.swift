// Licensed under GPL-3.0. See LICENSE.
//
//  GIFRecorder.swift
//  Nook
//
//  MCP `record_start` / `record_stop`: frames of the agent's page become a looping GIF. Frames
//  are kept as JPEG while recording (a full minute of raw frames would be hundreds of megabytes)
//  and turned into the GIF when the recording stops. All image work runs on the recorder's own
//  queue: on the main thread, a minute's GIF froze the person's browser for 4 to 11 s.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class GIFRecorder: @unchecked Sendable {
    enum Failure: LocalizedError {
        case empty, writeFailed

        var errorDescription: String? {
            switch self {
            case .empty: "No frames were recorded."
            case .writeFailed: "The GIF could not be written."
            }
        }
    }

    let width: CGFloat
    let fps: Double
    let maxFrames: Int
    private let queue = DispatchQueue(label: "com.qusai.nook.gif-recorder", qos: .utility)
    /// Encoded frames; touched on `queue` only.
    private var frames: [Data] = []
    /// Frames taken so far; touched by the caller only.
    private var taken = 0

    var count: Int { taken }

    init(width: CGFloat = 800, fps: Double = 4, maxSeconds: TimeInterval = 60) {
        self.width = width
        self.fps = fps
        maxFrames = Int(fps * maxSeconds)
    }

    /// Keeps `frame`, scaled down to `width` on the recorder's queue; false once the recording is full.
    func add(_ frame: CGImage) -> Bool {
        guard taken < maxFrames else { return false }
        taken += 1
        let width = self.width
        queue.async {
            if let jpeg = Self.jpeg(Self.scaled(frame, toWidth: width)) { self.frames.append(jpeg) }
        }
        return true
    }

    /// Takes a frame every 1/fps until the recording is full, `maxSeconds` have passed or the task
    /// is cancelled. A frame that fails is skipped; one that does not come within a second is
    /// given up, so a stuck page cannot keep the recording (and the agent page) going.
    @MainActor func record(_ frame: @escaping @MainActor () async -> CGImage?) async {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(Double(maxFrames) / fps))
        while !Task.isCancelled, clock.now < end, count < maxFrames {
            let started = clock.now
            if let image = await Self.within(.seconds(1), frame), !add(image) { return }
            try? await Task.sleep(until: min(started.advanced(by: .seconds(1 / fps)), end), clock: clock)
        }
    }

    /// The frame, or nil when it has not come within `limit`.
    @MainActor private static func within(_ limit: Duration, _ frame: @escaping @MainActor () async -> CGImage?) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let once = FrameOnce()
            Task { @MainActor in
                let image = await frame()
                if once.claim() { continuation.resume(returning: image) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Writes a GIF that loops forever, once every frame is encoded, and answers how many frames
    /// it holds.
    func write(to url: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.writeNow(to: url) }) }
        }
    }

    private func writeNow(to url: URL) throws -> Int {
        guard !frames.isEmpty else { throw Failure.empty }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw Failure.writeFailed }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for data in frames {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }
        return frames.count
    }

    private static func scaled(_ image: CGImage, toWidth width: CGFloat) -> CGImage {
        guard CGFloat(image.width) > width else { return image }
        let height = (CGFloat(image.height) * width / CGFloat(image.width)).rounded()
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Lets the first of a frame and its time limit answer.
@MainActor private final class FrameOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}
