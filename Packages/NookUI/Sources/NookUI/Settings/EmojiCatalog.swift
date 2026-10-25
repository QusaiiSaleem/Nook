// Licensed under GPL-3.0. See LICENSE.
//
//  EmojiCatalog.swift
//  Nook
//
//  The emoji the space mark picker offers: every single-scalar emoji the system emoji font draws,
//  in emoji style (U+FE0F added where text style is the default: ❤️ ☀️ ✈️), faces first, each
//  with its Unicode name for search. Read
//  from the system's Unicode data, so there is no list to keep up to date. Flags, skin tones and
//  joined sequences are left out; typing or pasting one in the picker's field still works.
//

import CoreText
import Foundation

enum EmojiCatalog {
    struct Entry: Hashable, Identifiable {
        let emoji: String
        /// Lowercased Unicode name, "grinning face".
        let name: String
        var id: String { emoji }
    }

    /// Unicode blocks in the order the grid shows them.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, // faces
        0x1F900...0x1F9FF, // more faces, people, animals, food
        0x1F300...0x1F5FF, // weather, plants, food, places, objects
        0x1F680...0x1F6FF, // transport and map
        0x1FA70...0x1FAFF, // newer objects
        0x1FA00...0x1FA6F, // chess and games
        0x1F700...0x1F8FF, // coloured shapes
        0x2000...0x2BFF,   // symbols
        0x1F000...0x1F2FF, // cards and enclosed letters
    ]

    static let all: [Entry] = {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        return blocks.flatMap { $0 }.compactMap { value in
            guard let scalar = Unicode.Scalar(value) else { return nil }
            let properties = scalar.properties
            // Regional indicators are half a flag on their own; modifiers are skin tone swatches.
            guard properties.isEmoji, !properties.isEmojiModifier,
                  !(0x1F1E6...0x1F1FF).contains(value), let name = properties.name else { return nil }
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return nil }
            let emoji = properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
            return Entry(emoji: emoji, name: name.lowercased())
        }
    }()

    /// Entries whose name holds every word of `query`; all of them for an empty query.
    static func matching(_ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return all }
        return all.filter { entry in words.allSatisfy { entry.name.contains($0) } }
    }
}
