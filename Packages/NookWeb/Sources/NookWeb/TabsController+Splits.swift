// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

/// Saved splits (Arc-style): intents over `TabTree+Splits`. A window shows a split by pairing its
/// tabs in `BrowserWindowState.split`; selecting the split or either of its tabs pairs them.
extension TabsController {
    // MARK: - Reads

    public func split(holding itemID: UUID) -> Item? {
        owner(ofItem: itemID).flatMap { tree($0).split(holding: itemID) }
    }

    public func splitTabs(_ splitID: UUID) -> (left: Item, right: Item)? {
        owner(ofItem: splitID).flatMap { tree($0).splitTabs(splitID) }
    }

    // MARK: - Intents

    /// Pairs `left` and `right` as a saved split where `target` is (below the top tab of its trail
    /// when it is a trail child, beside its split when it is in one). Nil when either tab is a
    /// favorite, which stays in its grid while the caller shows a window-only split.
    @discardableResult
    public func makeSplit(left: UUID, right: UUID, at target: UUID, info: SplitInfo = SplitInfo()) -> UUID? {
        guard let owner = owner(ofItem: target) else { return nil }
        let source = tree(owner)
        let isFavorite = { (id: UUID) -> Bool in
            if case .favorites? = source.section(of: id) { return true }
            return false
        }
        guard !isFavorite(left), !isFavorite(right), let placement = splitPlacement(for: target, in: source) else { return nil }
        let id = UUID()
        guard perform(owner, "makeSplit", {
            try $0.makeSplit(id: id, left: left, right: right, in: placement.parent, after: placement.after, info: info)
        }) != nil else { return nil }
        return id
    }

    /// Ends a split; its tabs take its place.
    public func separateSplit(_ splitID: UUID) {
        guard let owner = owner(ofItem: splitID) else { return }
        perform(owner, "separateSplit") { try $0.separateSplit(splitID) }
    }

    /// Swaps `old` out of its split for `new`; `old` sits right after the split.
    @discardableResult
    public func replaceInSplit(_ splitID: UUID, replacing old: UUID, with new: UUID) -> Bool {
        guard let owner = owner(ofItem: splitID) else { return false }
        return perform(owner, "replaceInSplit") { try $0.replaceInSplit(splitID, replacing: old, with: new) } != nil
    }

    /// Stores a split's divider position and focused side. Not an undo step.
    public func setSplitLayout(_ splitID: UUID, fraction: Double? = nil, focusRight: Bool? = nil) {
        guard let owner = owner(ofItem: splitID), let current = tree(owner).item(splitID)?.split else { return }
        let next = SplitInfo(fraction: fraction ?? current.fraction, focusRight: focusRight ?? current.focusRight).clamped()
        guard next != current else { return }
        perform(owner, "setSplitLayout", undoable: false) { try $0.setSplitInfo(splitID, next) }
    }

    /// For importers: an empty split to fill with two `importTab` calls right away.
    public func createSplit(in parent: Parent, after: UUID?, info: SplitInfo) -> UUID? {
        let owner: TabsController.Owner?
        switch parent {
        case .favorites(let spaceID), .pinned(let spaceID), .tabs(let spaceID): owner = self.owner(ofSpace: spaceID)
        case .folder(let folderID): owner = self.owner(ofItem: folderID)
        }
        guard let owner else { return nil }
        let id = UUID()
        guard perform(owner, "createSplit", { try $0.createSplit(id: id, in: parent, after: after, info: info) }) != nil else { return nil }
        return id
    }

    // MARK: - Windows

    /// The tab to show for a split: the side it was last used on.
    func focusedTab(ofSplit splitID: UUID, in source: TabTree) -> UUID? {
        guard let pair = source.splitTabs(splitID) else { return nil }
        return source.item(splitID)?.split?.focusRight == true ? pair.right.id : pair.left.id
    }

    /// A window selecting a split's tab shows the pair, and the split remembers that side.
    func pairWindowWithSplit(_ itemID: UUID, in window: BrowserWindowState, source: TabTree) {
        guard let host = source.split(holding: itemID), let info = host.split, let pair = source.splitTabs(host.id) else { return }
        let record = SplitRecord(leftItemID: pair.left.id, rightItemID: pair.right.id, fraction: info.fraction)
        if window.split != record { window.split = record }
        setSplitLayout(host.id, focusRight: itemID == pair.right.id)
    }

    // MARK: - Placement

    /// Where a new split goes so it takes `target`'s place. Splits stay out of trails, so a trail
    /// child's split goes right below the top tab of its trail.
    private func splitPlacement(for target: UUID, in source: TabTree) -> (parent: Parent, after: UUID?)? {
        guard let item = source.item(target) else { return nil }
        if let host = source.split(holding: target) { return (host.parent, host.id) }
        if source.trailParent(of: target) != nil {
            var top = target
            while let up = source.trailParent(of: top) { top = up }
            guard let topItem = source.item(top) else { return nil }
            return (topItem.parent, top)
        }
        let siblings = source.children(of: item.parent)
        let index = siblings.firstIndex { $0.id == target } ?? 0
        return (item.parent, index > 0 ? siblings[index - 1].id : nil)
    }
}
