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

    /// Run in the same evaluation as WA-JS, before it: WA-JS reports to Google Analytics from
    /// inside WhatsApp (a lasting client id, the page address and title) unless told not to.
    static let waJSPrelude = """
    // Nook WA-JS Config
    window.WPPConfig = Object.assign({}, window.WPPConfig, { disableGoogleAnalytics: true });
    """

    /// The vendored WA-JS from the app bundle, read once, or nil when it is missing.
    static let waJSSource: String? = Bundle.main.url(forResource: "wppconnect-wa", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static let captureSource = """
    // Nook WhatsApp Capture
    (function () {
        if (window.__nookWhatsAppCapture) { return; }
        Object.defineProperty(window, '__nookWhatsAppCapture', { value: true });

        const BATCH = 200;
        const PAGE = 500;
        const CHUNK = 512 * 1024;
        // A larger file, held whole in the page while it downloads, risks the page's memory.
        const MAX_MEDIA = 100 * 1024 * 1024;
        // Older media may be gone from WhatsApp's servers, and fetching it may ask the sender's
        // phone to upload it again; held back until that is confirmed harmless.
        const OLD_MEDIA = 30 * 86400;
        const READY_TIMEOUT = 120000;
        const MEDIA_KINDS = new Set(['image', 'video', 'ptt', 'audio', 'document', 'sticker']);
        const waiting = new Map();
        const queue = [];
        const queued = new Set();
        let nextRequest = 1;
        let downloading = false;
        let backfilling = false;
        let started = false;
        let stopped = false;

        function send(kind, payload) {
            if (stopped) { return Promise.resolve(null); }
            return new Promise(function (resolve) {
                const rid = nextRequest++;
                waiting.set(rid, resolve);
                window.postMessage(Object.assign({ __nookMA: kind, rid: rid }, payload), '*');
            }).then(function (reply) {
                // The Space's copy was turned off: stop reading, not just saving.
                if (reply && reply.stop) { stopped = true; }
                return reply;
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

        function vcards(m) {
            return Array.isArray(m.vcardList) ? m.vcardList.map(function (v) { return v && v.vcard; }).filter(Boolean).join('\\n') : null;
        }

        // A media message's body is its thumbnail; each kind keeps its words somewhere else.
        function textOf(m, kind) {
            switch (kind) {
            case 'chat': return m.body;
            case 'vcard': return m.body || vcards(m);
            case 'multi_vcard': return vcards(m);
            case 'location':
                return [m.loc, m.lat != null && m.lng != null ? m.lat + ',' + m.lng : null].filter(Boolean).join(' ') || null;
            case 'poll_creation':
                return [m.pollName].concat((m.pollOptions || []).map(function (o) { return o && o.name; })).filter(Boolean).join('\\n') || null;
            default: return m.caption;
            }
        }

        function record(m) {
            const id = sid(m && m.id);
            if (!id) { return null; }
            const chatID = sid(m.id.remote) || sid(m.from) || '';
            if (chatID === 'status@broadcast') { return null; }
            const kind = String(m.type || 'unknown');
            const text = textOf(m, kind);
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
                size: Number(m.size || (m.mediaData && m.mediaData.size)) || null,
                // By kind: models built for old messages may lack mediaData; a failed fetch is recorded.
                hasMedia: MEDIA_KINDS.has(kind)
            };
        }

        async function save(messages, edited, live) {
            if (stopped) { return; }
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
            for (let i = 0; i < records.length && !stopped; i += BATCH) {
                const batch = records.slice(i, i + BATCH);
                const reply = await send('upsert', { messages: batch });
                const wanted = new Set((reply && reply.needMedia) || []);
                for (const r of batch) {
                    if (wanted.has(r.id)) { enqueue(r, live); }
                }
            }
            drain();
        }

        // Each file once per page; new messages' files before the backlog.
        function enqueue(r, live) {
            if (!r.hasMedia || r.viewOnce || queued.has(r.id)) { return; }
            queued.add(r.id);
            if (r.size && r.size > MAX_MEDIA) { send('mediaFailed', { id: r.id, reason: 'tooLarge' }); return; }
            if (!live && r.timestamp && Date.now() / 1000 - r.timestamp > OLD_MEDIA) {
                send('mediaFailed', { id: r.id, reason: 'old' });
                return;
            }
            if (live) { queue.unshift(r); } else { queue.push(r); }
        }

        function base64(blob) {
            return new Promise(function (resolve, reject) {
                const reader = new FileReader();
                reader.onload = function () { resolve(String(reader.result).split(',')[1] || ''); };
                reader.onerror = function () { reject(reader.error); };
                reader.readAsDataURL(blob);
            });
        }

        function rest(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

        // One file at a time, each chunk waiting for Nook's answer, a short rest between files.
        // The attempt marker goes first, so a file that crashes the page is not tried again.
        async function drain() {
            if (downloading || stopped) { return; }
            downloading = true;
            try {
                while (queue.length && !stopped) {
                    const r = queue.shift();
                    await send('mediaAttempt', { id: r.id });
                    if (stopped) { break; }
                    let blob;
                    try { blob = await WPP.chat.downloadMedia(r.id); } catch (e) { blob = null; }
                    if (!blob) { await send('mediaFailed', { id: r.id, reason: 'unavailable' }); continue; }
                    if (blob.size > MAX_MEDIA) { await send('mediaFailed', { id: r.id, reason: 'tooLarge' }); continue; }
                    await send('mediaBegin', { id: r.id, fileName: r.fileName, mimeType: blob.type || r.mimeType });
                    for (let offset = 0; offset < blob.size && !stopped; offset += CHUNK) {
                        await send('mediaChunk', { id: r.id, base64: await base64(blob.slice(offset, offset + CHUNK)) });
                    }
                    if (!stopped) { await send('mediaEnd', { id: r.id }); }
                    await rest(250);
                }
            } catch (e) {
                // Never into WhatsApp's own error reporting.
            } finally {
                downloading = false;
            }
        }

        async function backfillChat(chat) {
            const id = sid(chat && chat.id);
            if (!id || id === 'status@broadcast') { return; }
            // WhatsApp's own store holds the newest messages, ones sent from the phone included;
            // getMessages starts at the last received message.
            try {
                if (chat.msgs && typeof chat.msgs.getModelsArray === 'function') { await save(chat.msgs.getModelsArray(), false, false); }
            } catch (e) {}
            let anchor = null;
            while (!stopped) {
                let messages = [];
                try {
                    messages = await WPP.chat.getMessages(id, anchor ? { count: PAGE, id: anchor, direction: 'before' } : { count: PAGE });
                } catch (e) { return; }
                if (!messages || !messages.length) { return; }
                await save(messages, false, false);
                const oldest = sid(messages[0] && messages[0].id);
                if (!oldest || oldest === anchor || messages.length < PAGE) { return; }
                anchor = oldest;
            }
        }

        async function backfill() {
            if (backfilling || stopped) { return; }
            backfilling = true;
            try {
                const chats = await WPP.chat.list();
                for (const chat of chats) {
                    if (stopped) { return; }
                    await backfillChat(chat);
                }
            } finally {
                backfilling = false;
            }
        }

        function start() {
            if (started) { return; }
            started = true;
            try {
                WPP.on('chat.new_message', function (m) { save([m], false, true).catch(function () {}); });
                WPP.on('chat.msg_edited', function (e) { if (e && e.msg) { save([e.msg], true, true).catch(function () {}); } });
                WPP.on('chat.msg_revoke', function (e) {
                    const id = sid(e && e.refId);
                    if (id) { send('delete', { ids: [id] }); }
                });
                // A page opened before sign-in lists no chats; signing in brings them.
                WPP.on('conn.authenticated', function () { backfill().catch(function () {}); });
                WPP.on('conn.main_loaded', function () { backfill().catch(function () {}); });
                send('status', { state: 'running' });
                backfill().catch(function (e) { pause(e && e.message ? e.message : e); });
            } catch (e) {
                pause(e && e.message ? e.message : e);
            }
        }

        if (!window.WPP || !WPP.chat || typeof WPP.on !== 'function') { pause('WA-JS is not available'); return; }
        // WA-JS becomes ready on its own timers, after this script runs.
        if (WPP.isFullReady) { start(); }
        else if (WPP.loader && typeof WPP.loader.onFullReady === 'function') {
            WPP.loader.onFullReady(start);
            setTimeout(function () { if (!started) { pause('WA-JS did not become ready'); } }, READY_TIMEOUT);
        } else {
            pause('WA-JS did not become ready');
        }
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
        const kinds = new Set(['upsert', 'delete', 'mediaAttempt', 'mediaFailed', 'mediaBegin', 'mediaChunk', 'mediaEnd', 'status']);

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
