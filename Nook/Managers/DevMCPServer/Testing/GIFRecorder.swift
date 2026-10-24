// Licensed under GPL-3.0. See LICENSE.
//
//  GIFRecorder.swift
//  Nook
//
//  MCP `record_start` / `record_stop`: frames of the agent's page become a looping GIF. Frames
//  are kept as JPEG while recording (a full minute of raw frames would be hundreds of megabytes)
//  and turned into the GIF when the recording stops.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class GIFRecorder {
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
    private var frames: [Data] = []

    var count: Int { frames.count }

    init(width: CGFloat = 800, fps: Double = 4, maxSeconds: TimeInterval = 60) {
        self.width = width
        self.fps = fps
        maxFrames = Int(fps * maxSeconds)
    }

    /// Keeps `frame`, scaled down to `width`; false once the recording is full.
    func add(_ frame: CGImage) -> Bool {
        guard frames.count < maxFrames, let jpeg = Self.jpeg(Self.scaled(frame, toWidth: width)) else { return false }
        frames.append(jpeg)
        return true
    }

    /// Writes a GIF that loops forever and answers how many frames it holds.
    func write(to url: URL) throws -> Int {
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
