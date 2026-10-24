// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Managers/MessageArchive/SearchText.swift scripts/tests/SearchTextCheck.swift -o /tmp/st && /tmp/st
//
//  The search copy of a message: Arabic matches without its marks or letter variants, which
//  SQLite's own unicode61 tokenizer does not do.

import Foundation

@main
struct SearchTextCheck {
    static func main() {
        precondition(SearchText.normalize("مَرْحَبًا") == SearchText.normalize("مرحبا"), "tashkeel is ignored")
        precondition(SearchText.normalize("أحمد") == "احمد", "alef with hamza is plain alef")
        precondition(SearchText.normalize("إلى") == "الي", "alef below and alef maqsura fold")
        precondition(SearchText.normalize("آمنة") == "امنه")
        precondition(SearchText.normalize("مدرسة") == SearchText.normalize("مدرسه"), "teh marbuta folds to heh")
        precondition(SearchText.normalize("ســـلام") == "سلام", "tatweel is dropped")
        precondition(SearchText.normalize("مسؤول") == "مسوول")
        precondition(SearchText.normalize("Café  PDF") == "cafe pdf", "Latin is folded and spaces collapse")
        precondition(SearchText.normalize("") == "")
        print("SearchTextCheck passed")
    }
}
