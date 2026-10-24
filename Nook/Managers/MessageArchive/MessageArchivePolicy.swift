// Licensed under GPL-3.0. See LICENSE.
//
//  MessageArchivePolicy.swift
//  Nook
//
//  What the native handler accepts from the capture script: only WhatsApp's own main frame, and
//  records decoded with bounds. The account (the Space) is always Nook's choice, never the page's.
//

import Foundation

enum MessageArchivePolicy {
    static let host = "web.whatsapp.com"
    /// The script sends 512 KB chunks; a little slack, nothing more.
    static let maxChunkBytes = 768 * 1024
    static let maxTextLength = 65_536

    static func accepts(scheme: String, host: String, isMainFrame: Bool, isPrivateOrAgent: Bool) -> Bool {
        scheme.lowercased() == "https" && host.lowercased() == Self.host && isMainFrame && !isPrivateOrAgent
    }

    /// A record from the page. A disappearing message that WhatsApp still shows after its timer
    /// ran out was kept by someone, so it gets no expiry here.
    static func record(from body: [String: Any], account: String, now: Date = Date()) -> ArchivedMessage? {
        guard let id = text(body["id"], 256), !id.isEmpty, let chatID = text(body["chatID"], 256), !chatID.isEmpty
        else { return nil }
        return ArchivedMessage(
            id: id, account: account, chatID: chatID, chatName: text(body["chatName"], 512) ?? "",
            senderID: text(body["senderID"], 256), senderName: text(body["senderName"], 512),
            fromMe: body["fromMe"] as? Bool ?? false,
            timestamp: Date(timeIntervalSince1970: number(body["timestamp"]) ?? 0),
            kind: text(body["kind"], 64) ?? "unknown", text: text(body["text"], maxTextLength),
            fileName: text(body["fileName"], 512), mimeType: text(body["mimeType"], 128),
            quotedID: text(body["quotedID"], 256), edited: body["edited"] as? Bool ?? false,
            viewOnce: body["viewOnce"] as? Bool ?? false,
            links: ((body["links"] as? [Any]) ?? []).prefix(20).compactMap { text($0, 2048) },
            expiresAt: number(body["expiresAt"]).map(Date.init(timeIntervalSince1970:)).flatMap { $0 > now ? $0 : nil })
    }

    /// A media chunk's bytes, or nil when it is not base64 or too large.
    static func chunk(from base64: String) -> Data? {
        guard base64.utf8.count <= (maxChunkBytes / 3 + 1) * 4, let data = Data(base64Encoded: base64),
              data.count <= maxChunkBytes else { return nil }
        return data
    }

    private static func text(_ value: Any?, _ limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        return string.count > limit ? String(string.prefix(limit)) : string
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
