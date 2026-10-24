// Licensed under GPL-3.0. See LICENSE.
//
//  SitePermission.swift
//  Nook
//
//  Created by Bain Gurley on 21/09/2026.
//

import Foundation

/// A capability a page can ask for and Nook can answer without prompting.
///
/// WebKit routes camera and microphone through `requestMediaCaptureAuthorization`, so a stored
/// answer can be applied. Web notifications have no WebKit delegate on macOS; Nook's own
/// `Notification` shim (`WebNotificationScripts`) asks for them, so their answer is stored here
/// too. Geolocation has neither and stays app-level.
public enum SitePermission: String, Codable, CaseIterable, Sendable {
    case camera
    case microphone
    case notifications
}

/// What to do when a site asks. `.ask` means prompt, which is WebKit's own behaviour.
public enum SitePermissionPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case allow
    case block

    public var label: String {
        switch self {
        case .ask: return "Ask"
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }
}

/// One site's stored answers, keyed by host. Hosts are stored lowercased with `www.` dropped so
/// `www.example.com` and `example.com` share one decision.
public struct SitePermissionRecord: Codable, Equatable, Sendable {
    public var host: String
    public var policies: [SitePermission: SitePermissionPolicy]

    public init(host: String, policies: [SitePermission: SitePermissionPolicy] = [:]) {
        self.host = host
        self.policies = policies
    }

    /// The canonical key for a host, so one site has one record.
    public static func key(for host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}
