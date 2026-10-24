// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

struct SpaceMarkTests {
    @Test func emojiIsTheFirstEmojiCharacter() {
        #expect(SpaceMark.emoji(from: "🕌") == .emoji("🕌"))
        #expect(SpaceMark.emoji(from: " 🕌 mosque") == .emoji("🕌"))
        // A flag and a family are one character each, made of several code points.
        #expect(SpaceMark.emoji(from: "🇯🇴") == .emoji("🇯🇴"))
        #expect(SpaceMark.emoji(from: "👨‍👩‍👧") == .emoji("👨‍👩‍👧"))
        #expect(SpaceMark.emoji(from: "a") == nil)
        // Digits carry the emoji property (keycaps) but are not emoji on their own.
        #expect(SpaceMark.emoji(from: "1") == nil)
        #expect(SpaceMark.emoji(from: "") == nil)
    }

    @Test func svgMustBeAnSVGAndSmall() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/></svg>"#.utf8)
        #expect(SpaceMark.svg(from: svg) == .svg(svg))
        let withHeader = Data(("<?xml version=\"1.0\"?>\n" + String(decoding: svg, as: UTF8.self)).utf8)
        #expect(SpaceMark.svg(from: withHeader) == .svg(withHeader))
        #expect(SpaceMark.svg(from: Data("hello".utf8)) == nil)
        let huge = Data(("<svg>" + String(repeating: " ", count: SpaceMark.svgLimit) + "</svg>").utf8)
        #expect(SpaceMark.svg(from: huge) == nil)
    }

    @Test func setClearAndUndo() throws {
        var f = Fixture()
        let undoSet = try f.tree.setSpaceMark(f.spaceA, mark: .emoji("🕌"), now: fixedNow)
        #expect(f.tree.space(f.spaceA)?.mark == .emoji("🕌"))
        #expect(f.tree.space(f.spaceB)?.mark == nil)

        let undoClear = try f.tree.setSpaceMark(f.spaceA, mark: nil, now: fixedNow)
        #expect(f.tree.space(f.spaceA)?.mark == nil)
        f.tree.apply(undoClear)
        #expect(f.tree.space(f.spaceA)?.mark == .emoji("🕌"))
        f.tree.apply(undoSet)
        #expect(f.tree.space(f.spaceA)?.mark == nil)

        // Setting the same mark again changes nothing.
        try f.tree.setSpaceMark(f.spaceB, mark: .emoji("📚"), now: fixedNow)
        #expect(try f.tree.setSpaceMark(f.spaceB, mark: .emoji("📚"), now: fixedNow).isEmpty)
        checkInvariants(f.tree)
    }

    @Test func survivesSaveAndLoadAndOldFilesHaveNone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceMarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var f = Fixture()
        let svg = Data(#"<svg viewBox="0 0 1 1"/>"#.utf8)
        try f.tree.setSpaceMark(f.spaceA, mark: .emoji("🕌"), now: fixedNow)
        try f.tree.setSpaceMark(f.spaceB, mark: .svg(svg), now: fixedNow)
        var device = DeviceState()
        device.firstLaunchCompleted = true
        let store = TabStore(directory: dir)
        store.save(f.tree, device)
        store.flush()
        let reloaded = TabStore(directory: dir).load(now: fixedNow).tree
        #expect(reloaded.space(f.spaceA)?.mark == .emoji("🕌"))
        #expect(reloaded.space(f.spaceB)?.mark == .svg(svg))

        // A record written before marks existed decodes with none.
        let old = ##"{"id":"\##(UUID().uuidString)","name":"Old","icon":"square","accentHex":"#123456","order":"m","modifiedAt":0}"##
        let decoded = try JSONDecoder().decode(SpaceRecord.self, from: Data(old.utf8))
        #expect(decoded.mark == nil)
    }
}
