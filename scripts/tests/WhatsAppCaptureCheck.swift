// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/MessageArchive/MessageArchiveScripts.swift \
//         scripts/tests/WhatsAppCaptureCheck.swift -o /tmp/wac && /tmp/wac
//
//  The WhatsApp capture script against a fake WPP in a real off-screen web view. The fake behaves
//  like WA-JS v4.7.2 where it matters: not ready when the script runs (`WPP.loader.onFullReady`),
//  `getMessages` paged and anchored before the newest own messages, media models without
//  `mediaData`. Backfill in batches, live messages, edits, deletions, media in chunks, never
//  view-once, never oversized or old media, never a call that sends or marks anything.

import AppKit
import WebKit

@MainActor
final class Recorder: NSObject, WKScriptMessageHandlerWithReply {
    var messages: [[String: Any]] = []
    /// When set, every reply tells the capture to stop (the Space's copy was turned off).
    var stopping = false

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any] else { return replyHandler(nil, nil) }
        messages.append(body)
        if stopping { return replyHandler(["stop": true], nil) }
        if body["kind"] as? String == "upsert", let records = body["messages"] as? [[String: Any]] {
            // Ask for every file, view-once included: the script itself must refuse those.
            let wanted = records.filter { $0["hasMedia"] as? Bool == true }.compactMap { $0["id"] as? String }
            return replyHandler(["needMedia": wanted], nil)
        }
        replyHandler(nil, nil)
    }

    func of(_ kind: String) -> [[String: Any]] { messages.filter { $0["kind"] as? String == kind } }
    var upserted: [[String: Any]] { of("upsert").flatMap { $0["messages"] as? [[String: Any]] ?? [] } }
    func record(_ id: String) -> [String: Any]? { upserted.last { $0["id"] as? String == id } }
    func index(_ kind: String, _ id: String) -> Int? {
        messages.firstIndex { $0["kind"] as? String == kind && $0["id"] as? String == id }
    }
}

@main
struct WhatsAppCaptureCheck {
    @MainActor static var web: WKWebView!
    @MainActor static let recorder = Recorder()

