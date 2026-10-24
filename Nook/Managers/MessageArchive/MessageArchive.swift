// Licensed under GPL-3.0. See LICENSE.
//
//  MessageArchive.swift
//  Nook
//
//  The local copy of WhatsApp: one SQLite database for every Space, media files beside it.
//  It lives only on this Mac: private file modes, excluded from backups, never synced. Claude
//  reads it with `sqlite3`; README.md in the folder describes the tables.
//

import Foundation
import SQLite3
import UniformTypeIdentifiers

/// One WhatsApp message as the capture script reports it.
struct ArchivedMessage: Codable, Equatable {
    var id: String
    var account: String
    var chatID: String
    var chatName: String
    var senderID: String?
    var senderName: String?
    var fromMe: Bool
    var timestamp: Date
    var kind: String
    var text: String?
    var fileName: String?
    var mimeType: String?
    var quotedID: String?
    var edited: Bool
    var viewOnce: Bool
    var links: [String]
    /// Relative to the archive folder, once the file has arrived.
    var mediaPath: String? = nil
    /// When a disappearing message expires; the copy drops it then, as WhatsApp does.
    var expiresAt: Date? = nil
}

enum MessageArchiveError: Error, CustomStringConvertible {
    case sqlite(String)
    var description: String { if case .sqlite(let message) = self { return message }; return "" }
}

