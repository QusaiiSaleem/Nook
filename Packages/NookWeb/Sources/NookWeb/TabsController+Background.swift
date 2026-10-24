// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+Background.swift
//  Nook
//
//  Pages that keep running with no window: a favorite or pinned tab whose site may notify, so
//  WhatsApp keeps its connection, its banners and its unread count while every window is closed.
//  Closing the tab itself still ends the page.
//

import Foundation
import NookSettings
import NookTabsCore

extension TabsController {
    /// Whether this item's page stays loaded when the last window showing it closes.
    public func keepsRunningOffscreen(_ itemID: UUID) -> Bool {
        guard case .main = owner(ofItem: itemID) else { return false }
        let url = session(for: itemID)?.url ?? device.openPages[itemID]?.url
        return WebNotificationPolicy.keepsRunning(
            isSynced: tree.scope(of: itemID) == .synced, url: url,
            stored: url?.host.map { settings.permission(.notifications, for: $0) } ?? .ask)
    }

    /// Items to start at launch: pages that were open at quit and keep running offscreen,
    /// favorites before pinned tabs, in sidebar order.
    public func backgroundLaunchItems() -> [UUID] {
        tree.orderedSpaces.flatMap { space in
            (tree.children(of: .favorites(spaceID: space.id)) + tree.children(of: .pinned(spaceID: space.id)))
                .map(\.id)
                .filter { device.openPages[$0] != nil && keepsRunningOffscreen($0) }
        }
    }
}
