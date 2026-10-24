// Licensed under GPL-3.0. See LICENSE.
//
//  UnreadCount.swift
//  Nook
//
//  Messaging sites put their unread count in the page title: WhatsApp, Telegram and X lead with
//  "(3) ", Gmail writes "Inbox (3)". Reading it from the title needs no script on the page.
//

import Foundation

public enum UnreadCount {
    /// The count a title carries, 1...9999, or nil.
    public static func parse(_ title: String) -> Int? {
        let digits: Substring
        if title.hasPrefix("("), let close = title.firstIndex(of: ")"),
           title[title.index(after: close)...].hasPrefix(" ") {
            var inside = title[title.index(after: title.startIndex)..<close]
            if inside.hasSuffix("+") { inside = inside.dropLast() }
            digits = inside
        } else if let inbox = title.range(of: "Inbox ("), let close = title[inbox.upperBound...].firstIndex(of: ")") {
            digits = title[inbox.upperBound..<close]
        } else {
            return nil
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let count = Int(digits), (1...9999).contains(count) else { return nil }
        return count
    }
}
