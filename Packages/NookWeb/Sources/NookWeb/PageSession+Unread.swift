// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Unread.swift
//  Nook
//
//  Unread counts read from page titles (`UnreadCount`). `title` is observed, so views showing a
//  count update as the site changes its title.
//

import Foundation

extension PageSession {
    /// The unread count in this page's title, or nil. An unloaded page keeps its last title, so
    /// it has no count.
    public var unreadCount: Int? { isUnloaded ? nil : UnreadCount.parse(title) }
}

extension PageSession {
    /// The person pressed a key in this page; cleared when the next page commits.
    public func noteTyping() { hasTypedSinceLoad = true }
}

extension TabsController {
    /// Whether a favorite or pinned page in this space shows an unread count. Tabs in the tabs
    /// section do not count: any site may put "(1)" in a title.
    public func spaceHasUnread(_ spaceID: UUID) -> Bool {
        sessions.contains { session in
            !session.isPrivate && session.unreadCount != nil
                && tree.spaceID(of: session.itemID) == spaceID && tree.scope(of: session.itemID) == .synced
        }
    }

    /// The unread total across WhatsApp pages, for the Dock.
    public var whatsAppUnreadTotal: Int {
        sessions.reduce(0) { total, session in
            guard session.url.host?.lowercased() == "web.whatsapp.com", !session.isPrivate, !session.isAgentPage
            else { return total }
            return total + (session.unreadCount ?? 0)
        }
    }
}
