// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Saved splits: a folder marked with `Item.split` holding exactly two tabs, which the sidebar
/// draws as one row and a window shows side by side. Rules: a split holds two tabs and nothing
/// else, its tabs hold no children (no trails), it never sits in Favorites or inside a trail,
/// and it counts toward folder depth like any folder. A split left with one tab gives way to it.
extension TabTree {
    // MARK: - Lookup

    /// The split a tab sits in, if any.
    public func split(holding id: UUID) -> Item? {
        guard case .folder(let hostID)? = item(id)?.parent, let host = item(hostID), host.isSplit else { return nil }
        return host
    }

    /// A split's tabs, left then right; nil unless it holds exactly two.
    public func splitTabs(_ splitID: UUID) -> (left: Item, right: Item)? {
        guard item(splitID)?.isSplit == true else { return nil }
        let tabs = children(of: .folder(itemID: splitID))
        guard tabs.count == 2 else { return nil }
        return (tabs[0], tabs[1])
    }

    // MARK: - Changes

    /// Pairs two tabs as a split placed in `parent` right after `after` (nil = first). Each tab's
    /// trail children first move up into its place, since a split's tabs hold no children. A
    /// split the tabs were in before gives way to its remaining tab.
    @discardableResult
    public mutating func makeSplit(id: UUID = UUID(), left: UUID, right: UUID, in parent: Parent, after: UUID?, info: SplitInfo = SplitInfo(), now: Date = Date()) throws -> Change {
        guard left != right, let leftItem = item(left), let rightItem = item(right),
              !leftItem.isFolder, !rightItem.isFolder else { throw TreeError.splitHoldsTabsOnly }
        for tab in [left, right] {
            if case .favorites? = section(of: tab) { throw TreeError.folderInFavorites }
        }
        try validate(parent: parent, placing: nil, isFolder: true)
        let previousSplits = Set([left, right].compactMap { split(holding: $0)?.id })
        var change = Change()
        for tab in [left, right] { promoteChildren(of: tab, change: &change, now: now) }
        let order = placeKey(in: parent, after: after, excluding: id, change: &change, now: now)
        record(&change, item: Item(id: id, parent: parent, order: order, kind: .folder, modifiedAt: now, split: info.clamped()))
        place(left, in: .folder(itemID: id), after: nil, change: &change, now: now)
        place(right, in: .folder(itemID: id), after: left, change: &change, now: now)
        for previous in previousSplits { collapseSplit(previous, change: &change, now: now) }
        return change
    }

    /// An empty split for an importer to fill with two tabs right away (`createTab` into it).
    @discardableResult
    public mutating func createSplit(id: UUID = UUID(), in parent: Parent, after: UUID?, info: SplitInfo = SplitInfo(), now: Date = Date()) throws -> Change {
        try validate(parent: parent, placing: nil, isFolder: true)
        var change = Change()
        let order = placeKey(in: parent, after: after, excluding: id, change: &change, now: now)
        record(&change, item: Item(id: id, parent: parent, order: order, kind: .folder, modifiedAt: now, split: info.clamped()))
        return change
    }

    /// Ends a split: its tabs take its place, left then right, and the split record goes.
    @discardableResult
    public mutating func separateSplit(_ splitID: UUID, now: Date = Date()) throws -> Change {
        guard let split = item(splitID), split.isSplit else { throw TreeError.missingItem }
        var change = Change()
        var after = splitID
        for tab in children(of: .folder(itemID: splitID)) {
            place(tab.id, in: split.parent, after: after, change: &change, now: now)
            after = tab.id
        }
        remove(&change, itemID: splitID, now: now)
        return change
    }

    /// Swaps one of a split's tabs for another: `old` leaves to sit right after the split,
    /// `new` takes its side.
    @discardableResult
    public mutating func replaceInSplit(_ splitID: UUID, replacing old: UUID, with new: UUID, now: Date = Date()) throws -> Change {
        guard let host = item(splitID), host.isSplit, split(holding: old)?.id == splitID,
              let incoming = item(new), !incoming.isFolder, new != old else { throw TreeError.missingItem }
        if case .favorites? = section(of: new) { throw TreeError.folderInFavorites }
        let tabs = children(of: .folder(itemID: splitID)).map(\.id)
        let previousSplit = split(holding: new)?.id
        var change = Change()
        promoteChildren(of: new, change: &change, now: now)
        place(old, in: host.parent, after: splitID, change: &change, now: now)
        place(new, in: .folder(itemID: splitID), after: tabs.first == old ? nil : tabs.first, change: &change, now: now)
        if let previousSplit, previousSplit != splitID { collapseSplit(previousSplit, change: &change, now: now) }
        return change
    }

    /// Stores a split's divider position (clamped) and focused side.
    @discardableResult
    public mutating func setSplitInfo(_ splitID: UUID, _ info: SplitInfo, now: Date = Date()) throws -> Change {
        guard var split = item(splitID), split.isSplit else { throw TreeError.missingItem }
        var change = Change()
        split.split = info.clamped()
        split.modifiedAt = now
        record(&change, item: split)
        return change
    }

    // MARK: - Rules

    /// What a split accepts: a tab, while it holds fewer than two others.
    func validateSplitChild(of splitID: UUID, placing id: UUID?, isFolder: Bool) throws {
        if isFolder { throw TreeError.splitHoldsTabsOnly }
        if children(of: .folder(itemID: splitID)).filter({ $0.id != id }).count >= 2 { throw TreeError.splitFull }
    }

    /// A split left with fewer than two tabs gives way: its remaining tab takes its place.
    mutating func collapseSplit(_ splitID: UUID, change: inout Change, now: Date) {
        guard let split = item(splitID), split.isSplit else { return }
        let tabs = children(of: .folder(itemID: splitID))
        guard tabs.count < 2 else { return }
        if let only = tabs.first { place(only.id, in: split.parent, after: splitID, change: &change, now: now) }
        remove(&change, itemID: splitID, now: now)
    }

    /// Repairs splits a file brought in broken: anything past the first two tabs (and any folder)
    /// moves out to sit right after the split, a tab's trail children move up beside it, and a
    /// split with fewer than two tabs gives way. Returns true when anything changed.
    mutating func repairSplits(now: Date) -> Bool {
        var change = Change()
        for split in items.values where split.deletedAt == nil && split.isSplit {
            var after = split.id
            var kept = 0
            for child in children(of: .folder(itemID: split.id)) {
                if !child.isFolder, kept < 2 {
                    kept += 1
                    promoteChildren(of: child.id, change: &change, now: now)
                    continue
                }
                place(child.id, in: split.parent, after: after, change: &change, now: now)
                after = child.id
            }
            collapseSplit(split.id, change: &change, now: now)
        }
        return !change.isEmpty
    }

    /// Moves one record under `parent` after `after`, without the checks `move` makes; callers
    /// here have already made them.
    private mutating func place(_ id: UUID, in parent: Parent, after: UUID?, change: inout Change, now: Date) {
        guard var moving = items[id] else { return }
        moving.order = placeKey(in: parent, after: after, excluding: id, change: &change, now: now)
        moving.parent = parent
        moving.modifiedAt = now
        record(&change, item: moving)
    }
}
