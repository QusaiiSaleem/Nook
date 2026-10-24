// Licensed under GPL-3.0. See LICENSE.
//
//  WebNotificationScripts.swift
//  Nook
//
//  WebKit gives a third-party app no Web Notifications, so a page sees Nook's own
//  `Notification` instead. The shim runs in the page world, because that is where the page
//  looks for `Notification`; the relay runs in an isolated world, the only place the native
//  handler is registered, so no page script can call the handler directly. The two talk with
//  `window.postMessage` on the same window and each drops any message whose `event.source` is
//  not that window, which keeps frames (ad iframes included) out.
//

import Foundation
import WebKit

public enum WebNotificationScripts {
    public static let handlerName = "nookWebNotification"

    public static let relayWorld = WKContentWorld.world(name: "NookWebNotification")

    /// Page world, main frame, before the page's own scripts.
    public static var shim: WKUserScript {
        WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Relay world, main frame, before the page's own scripts.
    public static var relay: WKUserScript {
        WKUserScript(source: relaySource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: relayWorld)
    }

    /// Script for `relayWorld` telling the page that notification `id` was clicked.
    public static func clickScript(id: String) -> String {
        guard let quoted = try? String(data: JSONEncoder().encode(id), encoding: .utf8) else { return "" }
        return "window.postMessage({ __nookWNClick: \(quoted) }, '*');"
    }

    // MARK: - Sources

    private static let shimSource = """
    // Nook Web Notifications
    (function () {
        if (window.__nookWebNotifications) { return; }
        Object.defineProperty(window, '__nookWebNotifications', { value: true });

        let permission = 'default';
        let nextRequest = 1;
        let nextID = 1;
        // Banners outlive the page, so ids carry a per-document prefix: after a reload an old
        // banner's click must not land on the new page's notification of the same number.
        const documentKey = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)).slice(0, 12);
        const waiting = new Map();
        const live = new Map();
        const ids = new WeakMap();

        function fire(notification, type) {
            const event = new Event(type);
            notification.dispatchEvent(event);
            const handler = notification['on' + type];
            if (typeof handler === 'function') { handler.call(notification, event); }
        }

        function ask(kind) {
            return new Promise(function (resolve) {
                const rid = nextRequest++;
                waiting.set(rid, function (answer) {
                    if (answer === 'granted' || answer === 'denied' || answer === 'default') { permission = answer; }
                    resolve(permission);
                });
                window.postMessage({ __nookWN: kind, rid: rid }, '*');
            });
        }

        window.addEventListener('message', function (event) {
            if (event.source !== window || !event.data || typeof event.data !== 'object') { return; }
            const data = event.data;
            if ('__nookWNReply' in data) {
                const done = waiting.get(data.__nookWNReply);
                if (done) { waiting.delete(data.__nookWNReply); done(data.permission); }
            } else if ('__nookWNClick' in data) {
                const notification = live.get(String(data.__nookWNClick));
                if (notification) { fire(notification, 'click'); }
            }
        });

        class Notification extends EventTarget {
            constructor(title, options) {
                super();
                if (arguments.length === 0) { throw new TypeError('Notification requires a title'); }
                options = options || {};
                this.title = String(title);
                this.body = options.body == null ? '' : String(options.body);
                this.tag = options.tag == null ? '' : String(options.tag);
                this.icon = options.icon == null ? '' : String(options.icon);
                this.silent = !!options.silent;
                this.data = options.data === undefined ? null : options.data;
                this.onclick = null;
                this.onclose = null;
                this.onshow = null;
                this.onerror = null;
                const id = documentKey + '-' + nextID++;
                ids.set(this, id);
                if (permission !== 'granted') {
                    queueMicrotask(() => fire(this, 'error'));
                    return;
                }
                if (this.tag) {
                    for (const [otherID, other] of live) {
                        if (other.tag === this.tag) { live.delete(otherID); }
                    }
                }
                live.set(id, this);
                window.postMessage({
                    __nookWN: 'show', id: id, title: this.title, body: this.body,
                    tag: this.tag || null, silent: this.silent
                }, '*');
                queueMicrotask(() => fire(this, 'show'));
            }

            close() {
                const id = ids.get(this);
                if (!live.has(id)) { return; }
                live.delete(id);
                window.postMessage({ __nookWN: 'close', id: id }, '*');
                fire(this, 'close');
            }

            static get permission() { return permission; }

            static get maxActions() { return 0; }

            static requestPermission(callback) {
                const answer = ask('request');
                if (typeof callback === 'function') { answer.then(callback); }
                return answer;
            }
        }

        Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true });

        // Sites that notify through their service worker registration take the same path. Calls
        // made inside the worker itself cannot be reached: user scripts never run there.
        if (window.ServiceWorkerRegistration) {
            ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
                if (permission !== 'granted') {
                    return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
                }
                new Notification(title, options);
                return Promise.resolve();
            };
            ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([]); };
        }

        ask('query');
    })();
    """

    private static let relaySource = """
    // Nook Web Notifications Relay
    (function () {
        if (window.__nookWebNotificationsRelay) { return; }
        window.__nookWebNotificationsRelay = true;
        const handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(handlerName);
        if (!handler) { return; }

        window.addEventListener('message', function (event) {
            if (event.source !== window || !event.data || typeof event.data !== 'object') { return; }
            const data = event.data;
            let kind = data.__nookWN;
            // Without a click a request only reads the stored answer, as Safari refuses to prompt
            // on page load. Checked here, where the page cannot fake it.
            if (kind === 'request' && navigator.userActivation && !navigator.userActivation.isActive) {
                kind = 'query';
            }
            let message;
            if (kind === 'query' || kind === 'request') {
                message = { kind: kind, rid: Number(data.rid) };
            } else if (kind === 'show') {
                message = {
                    kind: kind, id: String(data.id),
                    title: String(data.title == null ? '' : data.title).slice(0, 512),
                    body: String(data.body == null ? '' : data.body).slice(0, 4096),
                    tag: data.tag == null ? null : String(data.tag).slice(0, 256),
                    silent: !!data.silent
                };
            } else if (kind === 'close') {
                message = { kind: kind, id: String(data.id) };
            } else {
                return;
            }
            handler.postMessage(message).then(function (reply) {
                if (kind === 'query' || kind === 'request') {
                    window.postMessage({ __nookWNReply: message.rid, permission: String(reply) }, '*');
                }
            }, function () {});
        });
    })();
    """
}
