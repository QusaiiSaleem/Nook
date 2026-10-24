// Licensed under GPL-3.0. See LICENSE.
//
//  WebNotificationScriptsCheck.swift
//  Nook
//
//  The page's Notification shim and its isolated relay, in a real off-screen web view.
//  NookWeb has no test target, so this compiles the shipped source directly:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/WebNotificationScripts.swift \
//           Packages/NookWeb/Checks/WebNotificationScriptsCheck.swift -o /tmp/wns && /tmp/wns
//

import AppKit
import WebKit

/// Stands in for Nook's native handler: records what the relay sends and grants every request.
@MainActor
final class Recorder: NSObject, WKScriptMessageHandlerWithReply {
    var messages: [(body: [String: Any], mainFrame: Bool)] = []

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        if let body = message.body as? [String: Any] { messages.append((body, message.frameInfo.isMainFrame)) }
        replyHandler("granted", nil)
    }

    func shows(titled title: String) -> [(body: [String: Any], mainFrame: Bool)] {
        messages.filter { $0.body["kind"] as? String == "show" && $0.body["title"] as? String == title }
    }
}

@main
struct WebNotificationScriptsCheck {
    @MainActor static var web: WKWebView!
    @MainActor static let recorder = Recorder()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.addScriptMessageHandler(recorder, contentWorld: WebNotificationScripts.relayWorld,
                                           name: WebNotificationScripts.handlerName)
        controller.addUserScript(WebNotificationScripts.shim)
        controller.addUserScript(WebNotificationScripts.relay)

        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web = WKWebView(frame: window.contentView!.bounds, configuration: config)
        window.contentView = web
        window.orderBack(nil)
        web.loadHTMLString("<body>page</body>", baseURL: URL(string: "https://example.test/"))
        precondition(waitUntil { (evaluate("document.readyState") as? String) == "complete" }, "page never loaded")

        check_permission_follows_query_reply()
        check_request_permission_resolves()
        check_show_reaches_handler()
        check_iframe_cannot_reach_handler()
        check_click_fires_onclick()
        check_page_cannot_see_handler()
        print("WebNotificationScriptsCheck passed")
    }

    // MARK: - Checks

    @MainActor static func check_permission_follows_query_reply() {
        precondition(waitUntil { (evaluate("Notification.permission") as? String) == "granted" },
                     "Notification.permission never took the native answer")
    }

    @MainActor static func check_request_permission_resolves() {
        let answer = callAsync("return await Notification.requestPermission()") as? String
        precondition(answer == "granted", "requestPermission resolved \(String(describing: answer))")
    }

    @MainActor static func check_show_reaches_handler() {
        _ = evaluate("window.__n = new Notification('Ahmad', { body: 'are you coming?' }); 'ok'")
        precondition(waitUntil { !recorder.shows(titled: "Ahmad").isEmpty }, "show never reached the handler")
        let shown = recorder.shows(titled: "Ahmad")[0]
        precondition(shown.body["body"] as? String == "are you coming?")
        precondition(shown.mainFrame)
    }

    @MainActor static func check_iframe_cannot_reach_handler() {
        let frame = #"<script>parent.postMessage({ __nookWN: 'show', id: 'x', title: 'evil' }, '*')</script>"#
        _ = evaluate("""
            const f = document.createElement('iframe');
            f.srcdoc = \(jsString(frame));
            document.body.appendChild(f); 'ok'
            """)
        _ = waitUntil(1) { false }
        precondition(recorder.shows(titled: "evil").isEmpty, "a frame's message reached the native handler")
    }

    @MainActor static func check_click_fires_onclick() {
        _ = evaluate("window.__clicked = 'no'; window.__n.onclick = () => { window.__clicked = 'yes' }; 'ok'")
        guard let id = recorder.shows(titled: "Ahmad").first?.body["id"] as? String else {
            preconditionFailure("show carried no id")
        }
        web.evaluateJavaScript(WebNotificationScripts.clickScript(id: id), in: nil, in: WebNotificationScripts.relayWorld)
        precondition(waitUntil { (evaluate("window.__clicked") as? String) == "yes" }, "the click never reached onclick")
    }

    @MainActor static func check_page_cannot_see_handler() {
        let seen = evaluate("typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nookWebNotification)")
        precondition(seen as? String == "undefined", "the page world can reach the native handler")
    }

    // MARK: - Helpers

    /// Spins the run loop until `condition` holds or `timeout` passes.
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

    @MainActor static func callAsync(_ body: String) -> Any? {
        var result: Any?
        var done = false
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome in
            if case .success(let value) = outcome { result = value }
            done = true
        }
        waitUntil { done }
        return result
    }

    static func jsString(_ s: String) -> String {
        String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
    }
}
