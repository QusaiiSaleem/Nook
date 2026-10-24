// Licensed under GPL-3.0. See LICENSE.
//
//  SearchText.swift
//  Nook
//
//  The copy of a message the archive searches. SQLite's unicode61 tokenizer folds Latin accents
//  but keeps Arabic marks and letter variants, so "مرحبا" would miss "مَرْحَبًا" and "احمد" would
//  miss "أحمد". Queries go through the same function, so both sides match.
//

import Foundation

enum SearchText {
    static func normalize(_ text: String) -> String {
        // Folding drops Latin accents and splits hamza forms (أ إ آ ؤ ئ) into their base letter
        // plus a mark, which the filter below then removes.
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue      // tashkeel, superscript alef, tatweel
            case 0x0622, 0x0623, 0x0625, 0x0671: scalars.append("\u{0627}")   // آ أ إ ٱ → ا
            case 0x0649: scalars.append("\u{064A}")             // ى → ي
            case 0x0629: scalars.append("\u{0647}")             // ة → ه
            case 0x0624: scalars.append("\u{0648}")             // ؤ → و
            case 0x0626: scalars.append("\u{064A}")             // ئ → ي
            default: scalars.append(scalar)
            }
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
