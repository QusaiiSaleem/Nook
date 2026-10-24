// Licensed under GPL-3.0. See LICENSE.
//
//  WebNotificationPolicy.swift
//  Nook
//
//  The rules behind a page's notification requests, kept free of WebKit so a check can run them.
//  Answers are the per-site `SitePermission.notifications` policy; private windows and the Agent
//  space always read as "denied" and never prompt.
//

import Foundation
#if canImport(NookSettings)
import NookSettings
#endif

public enum WebNotificationPolicy {
    public enum Answer: Equatable {
        /// Tell the page this, no prompt.
        case reply(String)
        /// Ask the person.
        case prompt
    }

    /// The answer to `Notification.requestPermission()`.
    public static func answer(stored: SitePermissionPolicy, isPrivateOrAgent: Bool) -> Answer {
        if isPrivateOrAgent { return .reply("denied") }
        switch stored {
        case .allow: return .reply("granted")
        case .block: return .reply("denied")
        case .ask: return .prompt
        }
    }

    /// What `Notification.permission` reads before the page asks.
    public static func query(stored: SitePermissionPolicy, isPrivateOrAgent: Bool) -> String {
        switch answer(stored: stored, isPrivateOrAgent: isPrivateOrAgent) {
        case .reply(let value): return value
        case .prompt: return "default"
        }
    }

    /// Whether a notification may reach macOS right now.
    public static func mayShow(stored: SitePermissionPolicy, isPrivateOrAgent: Bool) -> Bool {
        !isPrivateOrAgent && stored == .allow
    }
}

/// Requests waiting on one open prompt per site.
public struct WebNotificationPrompts<Waiter> {
    private var waiting: [String: [Waiter]] = [:]

    public init() {}

    /// Queues `waiter` for `host`. True when it is the first, so the caller opens the prompt.
    public mutating func add(_ waiter: Waiter, for host: String) -> Bool {
        let first = waiting[host] == nil
        waiting[host, default: []].append(waiter)
        return first
    }

    /// Every waiter for `host`, in order; the site may prompt again afterwards.
    public mutating func resolve(_ host: String) -> [Waiter] {
        waiting.removeValue(forKey: host) ?? []
    }
}
