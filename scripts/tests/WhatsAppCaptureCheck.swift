// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/MessageArchive/MessageArchiveScripts.swift \
//         scripts/tests/WhatsAppCaptureCheck.swift -o /tmp/wac && /tmp/wac
//
//  The WhatsApp capture script against a fake WPP in a real off-screen web view: backfill in
//  batches, live messages, edits, deletions, media in chunks, never view-once media, never a
//  call that sends or marks anything.

import AppKit
import WebKit

@MainActor
final class Recorder: NSObject, WKScriptMessageHandlerWithReply {
    var messages: [[String: Any]] = []

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any] else { return replyHandler(nil, nil) }
        messages.append(body)
        if body["kind"] as? String == "upsert", let records = body["messages"] as? [[String: Any]] {
            // Ask for every file, view-once included: the script itself must refuse those.
            let wanted = records.filter { $0["hasMedia"] as? Bool == true }.compactMap { $0["id"] as? String }
            return replyHandler(["needMedia": wanted], nil)
        }
        replyHandler(nil, nil)
    }

    func of(_ kind: String) -> [[String: Any]] { messages.filter { $0["kind"] as? String == kind } }
    var upserted: [[String: Any]] { of("upsert").flatMap { $0["messages"] as? [[String: Any]] ?? [] } }
}

@main
struct WhatsAppCaptureCheck {
    @MainActor static var web: WKWebView!
    @MainActor static let recorder = Recorder()

    static let fakeWPP = """
        (function () {
            const handlers = {};
            const chat = { id: { _serialized: 'c1@c.us' }, name: 'Ahmad', formattedTitle: 'Ahmad' };
            const text = (i) => ({ id: { _serialized: 'm' + i, remote: { _serialized: 'c1@c.us' }, fromMe: false },
                                   t: 1790000000 + i, type: 'chat', body: 'message ' + i,
                                   senderObj: { pushname: 'Ahmad' }, from: { _serialized: 'c1@c.us' } });
            const history = [];
            for (let i = 0; i < 500; i++) history.push(text(i));
            history.push({ id: { _serialized: 'img1', remote: { _serialized: 'c1@c.us' } }, t: 1790000600, type: 'image',
                           caption: 'the contract', mediaData: {}, mimetype: 'image/jpeg' });
            history.push({ id: { _serialized: 'vo1', remote: { _serialized: 'c1@c.us' } }, t: 1790000601, type: 'image',
                           isViewOnce: true, mediaData: {}, mimetype: 'image/jpeg' });
            history.push({ id: { _serialized: 'rv1', remote: { _serialized: 'c1@c.us' } }, t: 1790000602, type: 'revoked' });
            history.push({ id: { _serialized: 'eph1', remote: { _serialized: 'c1@c.us' } }, t: 1790000700, type: 'chat',
                           body: 'gone tomorrow', ephemeralDuration: 86400 });
            window.__fake = {
                downloads: [],
                emit(event, payload) { (handlers[event] || []).forEach((h) => h(payload)); }
            };
            window.WPP = {
                isReady: true,
                on(event, handler) { (handlers[event] = handlers[event] || []).push(handler); },
                chat: {
                    list: async () => [chat],
                    getMessages: async (id) => (id === 'c1@c.us' ? history : []),
                    downloadMedia: async (id) => {
                        window.__fake.downloads.push(id);
                        return new Blob([new Uint8Array(1200 * 1024)], { type: 'image/jpeg' });
                    }
                },
                whatsapp: { ChatStore: { get: (id) => (id === 'c1@c.us' ? chat : undefined), on() {} } }
            };
        })(); 'ok'
        """

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(
            recorder, contentWorld: MessageArchiveScripts.relayWorld, name: MessageArchiveScripts.handlerName)
        config.userContentController.addUserScript(MessageArchiveScripts.relay)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web = WKWebView(frame: window.contentView!.bounds, configuration: config)
        window.contentView = web
        window.orderBack(nil)
        load()
        _ = evaluate(fakeWPP)
        _ = evaluate(MessageArchiveScripts.captureSource + "; 'ok'")

