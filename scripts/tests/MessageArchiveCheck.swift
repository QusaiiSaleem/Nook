// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Managers/MessageArchive/SearchText.swift Nook/Managers/MessageArchive/MessageArchive.swift \
//         scripts/tests/MessageArchiveCheck.swift -lsqlite3 -o /tmp/ma && /tmp/ma
//
//  The local WhatsApp copy: one row per message per account, Arabic search, deletions that take
//  the search entry and the media file with them, private files kept out of backups.

import Foundation

@main
struct MessageArchiveCheck {
    static func message(_ id: String, account: String = "space-a", text: String? = "hello", chat: String = "chat-1",
                        edited: Bool = false) -> ArchivedMessage {
        ArchivedMessage(
            id: id, account: account, chatID: chat, chatName: "Ahmad", senderID: "ahmad@c.us", senderName: "Ahmad",
            fromMe: false, timestamp: Date(timeIntervalSince1970: 1_790_000_000), kind: "chat", text: text,
            fileName: nil, mimeType: nil, quotedID: nil, edited: edited, viewOnce: false, links: [])
    }

    static func fresh() throws -> (MessageArchive, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ma-\(UUID().uuidString)/Messages")
        return (try MessageArchive(directory: dir), dir)
    }

    static func count(_ archive: MessageArchive, _ account: String) -> Int {
        (try? archive.stats(account: account).messages) ?? -1
    }

    static func find(_ archive: MessageArchive, _ query: String, account: String? = nil) -> [ArchivedMessage] {
        (try? archive.search(query, account: account)) ?? []
    }

    static func main() throws {
        try upsert_is_idempotent()
        try edit_replaces_text()
        try arabic_search_ignores_marks()
        try delete_removes_row_search_and_media()
        try delete_chat_removes_all()
        try accounts_stay_apart()
        try files_are_private_and_excluded()
        try readme_written()
        try expired_messages_are_purged()
        try files_outside_the_media_folder_are_never_touched()
        try media_bookkeeping()
        print("MessageArchiveCheck passed")
    }

    static func upsert_is_idempotent() throws {
        let (archive, _) = try fresh()
        try archive.upsert([message("m1")])
        try archive.upsert([message("m1")])
        precondition(count(archive, "space-a") == 1, "the same message twice is one row")
    }

    static func edit_replaces_text() throws {
        let (archive, _) = try fresh()
        try archive.upsert([message("m1", text: "see you at 5")])
        try archive.upsert([message("m1", text: "see you at 6", edited: true)])
        let hits = find(archive, "6")
        precondition(hits.count == 1 && hits[0].text == "see you at 6" && hits[0].edited)
        precondition(find(archive, "5").isEmpty, "the old text is no longer searchable")
    }

    static func arabic_search_ignores_marks() throws {
        let (archive, _) = try fresh()
        try archive.upsert([message("m1", text: "مَرْحَبًا بالجميع"), message("m2", text: "أحمد قال إنه قادم")])
        precondition(find(archive, "مرحبا").map(\.id) == ["m1"])
        precondition(find(archive, "احمد").map(\.id) == ["m2"])
    }

    static func delete_removes_row_search_and_media() throws {
        let (archive, _) = try fresh()
        try archive.upsert([message("m1", text: "the contract")])
        let file = try archive.beginMedia(account: "space-a", id: "m1", fileName: "contract.pdf")
        try archive.appendMedia(Data("%PDF-1.7".utf8), to: file)
        try archive.finishMedia(account: "space-a", id: "m1", at: file)
        precondition(FileManager.default.fileExists(atPath: file.path))
        try archive.delete(account: "space-a", ids: ["m1"])
        precondition(count(archive, "space-a") == 0)
        precondition(find(archive, "contract").isEmpty, "the search entry goes with the row")
        precondition(!FileManager.default.fileExists(atPath: file.path), "the media file goes with the row")
    }

    static func delete_chat_removes_all() throws {
        let (archive, _) = try fresh()
        try archive.upsert([message("m1"), message("m2"), message("m3", chat: "chat-2")])
        try archive.deleteChat(account: "space-a", chatID: "chat-1")
        precondition(count(archive, "space-a") == 1)
    }

    static func accounts_stay_apart() throws {
        let (archive, _) = try fresh()
        try archive.upsert([message("m1", account: "space-a", text: "work"), message("m1", account: "space-b", text: "home")])
        precondition(count(archive, "space-a") == 1 && count(archive, "space-b") == 1)
        precondition(find(archive, "home", account: "space-a").isEmpty)
        precondition(find(archive, "home", account: "space-b").count == 1)
    }

    static func files_are_private_and_excluded() throws {
        let (_, dir) = try fresh()
        let fm = FileManager.default
        let dirMode = (try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        let dbMode = (try fm.attributesOfItem(atPath: dir.appendingPathComponent("messages.sqlite").path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(dirMode == 0o700, "folder mode \(String(dirMode ?? 0, radix: 8))")
        precondition(dbMode == 0o600, "database mode \(String(dbMode ?? 0, radix: 8))")
        let excluded = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        precondition(excluded == true, "the folder is excluded from backups")
    }

    /// Disappearing messages leave the copy when their timer runs out, as in WhatsApp.
    static func expired_messages_are_purged() throws {
        let (archive, _) = try fresh()
        var vanishing = message("m1", text: "this disappears")
        vanishing.expiresAt = Date(timeIntervalSince1970: 1_790_000_100)
        try archive.upsert([vanishing, message("m2", text: "this stays")])
        try archive.purgeExpired(now: Date(timeIntervalSince1970: 1_790_000_200))
        precondition(count(archive, "space-a") == 1)
        precondition(find(archive, "disappears").isEmpty && find(archive, "stays").count == 1)
    }

    /// Only files under the archive's media folder are ever recorded or deleted.
    static func files_outside_the_media_folder_are_never_touched() throws {
        let (archive, dir) = try fresh()
        let outside = dir.deletingLastPathComponent().appendingPathComponent("keep-me.txt")
        try Data("mine".utf8).write(to: outside)
        try archive.upsert([message("m1")])
        precondition((try? archive.finishMedia(account: "space-a", id: "m1", at: outside)) == nil, "a file outside media/ is refused")
        try archive.delete(account: "space-a", ids: ["m1"])
        precondition(FileManager.default.fileExists(atPath: outside.path), "a file outside media/ survives a delete")
    }

    /// Which files are still wanted, and that view-once media is never accepted.
    static func media_bookkeeping() throws {
        let (archive, _) = try fresh()
        var once = message("vo1")
        once.viewOnce = true
        try archive.upsert([message("m1"), message("m2"), once])
        let file = try archive.beginMedia(account: "space-a", id: "m1", fileName: "a.jpg")
        try archive.finishMedia(account: "space-a", id: "m1", at: file)
        let missing = try archive.missingMedia(account: "space-a", ids: ["m1", "m2", "nope"])
        let allowed = try archive.mediaAllowed(account: "space-a", id: "m2")
        let viewOnce = try archive.mediaAllowed(account: "space-a", id: "vo1")
        let unknown = try archive.mediaAllowed(account: "space-a", id: "nope")
        precondition(Set(missing) == ["m2"], "missing \(missing)")
        precondition(allowed)
        precondition(!viewOnce, "view-once media is refused")
        precondition(!unknown, "unknown messages get no file")
    }

    static func readme_written() throws {
        let (_, dir) = try fresh()
        let readme = try String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8)
        precondition(readme.contains("messages_fts") && readme.contains("search_text"))
    }
}
