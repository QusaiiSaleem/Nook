// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Saved splits: a folder marked `split` holding exactly two tabs, shown as one sidebar row.
struct SplitTests {
    @Test func makeSplitPlacesPairAtTarget() throws {
        var f = Fixture()
        let pinned = Parent.pinned(spaceID: f.spaceA)
        let a = f.tab("a", in: pinned), b = f.tab("b", in: pinned), c = f.tab("c", in: pinned)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: b, right: c, in: pinned, after: a, info: SplitInfo(fraction: 0.6, focusRight: true), now: fixedNow)
        #expect(f.tree.children(of: pinned).map(\.id) == [a, split])
        #expect(f.tree.children(of: .folder(itemID: split)).map(\.id) == [b, c])
        #expect(f.tree.item(split)?.isSplit == true)
        #expect(f.tree.item(split)?.split == SplitInfo(fraction: 0.6, focusRight: true))
        #expect(f.tree.split(holding: c)?.id == split)
        #expect(f.tree.split(holding: a) == nil)
        #expect(f.tree.splitTabs(split)?.left.id == b)
        #expect(f.tree.splitTabs(split)?.right.id == c)
        checkInvariants(f.tree)
    }

    @Test func favoritesCannotBeSplit() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let favorite = f.tab("fav", in: .favorites(spaceID: f.spaceA))
        let t = f.tab("t", in: tabs)
        #expect(throws: TreeError.folderInFavorites) {
            try f.tree.makeSplit(left: t, right: favorite, in: tabs, after: nil, now: fixedNow)
        }
        let a = f.tab("a", in: tabs), b = f.tab("b", in: tabs)
        #expect(throws: TreeError.folderInFavorites) {
            try f.tree.makeSplit(left: a, right: b, in: .favorites(spaceID: f.spaceA), after: nil, now: fixedNow)
        }
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: nil, now: fixedNow)
        #expect(throws: TreeError.folderInFavorites) {
            try f.tree.move(split, to: .favorites(spaceID: f.spaceA), after: nil, now: fixedNow)
        }
        #expect(f.tree.favorites(of: f.spaceA).map(\.id) == [favorite])
        checkInvariants(f.tree)
    }

    @Test func splitHoldsTwoTabsOnly() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let a = f.tab("a", in: tabs), b = f.tab("b", in: tabs), c = f.tab("c", in: tabs)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: nil, now: fixedNow)
        #expect(throws: TreeError.splitFull) {
            try f.tree.move(c, to: .folder(itemID: split), after: nil, now: fixedNow)
        }
        #expect(throws: TreeError.splitHoldsTabsOnly) {
            try f.tree.createFolder(title: "x", in: .folder(itemID: split), after: nil, now: fixedNow)
        }
        // A split's tabs hold no children, so a link opened from a pane is not a trail child.
        #expect(throws: TreeError.childInSplit) {
            try f.tree.createTab(url: url("x"), title: "x", in: .folder(itemID: a), after: nil, now: fixedNow)
        }
        #expect(!f.tree.canTakeChild(a))
        #expect(throws: TreeError.splitHoldsTabsOnly) {
            try f.tree.makeSplit(left: c, right: c, in: tabs, after: nil, now: fixedNow)
        }
        // Swapping sides inside the split is a move within it.
        try f.tree.move(b, to: .folder(itemID: split), after: nil, now: fixedNow)
        #expect(f.tree.children(of: .folder(itemID: split)).map(\.id) == [b, a])
        checkInvariants(f.tree)
    }

    @Test func splitsStayOutOfTrails() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let parent = f.tab("parent", in: tabs)
        let child = f.tab("child", in: .folder(itemID: parent))
        let other = f.tab("other", in: tabs)
        #expect(throws: TreeError.folderInTab) {
            try f.tree.makeSplit(left: child, right: other, in: .folder(itemID: parent), after: nil, now: fixedNow)
        }
        // A tab's trail children move up into its place before it joins a split.
        let split = UUID()
        try f.tree.makeSplit(id: split, left: parent, right: other, in: tabs, after: nil, now: fixedNow)
        #expect(f.tree.children(of: tabs).map(\.id) == [split, child])
        #expect(f.tree.item(child)?.parent == tabs)
        checkInvariants(f.tree)
    }

    @Test func separateRestoresOrder() throws {
        var f = Fixture()
        let pinned = Parent.pinned(spaceID: f.spaceA)
        let a = f.tab("a", in: pinned), b = f.tab("b", in: pinned), c = f.tab("c", in: pinned), d = f.tab("d", in: pinned)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: b, right: c, in: pinned, after: a, now: fixedNow)
        let change = try f.tree.separateSplit(split, now: fixedNow)
        #expect(f.tree.children(of: pinned).map(\.id) == [a, b, c, d])
        #expect(f.tree.item(split) == nil)
        // One undo step brings the split back.
        _ = f.tree.apply(change)
        #expect(f.tree.children(of: pinned).map(\.id) == [a, split, d])
        #expect(f.tree.children(of: .folder(itemID: split)).map(\.id) == [b, c])
        checkInvariants(f.tree)
    }

    @Test func closingAHalfInTabsLeavesTheOther() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let x = f.tab("x", in: tabs), a = f.tab("a", in: tabs), b = f.tab("b", in: tabs), y = f.tab("y", in: tabs)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: x, now: fixedNow)
        #expect(f.tree.children(of: tabs).map(\.id) == [x, split, y])
        _ = try f.tree.close(b, now: fixedNow)
        #expect(f.tree.children(of: tabs).map(\.id) == [x, a, y])
        #expect(f.tree.item(split) == nil)
        checkInvariants(f.tree)
    }

    @Test func movingAHalfOutCollapses() throws {
        var f = Fixture()
        let pinned = Parent.pinned(spaceID: f.spaceA)
        let a = f.tab("a", in: pinned), b = f.tab("b", in: pinned), c = f.tab("c", in: pinned)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: pinned, after: nil, now: fixedNow)
        try f.tree.move(a, to: .pinned(spaceID: f.spaceB), after: nil, now: fixedNow)
        #expect(f.tree.children(of: pinned).map(\.id) == [b, c])
        #expect(f.tree.item(split) == nil)
        #expect(f.tree.children(of: .pinned(spaceID: f.spaceB)).map(\.id) == [a])
        checkInvariants(f.tree)
    }

    @Test func splitIsOneRow() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let x = f.tab("x", in: tabs), a = f.tab("a", in: tabs), b = f.tab("b", in: tabs)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: x, now: fixedNow)
        // Its tabs never show as rows of their own, even when its id is in the open set.
        let rows = f.tree.visibleRows(space: f.spaceA, openFolders: [split])
        #expect(rows.map(\.item.id) == [x, split])
        #expect(rows.last?.hasChildren == false)
    }

    @Test func noDropIntoSplit() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let a = f.tab("a", in: tabs), b = f.tab("b", in: tabs), other = f.tab("other", in: tabs)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: nil, now: fixedNow)
        let rows = f.tree.visibleRows(space: f.spaceA, openFolders: [])
        let index = try #require(rows.firstIndex { $0.id == split })
        let target = f.tree.dropTarget(section: tabs, rows: rows, index: index, intoFolder: true, dragged: other)
        #expect(target.parent == tabs)
        #expect(target.after == nil)
    }

    @Test func setSplitInfoClamps() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let a = f.tab("a", in: tabs), b = f.tab("b", in: tabs)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: nil, now: fixedNow)
        try f.tree.setSplitInfo(split, SplitInfo(fraction: 0.9, focusRight: true), now: fixedNow)
        #expect(f.tree.item(split)?.split == SplitInfo(fraction: 0.75, focusRight: true))
        #expect(SplitInfo(fraction: 0.1).clamped().fraction == SplitInfo.minFraction)
        #expect(throws: TreeError.missingItem) { try f.tree.setSplitInfo(a, SplitInfo(), now: fixedNow) }
    }

    @Test func repairNormalizesSplits() throws {
        var f = Fixture()
        let pinned = Parent.pinned(spaceID: f.spaceA)
        let a = f.tab("a", in: pinned), b = f.tab("b", in: pinned)
        let c = f.tab("c", in: pinned), d = f.tab("d", in: pinned), e = f.tab("e", in: pinned)
        let lone = UUID(), crowded = UUID()
        try f.tree.makeSplit(id: lone, left: a, right: b, in: pinned, after: nil, now: fixedNow)
        try f.tree.makeSplit(id: crowded, left: c, right: d, in: pinned, after: lone, now: fixedNow)
        // As a file from a sync or a crash could have them: one split lost a tab, one gained one.
        f.tree.items[b] = nil
        f.tree.items[e]?.parent = .folder(itemID: crowded)
        let lastKey = try #require(OrderKey.between(f.tree.item(d)?.order, nil))
        f.tree.items[e]?.order = lastKey
        let repaired = f.tree.repair(now: fixedNow)
        #expect(repaired)
        #expect(f.tree.item(lone) == nil)
        #expect(f.tree.children(of: pinned).map(\.id) == [a, crowded, e])
        #expect(f.tree.children(of: .folder(itemID: crowded)).map(\.id) == [c, d])
        let repairedAgain = f.tree.repair(now: fixedNow)
        #expect(!repairedAgain)
        checkInvariants(f.tree)
    }

    @Test func splitSurvivesEncodeDecode() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let a = f.tab("a", in: tabs), b = f.tab("b", in: tabs)
        let split = UUID()
        try f.tree.makeSplit(id: split, left: a, right: b, in: tabs, after: nil, info: SplitInfo(fraction: 0.4, focusRight: true), now: fixedNow)
        let back = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(try #require(f.tree.item(split))))
        #expect(back.split == SplitInfo(fraction: 0.4, focusRight: true))
        // A tab writes no split key, so files without splits are byte-for-byte what older builds write.
        let plain = try JSONEncoder().encode(try #require(f.tree.item(a)))
        #expect(String(decoding: plain, as: UTF8.self).contains("split") == false)
        #expect(try JSONDecoder().decode(Item.self, from: plain).split == nil)
    }
}