        backfill_batches_at_most_200()
        revoked_in_backfill_is_a_delete()
        disappearing_message_carries_expiry()
        media_arrives_in_chunks()
        view_once_never_downloads()
        new_message_upserts()
        edit_upserts_with_edited_true()
        revoke_deletes_ref_id()
        no_forbidden_calls()
        missing_wpp_reports_paused()
        print("WhatsAppCaptureCheck passed")
    }

    // MARK: - Checks

    @MainActor static func backfill_batches_at_most_200() {
        precondition(waitUntil(30) { recorder.upserted.count >= 503 }, "backfill sent \(recorder.upserted.count) of 503 messages")
        let batches = recorder.of("upsert").map { ($0["messages"] as? [[String: Any]])?.count ?? 0 }
        precondition(batches.count >= 3 && batches.allSatisfy { $0 <= 200 }, "batches \(batches)")
        let first = recorder.upserted.first { $0["id"] as? String == "m0" }
        precondition(first?["chatName"] as? String == "Ahmad" && first?["text"] as? String == "message 0")
    }

    @MainActor static func revoked_in_backfill_is_a_delete() {
        precondition(waitUntil { recorder.of("delete").contains { ($0["ids"] as? [String])?.contains("rv1") == true } },
                     "a message revoked while Nook was closed is not deleted")
        precondition(!recorder.upserted.contains { $0["id"] as? String == "rv1" })
    }

    @MainActor static func disappearing_message_carries_expiry() {
        let eph = recorder.upserted.first { $0["id"] as? String == "eph1" }
        precondition((eph?["expiresAt"] as? Double) == 1_790_000_700 + 86_400, "expiresAt \(String(describing: eph?["expiresAt"]))")
    }

    @MainActor static func media_arrives_in_chunks() {
        precondition(waitUntil(30) { recorder.of("mediaEnd").contains { $0["id"] as? String == "img1" } }, "media never finished")
        let chunks = recorder.of("mediaChunk").filter { $0["id"] as? String == "img1" }
        precondition(recorder.of("mediaBegin").contains { $0["id"] as? String == "img1" })
        precondition(chunks.count == 3, "expected 3 chunks for 1.2 MB, got \(chunks.count)")
    }

    @MainActor static func view_once_never_downloads() {
        let downloads = evaluate("JSON.stringify(window.__fake.downloads)") as? String ?? ""
        precondition(!downloads.contains("vo1"), "a view-once photo was downloaded: \(downloads)")
        precondition(!recorder.of("mediaBegin").contains { $0["id"] as? String == "vo1" })
    }

    @MainActor static func new_message_upserts() {
        _ = evaluate("""
            window.__fake.emit('chat.new_message', { id: { _serialized: 'n1', remote: { _serialized: 'c1@c.us' } },
                t: 1790001000, type: 'chat', body: 'are you coming?' }); 'ok'
            """)
        precondition(waitUntil { recorder.upserted.contains { $0["id"] as? String == "n1" } }, "a new message was not saved")
    }

    @MainActor static func edit_upserts_with_edited_true() {
        _ = evaluate("""
            window.__fake.emit('chat.msg_edited', { chat: { _serialized: 'c1@c.us' }, id: 'n1',
                msg: { id: { _serialized: 'n1', remote: { _serialized: 'c1@c.us' } }, t: 1790001000, type: 'chat',
                       body: 'are you coming at 6?' } }); 'ok'
            """)
        precondition(waitUntil {
            recorder.upserted.contains { $0["id"] as? String == "n1" && $0["edited"] as? Bool == true
                && $0["text"] as? String == "are you coming at 6?" }
        }, "an edit was not saved as edited")
    }

    @MainActor static func revoke_deletes_ref_id() {
        _ = evaluate("""
            window.__fake.emit('chat.msg_revoke', { id: { _serialized: 'x' }, refId: { _serialized: 'n1' }, type: 'sender_revoke' }); 'ok'
            """)
        precondition(waitUntil { recorder.of("delete").contains { ($0["ids"] as? [String]) == ["n1"] } },
                     "a message deleted for everyone was not removed")
    }

    static func no_forbidden_calls() {
        let source = MessageArchiveScripts.captureSource
        for call in ["sendTextMessage", "sendFileMessage", "markIsRead", "markIsUnread", "sendSeen", "deleteMessage",
                     "editMessage", "sendReactionToMessage", "forwardMessage", "markIsComposing", "markIsRecording",
                     "setPresence", "chat.archive", "chat.pin", "openChat"] {
            precondition(!source.contains(call), "the capture script mentions \(call)")
        }
    }

    @MainActor static func missing_wpp_reports_paused() {
        recorder.messages.removeAll()
        load()
        _ = evaluate(MessageArchiveScripts.captureSource + "; 'ok'")
        precondition(waitUntil { recorder.of("status").contains { $0["state"] as? String == "paused" } },
                     "a page without WPP did not report paused")
    }

    // MARK: - Helpers

    @MainActor static func load() {
        web.loadHTMLString("<body>wa</body>", baseURL: URL(string: "https://web.whatsapp.com/"))
        precondition(waitUntil { (evaluate("document.readyState") as? String) == "complete" }, "page never loaded")
    }

    @MainActor @discardableResult
    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    @MainActor static func evaluate(_ js: String) -> Any? {
        var result: Any?
        var done = false
        web.evaluateJavaScript(js, in: nil, in: .page) { outcome in
            if case .success(let value) = outcome { result = value }
            done = true
        }
        waitUntil { done }
        return result
    }
}
