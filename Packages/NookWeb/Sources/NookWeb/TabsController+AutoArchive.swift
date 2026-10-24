// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+AutoArchive.swift
//  Nook
//
//  Arc's auto-archive: Today tabs nobody looked at for 12 hours close on their own and are found
//  again in History (Qusai's choices). The rules are `AutoArchive` in NookTabsCore; this applies
//  them to the live app.
//

import Foundation
import NookTabsCore

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
import WebKit

extension TabsController {
    /// Closes Today tabs unseen for 12 hours and returns when the next one is due, or nil.
    @discardableResult
    public func archiveStaleTabs(now: Date = Date()) -> Date? {
        guard !isReadOnly else { return nil }
        let todayTabs = tree.items.values
            .filter { !$0.isFolder && $0.deletedAt == nil && tree.scope(of: $0.id) == .device }
            .map(\.id)
        // Tabs on screen are being looked at, and a tab with no record starts its clock now.
        let visible = todayTabs.filter(isOnScreen)
        setLastSeen(visible + todayTabs.filter { device.lastSeen?[$0] == nil }, at: now)

        let busy = sessions.filter { session in
            session.hasPlayingAudio || session.hasAudioContent || session.hasPiPActive
                || session.webView.map { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none } == true
        }.map(\.itemID)
        // Windows not reopened yet still show their tab.
        let keep = Set(visible + busy + [agentItemID].compactMap { $0 }).union(AutoArchive.shownBy(device.windows))
        let lastSeen = device.lastSeen ?? [:]
        let stale = AutoArchive.staleTabs(in: tree, lastSeen: lastSeen, now: now, keep: keep)
        if !stale.isEmpty {
            // Found again in History, also tabs that never loaded (opened in the background, imported).
            history?.importVisits(stale.compactMap { id in
                guard let url = session(for: id)?.url ?? tree.item(id)?.url, url.scheme == "https" || url.scheme == "http"
                else { return nil }
                let title = session(for: id)?.title.nilIfEmpty ?? tree.item(id)?.displayTitle ?? ""
                return HistoryVisit(url: url, title: title, timestamp: lastSeen[id] ?? now, tabId: id,
                                    profileId: tree.spaceID(of: id).flatMap { profile(forSpace: $0)?.id })
            })
            stale.forEach(archive)
        }
        return AutoArchive.nextDeadline(in: tree, lastSeen: device.lastSeen ?? [:], keep: keep)
    }
}