final class MessageArchive {
    let directory: URL
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)

        let file = directory.appendingPathComponent("messages.sqlite")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw MessageArchiveError.sqlite("cannot open \(file.path)")
        }
        // A reader holding the lock (sqlite3 opened without -readonly) makes a write wait, not fail.
        sqlite3_busy_timeout(db, 5000)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try execute(Self.schema)
        try Self.readme.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writing

    /// Inserts or updates by account and id. An arrived media file is kept.
    func upsert(_ messages: [ArchivedMessage]) throws {
        guard !messages.isEmpty else { return }
        try transaction {
            let statement = try prepare("""
                INSERT INTO messages (account, id, chat_id, chat_name, sender_id, sender_name, from_me, ts, kind, text,
                                      file_name, mime_type, quoted_id, edited, view_once, links, search_text, people, saved_at,
                                      expires_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
                ON CONFLICT (account, id) DO UPDATE SET
                    chat_id = excluded.chat_id,
                    chat_name = COALESCE(NULLIF(excluded.chat_name, ''), messages.chat_name),
                    sender_id = COALESCE(excluded.sender_id, messages.sender_id),
                    sender_name = COALESCE(excluded.sender_name, messages.sender_name),
                    from_me = excluded.from_me, ts = excluded.ts,
                    kind = CASE WHEN excluded.kind IN ('ciphertext', 'unknown') THEN messages.kind ELSE excluded.kind END,
                    text = CASE WHEN excluded.text IS NOT NULL OR excluded.edited THEN excluded.text ELSE messages.text END,
                    links = CASE WHEN excluded.text IS NOT NULL OR excluded.edited THEN excluded.links ELSE messages.links END,
                    search_text = CASE WHEN excluded.text IS NOT NULL OR excluded.edited OR excluded.file_name IS NOT NULL
                                       THEN excluded.search_text ELSE messages.search_text END,
                    people = CASE WHEN NULLIF(excluded.chat_name, '') IS NULL THEN messages.people ELSE excluded.people END,
                    file_name = COALESCE(excluded.file_name, messages.file_name),
                    mime_type = COALESCE(excluded.mime_type, messages.mime_type),
                    quoted_id = COALESCE(excluded.quoted_id, messages.quoted_id),
                    edited = MAX(messages.edited, excluded.edited),
                    view_once = MAX(messages.view_once, excluded.view_once),
                    expires_at = excluded.expires_at, saved_at = excluded.saved_at
                -- Every load re-sends history: leave a row alone unless something in it changed.
                WHERE messages.text IS NOT excluded.text OR messages.chat_name IS NOT excluded.chat_name
                   OR messages.sender_name IS NOT excluded.sender_name OR messages.kind IS NOT excluded.kind
                   OR messages.edited IS NOT excluded.edited OR messages.expires_at IS NOT excluded.expires_at
                   OR messages.file_name IS NOT excluded.file_name OR messages.view_once IS NOT excluded.view_once
                """)
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            for m in messages {
                sqlite3_reset(statement)
                bind(statement, 1, m.account); bind(statement, 2, m.id); bind(statement, 3, m.chatID)
                bind(statement, 4, m.chatName); bind(statement, 5, m.senderID); bind(statement, 6, m.senderName)
                sqlite3_bind_int(statement, 7, m.fromMe ? 1 : 0)
                sqlite3_bind_double(statement, 8, m.timestamp.timeIntervalSince1970)
                bind(statement, 9, m.kind); bind(statement, 10, m.text); bind(statement, 11, m.fileName)
                bind(statement, 12, m.mimeType); bind(statement, 13, m.quotedID)
                sqlite3_bind_int(statement, 14, m.edited ? 1 : 0)
                sqlite3_bind_int(statement, 15, m.viewOnce ? 1 : 0)
                bind(statement, 16, m.links.isEmpty ? nil : m.links.joined(separator: "\n"))
                bind(statement, 17, SearchText.normalize([m.text, m.fileName].compactMap { $0 }.joined(separator: " ")))
                bind(statement, 18, SearchText.normalize([m.senderName, m.chatName].compactMap { $0 }.joined(separator: " ")))
                sqlite3_bind_double(statement, 19, now)
                if let expiry = m.expiresAt { sqlite3_bind_double(statement, 20, expiry.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 20) }
                try step(statement)
            }
        }
    }

    /// Removes the messages, their search entries and their media files.
    func delete(account: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        var files: [String] = []
        try transaction {
            let select = try prepare("SELECT media_path FROM messages WHERE account = ?1 AND id = ?2")
            let delete = try prepare("DELETE FROM messages WHERE account = ?1 AND id = ?2")
            defer { sqlite3_finalize(select); sqlite3_finalize(delete) }
            for id in ids {
                sqlite3_reset(select); bind(select, 1, account); bind(select, 2, id)
                if sqlite3_step(select) == SQLITE_ROW, let path = column(select, 0) { files.append(path) }
                sqlite3_reset(delete); bind(delete, 1, account); bind(delete, 2, id)
                try step(delete)
            }
        }
        removeMedia(files)
    }

    /// Removes disappearing messages whose timer ran out, with their search entries and media.
    func purgeExpired(now: Date = Date()) throws {
        let statement = try prepare("SELECT account, id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?1")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        var byAccount: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let account = column(statement, 0), let id = column(statement, 1) { byAccount[account, default: []].append(id) }
        }
        for (account, ids) in byAccount { try delete(account: account, ids: ids) }
    }

    /// Removes a whole chat: deleted or cleared in WhatsApp.
    func deleteChat(account: String, chatID: String) throws {
        let select = try prepare("SELECT id FROM messages WHERE account = ?1 AND chat_id = ?2")
        defer { sqlite3_finalize(select) }
        bind(select, 1, account); bind(select, 2, chatID)
        var ids: [String] = []
        while sqlite3_step(select) == SQLITE_ROW { if let id = column(select, 0) { ids.append(id) } }
        try delete(account: account, ids: ids)
    }

    // MARK: - Media

    /// A new, empty file for a message's media, under media/<account>/<yyyy-mm>/.
    func beginMedia(account: String, id: String, fileName: String?, mimeType: String?) throws -> URL {
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        let folder = directory.appendingPathComponent("media")
            .appendingPathComponent(Self.safe(account))
            .appendingPathComponent(month.string(from: try timestamp(account: account, id: id) ?? Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Photos, voice notes and videos have no file name; the type gives an extension Finder opens.
        let ext = ((fileName as NSString?)?.pathExtension.nilIfEmpty
            ?? mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }).map(Self.safe) ?? "bin"
        let file = folder.appendingPathComponent("\(Self.safe(id)).\(ext)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MessageArchiveError.sqlite("cannot create \(file.path)")
        }
        return file
    }

    func appendMedia(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func finishMedia(account: String, id: String, at file: URL) throws {
        guard let relative = mediaRelativePath(file) else {
            throw MessageArchiveError.sqlite("media file is outside the archive: \(file.path)")
        }
        let update = try prepare("UPDATE messages SET media_path = ?3, media_state = 'saved' WHERE account = ?1 AND id = ?2")
        defer { sqlite3_finalize(update) }
        bind(update, 1, account); bind(update, 2, id); bind(update, 3, relative)
        try step(update)
    }

    // MARK: - Reading

    /// Of `ids`, the saved messages whose file has not been tried yet. A file tried once (the page
    /// may have crashed on it), unavailable, too large or held back is not asked for again.
    func missingMedia(account: String, ids: [String]) throws -> [String] {
        try filter(ids, account: account, where: "media_path IS NULL AND view_once = 0 AND media_state IS NULL")
    }

    /// Whether a file may be received now: in the copy, not view-once, not saved or given up on.
    func mediaAllowed(account: String, id: String) throws -> Bool {
        try !filter([id], account: account,
                    where: "media_path IS NULL AND view_once = 0 AND (media_state IS NULL OR media_state = 'attempted')").isEmpty
    }

    /// Records where a file stands: attempted, unavailable, tooLarge or old.
    func markMedia(account: String, id: String, state: String) throws {
        let update = try prepare("UPDATE messages SET media_state = ?3 WHERE account = ?1 AND id = ?2 AND media_path IS NULL")
        defer { sqlite3_finalize(update) }
        bind(update, 1, account); bind(update, 2, id); bind(update, 3, state)
        try step(update)
    }

    private func filter(_ ids: [String], account: String, where condition: String) throws -> [String] {
        let statement = try prepare("SELECT 1 FROM messages WHERE account = ?1 AND id = ?2 AND \(condition)")
        defer { sqlite3_finalize(statement) }
        return ids.filter { id in
            sqlite3_reset(statement); bind(statement, 1, account); bind(statement, 2, id)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    /// Newest first. Words must all appear in the message text or file name; Arabic matches
    /// without marks or letter variants.
    func search(_ query: String, account: String? = nil, limit: Int = 50) throws -> [ArchivedMessage] {
        let words = SearchText.normalize(query).split(separator: " ")
        guard !words.isEmpty else { return [] }
        let match = words.map { "search_text : \"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
        let statement = try prepare("""
            SELECT m.account, m.id, m.chat_id, m.chat_name, m.sender_id, m.sender_name, m.from_me, m.ts, m.kind, m.text,
                   m.file_name, m.mime_type, m.quoted_id, m.edited, m.view_once, m.links, m.media_path
            FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid
            WHERE messages_fts MATCH ?1 AND (?2 IS NULL OR m.account = ?2)
            ORDER BY m.ts DESC LIMIT ?3
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, match); bind(statement, 2, account); sqlite3_bind_int(statement, 3, Int32(limit))
        var results: [ArchivedMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(ArchivedMessage(
                id: column(statement, 1) ?? "", account: column(statement, 0) ?? "", chatID: column(statement, 2) ?? "",
                chatName: column(statement, 3) ?? "", senderID: column(statement, 4), senderName: column(statement, 5),
                fromMe: sqlite3_column_int(statement, 6) != 0,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                kind: column(statement, 8) ?? "", text: column(statement, 9), fileName: column(statement, 10),
                mimeType: column(statement, 11), quotedID: column(statement, 12),
                edited: sqlite3_column_int(statement, 13) != 0, viewOnce: sqlite3_column_int(statement, 14) != 0,
                links: column(statement, 15)?.split(separator: "\n").map(String.init) ?? [],
                mediaPath: column(statement, 16)))
        }
        return results
    }

    /// Message count, media bytes and the last save for one account (a Space).
    func stats(account: String) throws -> (messages: Int, bytes: Int64, lastSaved: Date?) {
        let statement = try prepare("SELECT COUNT(*), MAX(saved_at) FROM messages WHERE account = ?1")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, account)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0, nil) }
        let count = Int(sqlite3_column_int64(statement, 0))
        let last = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let media = directory.appendingPathComponent("media").appendingPathComponent(Self.safe(account))
        var bytes: Int64 = 0
        if let files = FileManager.default.enumerator(at: media, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in files {
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return (count, bytes, last)
    }

    // MARK: - SQLite

    private func timestamp(account: String, id: String) throws -> Date? {
        let statement = try prepare("SELECT ts FROM messages WHERE account = ?1 AND id = ?2")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, account); bind(statement, 2, id)
        return sqlite3_step(statement) == SQLITE_ROW ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)) : nil
    }

    /// Deletes only files that resolve inside media/, whatever the database says.
    private func removeMedia(_ paths: [String]) {
        for path in paths {
            let file = directory.appendingPathComponent(path)
            if mediaRelativePath(file) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The path relative to the archive folder when `file` resolves inside media/, else nil.
    private func mediaRelativePath(_ file: URL) -> String? {
        let root = directory.appendingPathComponent("media").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root) else { return nil }
        return "media/" + resolved.dropFirst(root.count)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw MessageArchiveError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MessageArchiveError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MessageArchiveError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, Self.transient) } else { sqlite3_bind_null(statement, index) }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func safe(_ component: String) -> String {
        String(component.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" })
    }

    // MARK: - Schema

    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS messages (
            rowid INTEGER PRIMARY KEY,
            account TEXT NOT NULL, id TEXT NOT NULL, chat_id TEXT NOT NULL, chat_name TEXT,
            sender_id TEXT, sender_name TEXT, from_me INTEGER NOT NULL, ts REAL NOT NULL, kind TEXT NOT NULL,
            text TEXT, file_name TEXT, mime_type TEXT, quoted_id TEXT,
            edited INTEGER NOT NULL DEFAULT 0, view_once INTEGER NOT NULL DEFAULT 0, links TEXT, media_path TEXT,
            search_text TEXT NOT NULL DEFAULT '', people TEXT NOT NULL DEFAULT '', saved_at REAL, expires_at REAL,
            media_state TEXT,
            UNIQUE (account, id));
        CREATE INDEX IF NOT EXISTS messages_chat ON messages (account, chat_id, ts);
        CREATE INDEX IF NOT EXISTS messages_expiry ON messages (expires_at) WHERE expires_at IS NOT NULL;
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5 (
            search_text, people, content = 'messages', content_rowid = 'rowid', tokenize = 'unicode61');
        CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts (rowid, search_text, people) VALUES (new.rowid, new.search_text, new.people);
        END;
        CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
            INSERT INTO messages_fts (messages_fts, rowid, search_text, people) VALUES ('delete', old.rowid, old.search_text, old.people);
        END;
        DROP TRIGGER IF EXISTS messages_au;
        CREATE TRIGGER messages_au AFTER UPDATE OF search_text, people ON messages
        WHEN old.search_text IS NOT new.search_text OR old.people IS NOT new.people BEGIN
            INSERT INTO messages_fts (messages_fts, rowid, search_text, people) VALUES ('delete', old.rowid, old.search_text, old.people);
            INSERT INTO messages_fts (rowid, search_text, people) VALUES (new.rowid, new.search_text, new.people);
        END;
        """

    private static let readme = """
        # Nook's local WhatsApp copy

        Written by Nook while Keep a Local Copy is on (the site menu on WhatsApp, per Space). Lives
        only on this Mac: not synced, excluded from Time Machine. Messages deleted for everyone and
        disappearing messages whose timer ran out are removed here too. Messages or chats deleted
        only on this side (delete for me, clear chat, delete chat) are not removed yet.
        Open read-only, for example: `sqlite3 -readonly messages.sqlite`.

        ## messages
        One row per message per Space.
        - `account`: the Nook Space id (each Space holds one WhatsApp number)
        - `id`: WhatsApp's message id; `chat_id`, `chat_name`: the chat (groups end in `@g.us`)
        - `sender_id`, `sender_name`, `from_me` (1 = sent by this number)
        - `ts`: seconds since 1970 (`datetime(ts, 'unixepoch', 'localtime')`)
        - `kind`: chat (text), image, video, ptt (voice note), audio, document, sticker, location, vcard, …
        - `text`: the text, or a media caption; `file_name`, `mime_type` for documents
        - `quoted_id`: the message this one replies to; `edited`, `view_once` (media never saved)
        - `links`: URLs in the message, one per line
        - `media_path`: the saved file, relative to this folder (NULL until downloaded)
        - `media_state`: saved, attempted, unavailable, tooLarge (over 100 MB), or old (media older
          than 30 days is held back for now)
        - `expires_at`: for disappearing messages, when they leave this copy
        - `search_text`, `people`: normalized copies used for search (Arabic without marks:
          أ/إ/آ→ا, ى→ي, ة→ه, no tashkeel or tatweel)

        ## messages_fts
        Full-text index over `search_text` and `people`. Normalize the query the same way, then:
        `SELECT m.* FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid
         WHERE messages_fts MATCH 'search_text : "عقد"' ORDER BY m.ts DESC;`
        Use `people : "احمد"` to match a sender or chat name.
        """
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
