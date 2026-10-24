// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceMarkRendererCheck.swift
//  Nook
//
//  The SVG a person picks for a space's mark is drawn once into a small PNG, off the main
//  thread and within a time limit. NookUI has no test target, so this compiles the source:
//
//    swiftc -parse-as-library Packages/NookUI/Sources/NookUI/Spaces/SpaceMarkRenderer.swift \
//           Packages/NookUI/Checks/SpaceMarkRendererCheck.swift -o /tmp/smr && /tmp/smr
//

import AppKit

@main
struct SpaceMarkRendererCheck {
    static func main() async {
        let star = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 2l3 7h7l-5.5 4.5L18.5 21 12 16.5 5.5 21l2-7.5L2 9h7z" fill="#0a7"/></svg>"##.utf8)
        guard let png = await SpaceMarkRenderer.png(fromSVG: star, pixels: 64),
              let rep = NSBitmapImageRep(data: png) else { preconditionFailure("a plain icon was not drawn") }
        precondition(rep.pixelsWide == 64 && rep.pixelsHigh == 64, "size \(rep.pixelsWide)×\(rep.pixelsHigh)")
        precondition((rep.colorAt(x: 32, y: 34)?.alphaComponent ?? 0) > 0.5, "the star's middle is empty")

        // Declares itself 100,000 px square: drawn at the mark's size, so quick and small.
        let giant = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"><circle cx="50000" cy="50000" r="40000" fill="#e53"/></svg>"##.utf8)
        var start = Date()
        let giantPNG = await SpaceMarkRenderer.png(fromSVG: giant, pixels: 64)
        precondition(giantPNG != nil, "a giant-sized SVG was not drawn")
        precondition(Date().timeIntervalSince(start) < 2, "a giant-sized SVG took \(Date().timeIntervalSince(start)) s")

        let garbage = await SpaceMarkRenderer.png(fromSVG: Data("not an svg".utf8), pixels: 64)
        precondition(garbage == nil, "garbage was drawn")

        // A blur over a huge region never finishes drawing: the renderer gives up at its deadline.
        let blur = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="20000" height="20000"><filter id="b" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="900"/></filter><rect width="20000" height="20000" filter="url(#b)"/></svg>"##.utf8)
        start = Date()
        _ = await SpaceMarkRenderer.png(fromSVG: blur, pixels: 64, deadline: .seconds(1))
        precondition(Date().timeIntervalSince(start) < 2, "the renderer waited \(Date().timeIntervalSince(start)) s past its deadline")
        print("SpaceMarkRendererCheck passed")
        exit(0)
    }
}
