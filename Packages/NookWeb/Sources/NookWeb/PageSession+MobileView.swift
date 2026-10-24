// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+MobileView.swift
//  Nook
//
//  Turning a tab's mobile view on or off: every view of the page takes the matching user agent and
//  reloads, so the site serves what it serves an iPhone, and the windows showing the tab lay it out
//  again at a phone's width (`MobileView.frame`).
//

import Foundation
import WebKit

extension PageSession {
    /// The user agent for this tab's views.
    var userAgent: String? {
        isMobileView ? MobileView.userAgent(safariVersion: PlatformUserAgent.safariVersion) : PlatformUserAgent.custom
    }

    public func setMobileView(_ on: Bool) {
        guard on != isMobileView else { return }
        isMobileView = on
        var views = controller?.webViews?.allWebViews(for: itemID) ?? []
        if let primary = webView, !views.contains(where: { $0 === primary }) { views.append(primary) }
        for view in views { view.customUserAgent = userAgent }
        webView?.reload()
        controller?.refreshWindows(showing: itemID)
    }
}
