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
        // Emoji written with the emoji-style selector (U+FE0F) or as keycaps (U+20E3).
        for text in ["⌨️", "©️", "™️", "↩️", "ℹ️", "#️⃣", "1️⃣", "*️⃣"] {
            #expect(SpaceMark.emoji(from: text) == .emoji(text), "refused \(text)")
        }
        // The same characters without the selector are text, not emoji.
        #expect(SpaceMark.emoji(from: "©") == nil)
        #expect(SpaceMark.emoji(from: "#") == nil)
        #expect(SpaceMark.emoji(from: "a") == nil)
        // Digits carry the emoji property (keycaps) but are not emoji on their own.
        #expect(SpaceMark.emoji(from: "1") == nil)
        #expect(SpaceMark.emoji(from: "") == nil)
    }

    @Test func svgMustBeAnSVGSmallAndPlain() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/></svg>"#.utf8)
        #expect(SpaceMark.acceptsSVG(svg))
        let withHeader = Data(("<?xml version=\"1.0\"?>\n" + String(decoding: svg, as: UTF8.self)).utf8)
        #expect(SpaceMark.acceptsSVG(withHeader))
        #expect(!SpaceMark.acceptsSVG(Data("hello".utf8)))
        let huge = Data(("<svg>" + String(repeating: " ", count: SpaceMark.svgLimit) + "</svg>").utf8)
        #expect(!SpaceMark.acceptsSVG(huge))
        // Features that let a small file take seconds or gigabytes to draw, or reach outside it
        // (measured 2026-10-24: nested <use> 6.7 s / 1.8 GB, a blur filter never finished).
        for part in ["<use href=\"#a\"/>", "<filter id=\"f\"/>", "<image href=\"x.png\"/>", "<foreignObject/>", "<!ENTITY a \"b\">"] {
            let bad = Data("<svg xmlns=\"http://www.w3.org/2000/svg\">\(part)</svg>".utf8)
            #expect(!SpaceMark.acceptsSVG(bad), "accepted an SVG with \(part)")
        }
    }

    /// A kind of mark this build does not know (from a newer build) reads as no mark; the file
    /// must still load, or the person's tabs would be lost to a read-only session.
    @Test func unknownMarkKindReadsAsNone() throws {
        let json = ##"{"id":"\##(UUID().uuidString)","name":"New","icon":"square","accentHex":"#123456","order":"m","modifiedAt":0,"mark":{"sticker":{"_0":"x"}}}"##
        let decoded = try JSONDecoder().decode(SpaceRecord.self, from: Data(json.utf8))
        #expect(decoded.mark == nil)
        #expect(decoded.name == "New")
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
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        try f.tree.setSpaceMark(f.spaceA, mark: .emoji("🕌"), now: fixedNow)
        try f.tree.setSpaceMark(f.spaceB, mark: .picture(png), now: fixedNow)
        var device = DeviceState()
        device.firstLaunchCompleted = true
        let store = TabStore(directory: dir)
        store.save(f.tree, device)
        store.flush()
        let reloaded = TabStore(directory: dir).load(now: fixedNow).tree
        #expect(reloaded.space(f.spaceA)?.mark == .emoji("🕌"))
        #expect(reloaded.space(f.spaceB)?.mark == .picture(png))

        // A record written before marks existed decodes with none.
        let old = ##"{"id":"\##(UUID().uuidString)","name":"Old","icon":"square","accentHex":"#123456","order":"m","modifiedAt":0}"##
        let decoded = try JSONDecoder().decode(SpaceRecord.self, from: Data(old.utf8))
        #expect(decoded.mark == nil)
    }
}
