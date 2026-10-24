// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Today tabs unseen for 12 hours close on their own (Qusai: 12 hours, archived tabs just close).
struct AutoArchiveTests {
    let hours: TimeInterval = 60 * 60

    @Test func todayTabUnseenFor12HoursIsStale() {
        var f = Fixture()
        let old = f.tab("old", in: .tabs(spaceID: f.spaceA))
        let fresh = f.tab("fresh", in: .tabs(spaceID: f.spaceA))
        let seen = [old: fixedNow.addingTimeInterval(-13 * hours), fresh: fixedNow.addingTimeInterval(-1 * hours)]
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: seen, now: fixedNow, keep: []) == [old])
    }

    @Test func pinnedAndFavoritesNeverArchive() {
        var f = Fixture()
        let pinned = f.tab("pinned", in: .pinned(spaceID: f.spaceA))
        let favorite = f.tab("favorite", in: .favorites(spaceID: f.spaceA))
        let long = fixedNow.addingTimeInterval(-100 * hours)
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: [pinned: long, favorite: long], now: fixedNow, keep: []).isEmpty)
    }

    @Test func aTabWithNoRecordIsNotStale() {
        var f = Fixture()
        f.tab("unknown", in: .tabs(spaceID: f.spaceA))
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: [:], now: fixedNow, keep: []).isEmpty)
    }

    @Test func keptTabsStay() {
        var f = Fixture()
        let playing = f.tab("playing", in: .tabs(spaceID: f.spaceA))
        let seen = [playing: fixedNow.addingTimeInterval(-20 * hours)]
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: seen, now: fixedNow, keep: [playing]).isEmpty)
    }

    @Test func splitTabsStay() throws {
        var f = Fixture()
        let a = f.tab("a", in: .tabs(spaceID: f.spaceA))
        let b = f.tab("b", in: .tabs(spaceID: f.spaceA))
        _ = try f.tree.makeSplit(left: a, right: b, in: .tabs(spaceID: f.spaceA), after: nil, now: fixedNow)
        let long = fixedNow.addingTimeInterval(-30 * hours)
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: [a: long, b: long], now: fixedNow, keep: []).isEmpty)
    }

    @Test func agentSpaceTabsStay() throws {
        var f = Fixture()
        let created = f.tree.ensureAgentSpace(loginsFrom: f.spaceA, now: fixedNow)
        let agent = try #require(created).id
        let tab = f.tab("agent page", in: .tabs(spaceID: agent))
        let seen = [tab: fixedNow.addingTimeInterval(-30 * hours)]
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: seen, now: fixedNow, keep: []).isEmpty)
    }

    @Test func trailChildrenCountOnTheirOwn() throws {
        var f = Fixture()
        let parent = f.tab("parent", in: .tabs(spaceID: f.spaceA))
        let child = f.tab("child", in: .folder(itemID: parent))
        let seen = [parent: fixedNow.addingTimeInterval(-1 * hours), child: fixedNow.addingTimeInterval(-13 * hours)]
        #expect(AutoArchive.staleTabs(in: f.tree, lastSeen: seen, now: fixedNow, keep: []) == [child])
    }

    @Test func nextDeadlineIsTheEarliestExpiry() {
        var f = Fixture()
        let a = f.tab("a", in: .tabs(spaceID: f.spaceA))
        let b = f.tab("b", in: .tabs(spaceID: f.spaceA))
        let seen = [a: fixedNow.addingTimeInterval(-2 * hours), b: fixedNow.addingTimeInterval(-5 * hours)]
        #expect(AutoArchive.nextDeadline(in: f.tree, lastSeen: seen, keep: []) == fixedNow.addingTimeInterval(7 * hours))
        #expect(AutoArchive.nextDeadline(in: f.tree, lastSeen: [:], keep: []) == nil)
    }

    @Test func lastSeenSurvivesSavingAndOlderFilesLoad() throws {
        var device = DeviceState()
        let id = UUID()
        device.lastSeen = [id: fixedNow]
        let decoded = try JSONDecoder().decode(DeviceState.self, from: JSONEncoder().encode(device))
        #expect(decoded.lastSeen?[id] == fixedNow)
        let older = try JSONDecoder().decode(DeviceState.self, from: JSONEncoder().encode(DeviceState()))
        #expect(older.lastSeen == nil)
    }
}