    static let fakeWPP = """
        (function () {
            const handlers = {};
            const now = Math.floor(Date.now() / 1000);
            const chat = { id: { _serialized: 'c1@c.us' }, name: 'Ahmad', formattedTitle: 'Ahmad' };
            const msg = (id, extra) => Object.assign({
                id: { _serialized: id, remote: { _serialized: 'c1@c.us' }, fromMe: false }, t: now - 3000, type: 'chat',
                from: { _serialized: 'c1@c.us' }, senderObj: { pushname: 'Ahmad' } }, extra);
            const history = [];
            for (let i = 0; i < 500; i++) history.push(msg('m' + i, { t: now - 3000 + i, body: 'message ' + i }));
            history.push(msg('img1', { t: now - 2000, type: 'image', caption: 'the contract', mediaData: {}, mimetype: 'image/jpeg', size: 1228800 }));
            history.push(msg('img2', { t: now - 1990, type: 'image', mimetype: 'image/png', size: 1000 }));
            history.push(msg('vo1', { t: now - 1980, type: 'image', isViewOnce: true, mediaData: {}, mimetype: 'image/jpeg' }));
            history.push(msg('big1', { t: now - 1970, type: 'document', filename: 'huge.zip', size: 3221225472, mediaData: {} }));
            history.push(msg('old1', { t: now - 40 * 86400, type: 'image', mediaData: {}, mimetype: 'image/jpeg', size: 1000 }));
            history.push(msg('rv1', { t: now - 1960, type: 'revoked' }));
            history.push(msg('eph1', { t: now - 1950, body: 'gone tomorrow', ephemeralDuration: 86400 }));
            history.push(msg('vc1', { t: now - 1940, type: 'vcard', body: 'BEGIN:VCARD\\nFN:Sara\\nEND:VCARD' }));
            history.push(msg('loc1', { t: now - 1930, type: 'location', loc: 'Khobar Corniche', lat: 26.28, lng: 50.21 }));
            // Sent from the phone after the last received message: WhatsApp's store has it,
            // getMessages (anchored at the last received message) does not.
            const own = msg('own1', { t: now - 10, body: 'sent from my phone' });
            own.id.fromMe = true;
            chat.msgs = { getModelsArray: () => [history[history.length - 1], own] };
            window.__fake = {
                downloads: [], calls: [],
                emit(event, payload) { (handlers[event] || []).forEach((h) => h(payload)); }
            };
            window.WPP = {
                isReady: false, isFullReady: false,
                loader: { onFullReady(cb) { setTimeout(() => { WPP.isReady = true; WPP.isFullReady = true; cb(); }, 50); } },
                on(event, handler) { (handlers[event] = handlers[event] || []).push(handler); },
                chat: {
                    list: async () => [chat],
                    getMessages: async (id, opts) => {
                        window.__fake.calls.push(JSON.stringify(opts || {}));
                        if (id !== 'c1@c.us') { return []; }
                        const count = opts && opts.count > 0 ? opts.count : history.length;
                        let end = history.length;
                        if (opts && opts.id) {
                            end = history.findIndex((m) => m.id._serialized === opts.id);
                            if (end < 0) { return []; }
                        }
                        return history.slice(Math.max(0, end - count), end);
                    },
                    downloadMedia: async (id) => {
                        window.__fake.downloads.push(id);
                        return new Blob([new Uint8Array(id === 'img1' ? 1228800 : 1000)], { type: 'image/jpeg' });
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

        backfill_waits_for_the_loader_then_pages()
        own_newest_message_is_saved()
        revoked_in_backfill_is_a_delete()
        disappearing_message_carries_expiry()
        contact_cards_and_locations_keep_their_content()
        media_arrives_in_chunks_after_an_attempt_marker()
        media_without_media_data_is_still_fetched()
        view_once_never_downloads()
        oversized_and_old_media_are_skipped()
        new_message_upserts()
        a_file_is_downloaded_once()
        edit_upserts_with_edited_true()
        revoke_deletes_ref_id()
        relay_refuses_delete_chat()
        stop_reply_stops_the_capture()
        no_forbidden_calls()
        prelude_turns_off_wa_js_analytics()
        missing_wpp_reports_paused()
        print("WhatsAppCaptureCheck passed")
    }

    // MARK: - Checks

    @MainActor static func backfill_waits_for_the_loader_then_pages() {
        precondition(waitUntil(30) { recorder.record("m0") != nil && recorder.record("m499") != nil },
                     "backfill never ran (\(recorder.upserted.count) saved; status \(recorder.of("status")))")
        let calls = (evaluate("JSON.stringify(window.__fake.calls)") as? String) ?? ""
        precondition(!calls.contains("-1"), "getMessages asked for everything at once: \(calls)")
        precondition(calls.components(separatedBy: "count").count - 1 >= 2, "history was not paged: \(calls)")
        let batches = recorder.of("upsert").map { ($0["messages"] as? [[String: Any]])?.count ?? 0 }
        precondition(batches.allSatisfy { $0 <= 200 }, "batches \(batches)")
        precondition(recorder.record("m0")?["chatName"] as? String == "Ahmad")
    }

    @MainActor static func own_newest_message_is_saved() {
        precondition(waitUntil { recorder.record("own1")?["fromMe"] as? Bool == true }, "a message sent from the phone was missed")
    }

    @MainActor static func revoked_in_backfill_is_a_delete() {
        precondition(waitUntil { recorder.of("delete").contains { ($0["ids"] as? [String])?.contains("rv1") == true } },
                     "a message revoked while Nook was closed is not deleted")
        precondition(recorder.record("rv1") == nil)
    }

    @MainActor static func disappearing_message_carries_expiry() {
        let eph = recorder.record("eph1")
        let t = eph?["timestamp"] as? Double ?? 0
        precondition((eph?["expiresAt"] as? Double) == t + 86_400, "expiresAt \(String(describing: eph?["expiresAt"]))")
    }

    @MainActor static func contact_cards_and_locations_keep_their_content() {
        precondition((recorder.record("vc1")?["text"] as? String)?.contains("FN:Sara") == true, "the contact card's vCard was lost")
        let loc = recorder.record("loc1")?["text"] as? String ?? ""
        precondition(loc.contains("Khobar Corniche") && loc.contains("26.28") && loc.contains("50.21"), "location text \(loc)")
    }

    @MainActor static func media_arrives_in_chunks_after_an_attempt_marker() {
        precondition(waitUntil(30) { recorder.index("mediaEnd", "img1") != nil }, "media never finished")
        let chunks = recorder.of("mediaChunk").filter { $0["id"] as? String == "img1" }
        precondition(chunks.count == 3, "expected 3 chunks for 1.2 MB, got \(chunks.count)")
        guard let attempt = recorder.index("mediaAttempt", "img1"), let begin = recorder.index("mediaBegin", "img1") else {
            preconditionFailure("no attempt marker before the download")
        }
        precondition(attempt < begin, "the attempt marker must come first, so a crash marks the file")
        precondition(recorder.of("mediaBegin").first { $0["id"] as? String == "img1" }?["mimeType"] as? String == "image/jpeg")
    }

    @MainActor static func media_without_media_data_is_still_fetched() {
        precondition(waitUntil(10) { downloads().contains("img2") }, "a photo whose model lacks mediaData was never fetched")
    }

    @MainActor static func view_once_never_downloads() {
        precondition(!downloads().contains("vo1"), "a view-once photo was downloaded")
        precondition(recorder.index("mediaBegin", "vo1") == nil)
    }

    @MainActor static func oversized_and_old_media_are_skipped() {
        precondition(waitUntil {
            recorder.of("mediaFailed").contains { $0["id"] as? String == "big1" && $0["reason"] as? String == "tooLarge" }
        }, "a 3 GB file was not refused")
        precondition(waitUntil {
            recorder.of("mediaFailed").contains { $0["id"] as? String == "old1" && $0["reason"] as? String == "old" }
        }, "media older than 30 days was not held back")
        precondition(!downloads().contains("big1") && !downloads().contains("old1"))
    }

    @MainActor static func new_message_upserts() {
        _ = evaluate("""
            window.__fake.emit('chat.new_message', { id: { _serialized: 'n1', remote: { _serialized: 'c1@c.us' } },
                t: Math.floor(Date.now() / 1000), type: 'chat', body: 'are you coming?' }); 'ok'
            """)
        precondition(waitUntil { recorder.record("n1") != nil }, "a new message was not saved")
    }

    @MainActor static func a_file_is_downloaded_once() {
        _ = evaluate("""
            window.__fake.emit('chat.new_message', { id: { _serialized: 'img1', remote: { _serialized: 'c1@c.us' } },
                t: Math.floor(Date.now() / 1000), type: 'image', mediaData: {}, mimetype: 'image/jpeg', size: 1228800 }); 'ok'
            """)
        _ = waitUntil(1) { false }
        precondition(downloads().filter { $0 == "img1" }.count == 1, "img1 downloaded \(downloads().filter { $0 == "img1" }.count) times")
    }

    @MainActor static func edit_upserts_with_edited_true() {
        _ = evaluate("""
            window.__fake.emit('chat.msg_edited', { chat: { _serialized: 'c1@c.us' }, id: 'n1',
                msg: { id: { _serialized: 'n1', remote: { _serialized: 'c1@c.us' } }, t: Math.floor(Date.now() / 1000),
                       type: 'chat', body: 'are you coming at 6?' } }); 'ok'
            """)
        precondition(waitUntil {
            recorder.record("n1")?["edited"] as? Bool == true && recorder.record("n1")?["text"] as? String == "are you coming at 6?"
        }, "an edit was not saved as edited")
    }

    @MainActor static func revoke_deletes_ref_id() {
        _ = evaluate("""
            window.__fake.emit('chat.msg_revoke', { id: { _serialized: 'x' }, refId: { _serialized: 'n1' }, type: 'sender_revoke' }); 'ok'
            """)
        precondition(waitUntil { recorder.of("delete").contains { ($0["ids"] as? [String]) == ["n1"] } },
                     "a message deleted for everyone was not removed")
    }

    /// Nothing sends deleteChat yet, so no page script may use it to erase a chat.
    @MainActor static func relay_refuses_delete_chat() {
        _ = evaluate("window.postMessage({ __nookMA: 'deleteChat', rid: 999, chatID: 'c1@c.us' }, '*'); 'ok'")
        _ = waitUntil(1) { false }
        precondition(recorder.of("deleteChat").isEmpty, "the relay passed a deleteChat on")
    }

    /// Turning the copy off stops the page's capture, not just the saving.
    @MainActor static func stop_reply_stops_the_capture() {
        recorder.stopping = true
        _ = evaluate("""
            window.__fake.emit('chat.new_message', { id: { _serialized: 's1', remote: { _serialized: 'c1@c.us' } },
                t: Math.floor(Date.now() / 1000), type: 'chat', body: 'one' }); 'ok'
            """)
        precondition(waitUntil { recorder.record("s1") != nil })
        _ = evaluate("""
            window.__fake.emit('chat.new_message', { id: { _serialized: 's2', remote: { _serialized: 'c1@c.us' } },
                t: Math.floor(Date.now() / 1000), type: 'chat', body: 'two' }); 'ok'
            """)
        _ = waitUntil(1) { false }
        precondition(recorder.record("s2") == nil, "the capture kept sending after being told to stop")
        recorder.stopping = false
    }

    static func no_forbidden_calls() {
        let source = MessageArchiveScripts.captureSource
        for call in ["sendTextMessage", "sendFileMessage", "markIsRead", "markIsUnread", "sendSeen", "deleteMessage",
                     "editMessage", "sendReactionToMessage", "forwardMessage", "markIsComposing", "markIsRecording",
                     "setPresence", "chat.archive", "chat.pin", "openChat", "keepMessage"] {
            precondition(!source.contains(call), "the capture script mentions \(call)")
        }
    }

    /// WA-JS reports to Google Analytics unless told not to before it loads.
    @MainActor static func prelude_turns_off_wa_js_analytics() {
        let result = evaluate(MessageArchiveScripts.waJSPrelude + "; String(window.WPPConfig && window.WPPConfig.disableGoogleAnalytics)")
        precondition(result as? String == "true", "WPPConfig.disableGoogleAnalytics is \(String(describing: result))")
    }

    @MainActor static func missing_wpp_reports_paused() {
        recorder.messages.removeAll()
        load()
        _ = evaluate(MessageArchiveScripts.captureSource + "; 'ok'")
        precondition(waitUntil { recorder.of("status").contains { $0["state"] as? String == "paused" } },
                     "a page without WPP did not report paused")
    }

    // MARK: - Helpers

    @MainActor static func downloads() -> [String] {
        let json = evaluate("JSON.stringify(window.__fake ? window.__fake.downloads : [])") as? String ?? "[]"
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

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
