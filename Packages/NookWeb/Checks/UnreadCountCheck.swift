// Licensed under GPL-3.0. See LICENSE.
//
//  UnreadCountCheck.swift
//  Nook
//
//  The unread count a page puts in its title. NookWeb has no test target, so this compiles the
//  shipped source directly:
//
//    swiftc Packages/NookWeb/Sources/NookWeb/UnreadCount.swift \
//           Packages/NookWeb/Checks/UnreadCountCheck.swift -o /tmp/uc && /tmp/uc
//

import Foundation

@main
struct UnreadCountCheck {
    static func main() {
        precondition(UnreadCount.parse("(3) WhatsApp") == 3)
        precondition(UnreadCount.parse("(99+) Home / X") == 99)
        precondition(UnreadCount.parse("Inbox (12) - me@gmail.com - Gmail") == 12)
        precondition(UnreadCount.parse("WhatsApp") == nil)
        precondition(UnreadCount.parse("(0) WhatsApp") == nil)
        precondition(UnreadCount.parse("Top 10 (2024)") == nil, "a number later in a title is not a count")
        precondition(UnreadCount.parse("(3)WhatsApp") == nil, "the count is followed by a space")
        precondition(UnreadCount.parse("(123456) spam") == nil, "counts stop at 9999")
        precondition(UnreadCount.parse("") == nil)
        print("UnreadCountCheck passed")
    }
}
