// Licensed under GPL-3.0. See LICENSE.
//
//  AreaCaptureRenderer.swift
//  Nook
//
//  Capture Area's picture: the selected part of the page snapshot at full pixel scale, with the
//  person's arrows and highlights drawn on it. Marks are in points from the crop's top-left
//  corner, as the markup view placed them.
//

import CoreGraphics
import Foundation

enum CaptureMark: Equatable {
    case arrow(from: CGPoint, to: CGPoint)
    case highlight([CGPoint])

    static let arrowWidth: CGFloat = 4
    static let arrowHeadLength: CGFloat = 16
    static let highlightWidth: CGFloat = 18
}

enum AreaCaptureRenderer {
    /// `crop` and the marks are in snapshot points; `scale` is pixels per point.
    static func render(
        _ snapshot: CGImage, crop: CGRect, scale: CGFloat, marks: [CaptureMark],
        arrowColor: CGColor, highlightColor: CGColor
    ) -> CGImage? {
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        guard !pixels.isEmpty, let cropped = snapshot.cropping(to: pixels),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = CGSize(width: cropped.width, height: cropped.height)
        context.draw(cropped, in: CGRect(origin: .zero, size: size))
        // Marks are top-left points; the bitmap is bottom-left pixels.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            switch mark {
            case .highlight(let points):
                guard let first = points.first else { continue }
                context.setStrokeColor(highlightColor)
                context.setLineWidth(CaptureMark.highlightWidth)
                context.beginPath()
                context.move(to: first)
                points.dropFirst().forEach { context.addLine(to: $0) }
                context.strokePath()
            case .arrow(let from, let to):
                let (left, right) = arrowHead(from: from, to: to, length: CaptureMark.arrowHeadLength)
                context.setStrokeColor(arrowColor)
                context.setLineWidth(CaptureMark.arrowWidth)
                context.beginPath()
                context.move(to: from)
                context.addLine(to: to)
                context.move(to: left)
                context.addLine(to: to)
                context.addLine(to: right)
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    /// The two ends of the arrowhead's wings, 30° either side of the line, behind the tip.
    static func arrowHead(from: CGPoint, to: CGPoint, length: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let spread = CGFloat.pi / 6
        func wing(_ offset: CGFloat) -> CGPoint {
            CGPoint(x: to.x - length * cos(angle + offset), y: to.y - length * sin(angle + offset))
        }
        return (wing(spread), wing(-spread))
    }
}
