// Licensed under GPL-3.0. See LICENSE.
//
//  MessageArchiveScripts.swift
//  Nook
//
//  The page side of the local WhatsApp copy. WA-JS (vendored, `wppconnect-wa.js`) exposes
//  WhatsApp Web's decrypted messages as `window.WPP`; the capture script, evaluated after it in
//  the page world, turns them into plain records. It only reads: it never calls anything that
//  sends, marks read, or changes what other people see. Records travel by `window.postMessage`
//  to the relay in an isolated world, the only place the native handler is registered.
//

import Foundation
import WebKit

enum MessageArchiveScripts {
    static let handlerName = "nookMessageArchive"

    static let relayWorld = WKContentWorld.world(name: "NookMessageArchive")

    /// Relay world, main frame. Forwards the capture script's messages and carries replies back.
    static var relay: WKUserScript {
        WKUserScript(source: relaySource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: relayWorld)
    }

    /// The vendored WA-JS from the app bundle, or nil when it is missing.
    static var waJSSource: String? {
        Bundle.main.url(forResource: "wppconnect-wa", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static let captureSource = """
    // Nook WhatsApp Capture
    (function () {
        if (window.__nookWhatsAppCapture) { return; }
        Object.defineProperty(window, '__nookWhatsAppCapture', { value: true });

        const BATCH = 200;
        const CHUNK = 512 * 1024;
        const MEDIA_KINDS = new Set(['image', 'video', 'ptt', 'audio', 'document', 'sticker']);
        const waiting = new Map();
        const queue = [];
        let nextRequest = 1;
        let downloading = false;
        let stopped = false;

        function send(kind, payload) {
            if (stopped) { return Promise.resolve(null); }
            return new Promise(function (resolve) {
                const rid = nextRequest++;
                waiting.set(rid, resolve);
                window.postMessage(Object.assign({ __nookMA: kind, rid: rid }, payload), '*');
            });
        }

        window.addEventListener('message', function (event) {
            if (event.source !== window || !event.data || typeof event.data !== 'object') { return; }
            if ('__nookMAReply' in event.data) {
                const done = waiting.get(event.data.__nookMAReply);
                if (done) { waiting.delete(event.data.__nookMAReply); done(event.data.reply); }
            }
        });

        function pause(reason) {
            if (stopped) { return; }
            send('status', { state: 'paused', reason: String(reason || '').slice(0, 300) });
            stopped = true;
        }

        function sid(value) {
            if (!value) { return null; }
            if (typeof value === 'string') { return value; }
            return value._serialized || null;
        }

        function chatName(chatID) {
            try {
                const store = WPP.whatsapp && WPP.whatsapp.ChatStore;
                const chat = store && store.get && store.get(chatID);
                if (!chat) { return ''; }
                const contact = chat.contact || {};
                return String(chat.name || chat.formattedTitle || contact.name || contact.pushname || '');
            } catch (e) { return ''; }
        }

        function record(m) {
            const id = sid(m && m.id);
            if (!id) { return null; }
            const chatID = sid(m.id.remote) || sid(m.from) || '';
            if (chatID === 'status@broadcast') { return null; }
            const kind = String(m.type || 'unknown');
            // A media message's body is its thumbnail; the caption is the text.
            const text = kind === 'chat' ? m.body : m.caption;
            const sender = m.senderObj || {};
            const ts = Number(m.t) || 0;
            const duration = Number(m.ephemeralDuration) || 0;
            return {
                id: id, chatID: chatID, chatName: chatName(chatID),
                senderID: sid(m.author) || sid(m.from),
                senderName: sender.name || sender.pushname || sender.formattedName || null,
                fromMe: !!m.id.fromMe, timestamp: ts, kind: kind,
                text: text == null ? null : String(text).slice(0, 65536),
                fileName: m.filename ? String(m.filename) : null,
                mimeType: m.mimetype ? String(m.mimetype) : null,
                quotedID: m.quotedStanzaID ? String(m.quotedStanzaID) : null,
                edited: !!m.latestEditMsgKey, viewOnce: !!m.isViewOnce,
                links: text ? (String(text).match(/https?:[/][/][^\\s]+/g) || []).slice(0, 20) : [],
                expiresAt: duration > 0 ? (Number(m.ephemeralStartTimestamp) || ts) + duration : null,
                hasMedia: MEDIA_KINDS.has(kind) && !!m.mediaData
            };
        }

        async function save(messages, edited) {
            const records = [];
            const deletes = [];
            for (const m of messages) {
                if (m && m.type === 'revoked') {
                    const id = sid(m.id);
                    if (id) { deletes.push(id); }
                    continue;
                }
                const r = record(m);
                if (!r) { continue; }
                if (edited) { r.edited = true; }
                records.push(r);
            }
            if (deletes.length) { await send('delete', { ids: deletes }); }
            for (let i = 0; i < records.length; i += BATCH) {
                const batch = records.slice(i, i + BATCH);
                const reply = await send('upsert', { messages: batch });
                const wanted = new Set((reply && reply.needMedia) || []);
                for (const r of batch) {
                    if (wanted.has(r.id) && r.hasMedia && !r.viewOnce) { queue.push(r); }
                }
            }
            drain();
        }

        function base64(blob) {
            return new Promise(function (resolve, reject) {
                const reader = new FileReader();
                reader.onload = function () { resolve(String(reader.result).split(',')[1] || ''); };
                reader.onerror = function () { reject(reader.error); };
                reader.readAsDataURL(blob);
            });
        }

        // One file at a time, each chunk waiting for Nook's answer, so a large history never floods.
        async function drain() {
            if (downloading || stopped) { return; }
            downloading = true;
            try {
                while (queue.length && !stopped) {
                    const r = queue.shift();
                    try {
                        const blob = await WPP.chat.downloadMedia(r.id);
                        await send('mediaBegin', { id: r.id, fileName: r.fileName });
                        for (let offset = 0; offset < blob.size; offset += CHUNK) {
                            await send('mediaChunk', { id: r.id, base64: await base64(blob.slice(offset, offset + CHUNK)) });
                        }
                        await send('mediaEnd', { id: r.id });
                    } catch (e) {
                        // Media WhatsApp no longer has: the message row stays without a file.
                    }
                }
            } finally {
                downloading = false;
            }
        }

        async function backfill() {
            const chats = await WPP.chat.list();
            for (const chat of chats) {
                if (stopped) { return; }
                const id = sid(chat && chat.id);
                if (!id || id === 'status@broadcast') { continue; }
                let messages = [];
                try { messages = await WPP.chat.getMessages(id, { count: -1 }); } catch (e) { continue; }
                await save(messages, false);
            }
        }

        function start() {
            try {
                WPP.on('chat.new_message', function (m) { save([m], false); });
                WPP.on('chat.msg_edited', function (e) { if (e && e.msg) { save([e.msg], true); } });
                WPP.on('chat.msg_revoke', function (e) {
                    const id = sid(e && e.refId);
                    if (id) { send('delete', { ids: [id] }); }
                });
                send('status', { state: 'running' });
                backfill().catch(function (e) { pause(e && e.message ? e.message : e); });
            } catch (e) {
                pause(e && e.message ? e.message : e);
            }
        }

        if (!window.WPP || !WPP.chat || typeof WPP.on !== 'function') { pause('WA-JS is not available'); return; }
        if (WPP.isReady) { start(); }
        else if (WPP.webpack && typeof WPP.webpack.onReady === 'function') { WPP.webpack.onReady(start); }
        else { pause('WA-JS did not become ready'); }
    })();
    """

    private static let relaySource = """
    // Nook WhatsApp Capture Relay
    (function () {
        if (window.__nookWhatsAppCaptureRelay) { return; }
        window.__nookWhatsAppCaptureRelay = true;
        const handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(handlerName);
        if (!handler) { return; }
        const kinds = new Set(['upsert', 'delete', 'deleteChat', 'mediaBegin', 'mediaChunk', 'mediaEnd', 'status']);

        window.addEventListener('message', function (event) {
            if (event.source !== window || !event.data || typeof event.data !== 'object') { return; }
            const kind = event.data.__nookMA;
            if (!kinds.has(kind)) { return; }
            const rid = event.data.rid;
            const message = Object.assign({}, event.data, { kind: kind });
            delete message.__nookMA;
            delete message.rid;
            const answer = function (reply) { window.postMessage({ __nookMAReply: rid, reply: reply || null }, '*'); };
            handler.postMessage(message).then(answer, function () { answer(null); });
        });
    })();
    """
}
