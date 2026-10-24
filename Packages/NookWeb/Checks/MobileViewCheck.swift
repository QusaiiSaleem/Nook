// Licensed under GPL-3.0. See LICENSE.
//
//  MobileViewCheck.swift
//  Nook
//
//  A tab shown as an iPhone shows it: where the page sits and what it tells sites. NookWeb has no
//  test target, so this compiles the shipped source directly:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/MobileView.swift \
//           Packages/NookWeb/Checks/MobileViewCheck.swift -o /tmp/mv && /tmp/mv
//

import CoreGraphics

@main
struct MobileViewCheck {
    static func main() {
        // Phone-wide and centered in a wide page area, full height.
        precondition(MobileView.frame(in: CGRect(x: 0, y: 0, width: 1280, height: 800)) == CGRect(x: 445, y: 0, width: 390, height: 800))
        // An area already narrower than a phone keeps its own width.
        precondition(MobileView.frame(in: CGRect(x: 0, y: 0, width: 300, height: 700)) == CGRect(x: 0, y: 0, width: 300, height: 700))
        // Whole points, so the page does not draw blurry on a half-point edge.
        let odd = MobileView.frame(in: CGRect(x: 10, y: 5, width: 1001, height: 600))
        precondition(odd.width == 390 && odd.minX == odd.minX.rounded() && abs(odd.midX - 510.5) <= 0.5, "odd width: \(odd)")

        // iPhone Safari's identity, with the installed Safari's version, so sites serve their phone
        // pages and gate features on the right version.
        let agent = MobileView.userAgent(safariVersion: "26.4")
        for part in ["(iPhone;", "Mobile/", "Version/26.4", "Safari/"] {
            precondition(agent.contains(part), "user agent lacks \(part): \(agent)")
        }
        precondition(!agent.contains("Macintosh"), "user agent still says Mac: \(agent)")
        print("MobileViewCheck passed")
    }
}
