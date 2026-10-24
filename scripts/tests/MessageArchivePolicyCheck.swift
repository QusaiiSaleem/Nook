// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Managers/MessageArchive/SearchText.swift Nook/Managers/MessageArchive/MessageArchive.swift \
//         Nook/Managers/MessageArchive/MessageArchivePolicy.swift scripts/tests/MessageArchivePolicyCheck.swift \
//         -lsqlite3 -o /tmp/map && /tmp/map
//
//  Who may write to the local WhatsApp copy, and what a record from the page may contain.

import Foundation

@main
struct MessageArchivePolicyCheck {
    static func main() {
        // Only the main frame of the real WhatsApp, never a private or Agent page.
        precondition(MessageArchivePolicy.accepts(scheme: "https", host: "web.whatsapp.com", isMainFrame: true, isPrivateOrAgent: false))
        precondition(!MessageArchivePolicy.accepts(scheme: "http", host: "web.whatsapp.com", isMainFrame: true, isPrivateOrAgent: false))
        precondition(!MessageArchivePolicy.accepts(scheme: "https", host: "evil.com", isMainFrame: true, isPrivateOrAgent: false))
        precondition(!MessageArchivePolicy.accepts(scheme: "https", host: "web.whatsapp.com.evil.com", isMainFrame: true, isPrivateOrAgent: false))
        precondition(!MessageArchivePolicy.accepts(scheme: "https", host: "web.whatsapp.com", isMainFrame: false, isPrivateOrAgent: false))
        precondition(!MessageArchivePolicy.accepts(scheme: "https", host: "web.whatsapp.com", isMainFrame: true, isPrivateOrAgent: true))

        // A record decodes with the account the native side chose, never one from the page.
        let page: [String: Any] = [
            "id": "m1", "chatID": "c1@c.us", "chatName": "Ahmad", "senderName": "Ahmad", "fromMe": false,
            "timestamp": 1_790_000_000.0, "kind": "chat", "text": "hello", "edited": false, "viewOnce": false,
            "links": ["https://example.com"], "expiresAt": 1_790_086_400.0, "account": "someone-else"
        ]
        let decoded = MessageArchivePolicy.record(from: page, account: "space-a")
        precondition(decoded?.account == "space-a" && decoded?.id == "m1" && decoded?.text == "hello")
        precondition(decoded?.timestamp == Date(timeIntervalSince1970: 1_790_000_000))
        precondition(decoded?.expiresAt == Date(timeIntervalSince1970: 1_790_086_400))
        precondition(MessageArchivePolicy.record(from: ["chatID": "c1@c.us"], account: "space-a") == nil, "no id, no record")
        precondition(MessageArchivePolicy.record(from: ["id": "m1"], account: "space-a") == nil, "no chat, no record")
        var long = page
        long["text"] = String(repeating: "a", count: 200_000)
        precondition((MessageArchivePolicy.record(from: long, account: "space-a")?.text?.count ?? 0) <= 65_536, "text is capped")

        // Media chunks are bounded.
        precondition(MessageArchivePolicy.chunk(from: Data(count: 512 * 1024).base64EncodedString())?.count == 512 * 1024)
        precondition(MessageArchivePolicy.chunk(from: Data(count: 2 * 1024 * 1024).base64EncodedString()) == nil, "oversized chunk refused")
        precondition(MessageArchivePolicy.chunk(from: "not base64!") == nil)
        print("MessageArchivePolicyCheck passed")
    }
}
