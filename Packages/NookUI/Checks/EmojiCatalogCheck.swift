// Licensed under GPL-3.0. See LICENSE.
//
//  EmojiCatalogCheck.swift
//  Nook
//
//  The space mark picker's emoji: faces first, searchable by name, no half-flags or skin tone
//  swatches, and every one accepted as a mark. NookUI has no test target, so this compiles the
//  sources (NookTabsCore for `SpaceMark`):
//
//    swiftc -parse-as-library Packages/NookTabsCore/Sources/NookTabsCore/*.swift \
//           Packages/NookUI/Sources/NookUI/Settings/EmojiCatalog.swift \
//           Packages/NookUI/Checks/EmojiCatalogCheck.swift -o /tmp/ec && /tmp/ec
//

import Foundation

@main
struct EmojiCatalogCheck {
    static func main() {
        let all = EmojiCatalog.all
        precondition(all.count > 1000, "only \(all.count) emoji")
        precondition(all.first?.emoji == "😀", "first is \(all.first?.emoji ?? "nothing"), not a face")
        precondition(Set(all.map(\.emoji)).count == all.count, "an emoji is listed twice")
        for missing in ["🚀", "🍕", "🐱", "❤️", "☀️", "✈️", "⭐", "🟢", "🫠"] {
            precondition(all.contains { $0.emoji == missing }, "\(missing) is missing")
        }
        for unwanted in ["🏽", "🇦", "©", "#"] {
            precondition(!all.contains { $0.emoji == unwanted }, "\(unwanted) is listed")
        }
        for entry in all {
            precondition(SpaceMark.emoji(from: entry.emoji) == .emoji(entry.emoji), "\(entry.emoji) is refused as a mark")
        }

        precondition(EmojiCatalog.matching("rocket").map(\.emoji) == ["🚀"], "rocket finds \(EmojiCatalog.matching("rocket").map(\.emoji))")
        precondition(EmojiCatalog.matching("  GRINNING face ").first?.emoji == "😀", "search ignores case and spaces")
        precondition(EmojiCatalog.matching("cat face").contains { $0.emoji == "🐱" }, "words in any position")
        precondition(EmojiCatalog.matching("zzqqxx").isEmpty, "nonsense matches")
        precondition(EmojiCatalog.matching("").count == all.count, "an empty search hides emoji")
        print("EmojiCatalogCheck passed: \(all.count) emoji")
    }
}
