// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Arc's auto-archive: a tab in a space's Today section that nobody has looked at for 12 hours
/// closes on its own (Qusai's choice: it is found again in History). Favorites, pinned tabs,
/// split tabs and the Agent space never archive; the caller keeps whatever must stay (tabs on
/// screen, playing audio, picture-in-picture, capture).
public enum AutoArchive {
    public static let maxAge: TimeInterval = 12 * 60 * 60

    /// Tabs to close now, oldest first. A tab with no record is not stale: its clock starts when
    /// it is first recorded.
    public static func staleTabs(in tree: TabTree, lastSeen: [UUID: Date], now: Date, keep: Set<UUID>) -> [UUID] {
        candidates(in: tree, lastSeen: lastSeen, keep: keep)
            .filter { now.timeIntervalSince($0.seen) >= maxAge }
            .sorted { $0.seen < $1.seen }
            .map(\.id)
    }

    /// Tabs saved window records show: the selection in each record's space and its split pair.
    /// Windows reopened after launch must not find their tab archived.
    public static func shownBy(_ windows: [WindowRecord]) -> Set<UUID> {
        var shown = Set<UUID>()
        for window in windows {
            if let space = window.spaceID, let selected = window.selectedItemBySpace[space] { shown.insert(selected) }
            if let split = window.split { shown.formUnion([split.leftItemID, split.rightItemID]) }
        }
        return shown
    }

    /// When the next tab becomes stale, so one timer can wait for it.
    public static func nextDeadline(in tree: TabTree, lastSeen: [UUID: Date], keep: Set<UUID>) -> Date? {
        candidates(in: tree, lastSeen: lastSeen, keep: keep).map { $0.seen.addingTimeInterval(maxAge) }.min()
    }

    /// Tabs that may archive, with their last-seen time.
    public static func candidates(in tree: TabTree, lastSeen: [UUID: Date], keep: Set<UUID>) -> [(id: UUID, seen: Date)] {
        let agent = tree.agentSpace?.id
        return lastSeen.compactMap { id, seen in
            guard !keep.contains(id), let item = tree.item(id), item.deletedAt == nil, !item.isFolder,
                  case .tabs(let spaceID)? = tree.section(of: id), spaceID != agent,
                  tree.split(holding: id) == nil else { return nil }
            return (id, seen)
        }
    }
}
