// Licensed under GPL-3.0. See LICENSE.
//
//  MessageArchiveManager.swift
//  Nook
//
//  The local WhatsApp copy, per Space: whether it is on, installing the capture on WhatsApp
//  pages, and writing what arrives to `MessageArchive` on a serial queue so a long backfill never
//  holds up the main thread.
//

import AppKit
import NookWeb
import OSLog
import WebKit

@MainActor
final class MessageArchiveManager {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "MessageArchive")

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.qusai.nook")
            .appendingPathComponent("Messages")
    }

    private unowned let browserManager: BrowserManager
    private let queue = DispatchQueue(label: "com.qusai.nook.message-archive")
    /// Touched only on `queue`.
    nonisolated(unsafe) private var store: MessageArchive?
    /// Files being received and their bytes so far, by "<account>|<id>". Touched only on `queue`.
    nonisolated(unsafe) private var openMedia: [String: (file: URL, bytes: Int)] = [:]
    /// The page refuses files over 100 MB; this guards the total a page may send for one file.
    private static let maxFileBytes = 110 * 1024 * 1024
    /// What each Space's capture last reported.
    private(set) var status: [UUID: (running: Bool, reason: String?)] = [:]

    init(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    // MARK: - Setting

    func isEnabled(spaceID: UUID) -> Bool {
        browserManager.tabs.settings.messageArchiveSpaces.contains(spaceID.uuidString)
    }

    func setEnabled(_ enabled: Bool, spaceID: UUID) {
        var spaces = Set(browserManager.tabs.settings.messageArchiveSpaces)
        if enabled { spaces.insert(spaceID.uuidString) } else { spaces.remove(spaceID.uuidString) }
        browserManager.tabs.settings.messageArchiveSpaces = spaces.sorted()
        if !enabled { status[spaceID] = nil }
    }

    // MARK: - Install

    /// After a page finishes loading: on WhatsApp in an enabled Space, add the relay and handler,
    /// then run WA-JS and the capture script in the page.
    func install(in webView: WKWebView, session: PageSession) {
        guard let url = webView.url, url.scheme == "https", url.host?.lowercased() == MessageArchivePolicy.host,
              !session.isPrivate, !session.isAgentPage,
              let spaceID = browserManager.tabs.spaceID(of: session.itemID), isEnabled(spaceID: spaceID)
        else { return }
        guard let waJS = MessageArchiveScripts.waJSSource else {
            setStatus(running: false, reason: "WA-JS is missing from this build", spaceID: spaceID)
            return
        }
        openStore()
        let controller = webView.configuration.userContentController
        let relay = MessageArchiveScripts.relay
        if !controller.userScripts.contains(where: { $0.source.hasPrefix("// Nook WhatsApp Capture Relay") }) {
            controller.addUserScript(relay)
        }
        controller.removeScriptMessageHandler(forName: MessageArchiveScripts.handlerName, contentWorld: MessageArchiveScripts.relayWorld)
        controller.addScriptMessageHandler(
            MessageArchiveHandler(manager: self, session: session, spaceID: spaceID),
            contentWorld: MessageArchiveScripts.relayWorld, name: MessageArchiveScripts.handlerName)
        // The user script covers later documents; this one has already loaded.
        webView.evaluateJavaScript(relay.source, in: nil, in: MessageArchiveScripts.relayWorld)
        // The prelude goes in the same evaluation, so WA-JS reads it as it loads.
        webView.evaluateJavaScript(MessageArchiveScripts.waJSPrelude + "\n" + waJS, in: nil, in: .page) { _ in
            webView.evaluateJavaScript(MessageArchiveScripts.captureSource, in: nil, in: .page)
        }
    }

    // MARK: - Writing (called by MessageArchiveHandler)

    func upsert(_ records: [ArchivedMessage], mediaCandidates: [String], account: String,
                completion: @escaping @MainActor ([String]) -> Void) {
        queue.async { [self] in
            var wanted: [String] = []
            do {
                try store?.upsert(records)
                try store?.purgeExpired()
                wanted = try store?.missingMedia(account: account, ids: mediaCandidates) ?? []
            } catch {
                Self.log.error("archive write failed: \(String(describing: error), privacy: .public)")
            }
            DispatchQueue.main.async { completion(wanted) }
        }
    }

    func delete(ids: [String], account: String) {
        queue.async { [self] in try? store?.delete(account: account, ids: ids) }
    }

    func markMedia(id: String, state: String, account: String) {
        queue.async { [self] in try? store?.markMedia(account: account, id: id, state: state) }
    }

    func beginMedia(id: String, fileName: String?, mimeType: String?, account: String,
                    completion: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            let key = "\(account)|\(id)"
            if let stale = openMedia.removeValue(forKey: key) { try? FileManager.default.removeItem(at: stale.file) }
            if (try? store?.mediaAllowed(account: account, id: id)) == true,
               let file = try? store?.beginMedia(account: account, id: id, fileName: fileName, mimeType: mimeType) {
                openMedia[key] = (file, 0)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    func appendMedia(_ data: Data, id: String, account: String, completion: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            let key = "\(account)|\(id)"
            if let open = openMedia[key] {
                if open.bytes + data.count > Self.maxFileBytes {
                    openMedia[key] = nil
                    try? FileManager.default.removeItem(at: open.file)
                    try? store?.markMedia(account: account, id: id, state: "tooLarge")
                } else {
                    try? store?.appendMedia(data, to: open.file)
                    openMedia[key] = (open.file, open.bytes + data.count)
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    func finishMedia(id: String, account: String, completion: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            if let open = openMedia.removeValue(forKey: "\(account)|\(id)") {
                try? store?.finishMedia(account: account, id: id, at: open.file)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    func setStatus(running: Bool, reason: String?, spaceID: UUID) {
        status[spaceID] = (running, reason)
        if !running { Self.log.notice("capture paused: \(reason ?? "", privacy: .public)") }
    }

    /// Message count, media bytes and last save for a Space, for Settings.
    func stats(spaceID: UUID, completion: @escaping @MainActor ((messages: Int, bytes: Int64, lastSaved: Date?)?) -> Void) {
        queue.async { [self] in
            let result = try? store?.stats(account: spaceID.uuidString)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func openStore() {
        queue.async { [self] in
            guard store == nil else { return }
            do {
                store = try MessageArchive(directory: Self.directory)
                try store?.purgeExpired()
            } catch {
                Self.log.error("archive did not open: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
