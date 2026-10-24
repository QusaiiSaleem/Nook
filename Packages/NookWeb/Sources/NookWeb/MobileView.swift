// Licensed under GPL-3.0. See LICENSE.
//
//  MobileView.swift
//  Nook
//
//  A tab shown as an iPhone shows it: the page lays out at a phone's width in the middle of its
//  area (the web view itself is narrowed, as a narrow window would be), and it tells sites it is
//  iPhone Safari, so sites with separate phone versions serve those. There is no touch: WebKit on
//  the Mac has none.
//

import CoreGraphics

public enum MobileView {
    /// An iPhone 15 to 17's width in points.
    public static let width: CGFloat = 390

    /// The page's frame inside `bounds`: phone-wide and centered, or all of `bounds` when that is
    /// already narrower than a phone. Whole points, so the page never sits on a half-point edge.
    public static func frame(in bounds: CGRect) -> CGRect {
        guard bounds.width > width else { return bounds }
        return CGRect(x: (bounds.midX - width / 2).rounded(), y: bounds.minY, width: width, height: bounds.height)
    }

    /// iPhone Safari's user agent. Like desktop Safari's frozen 10_15_7, iPhone Safari 26 keeps its
    /// OS token at 18_6 and carries the real version in Version/.
    public static func userAgent(safariVersion: String) -> String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }
}
