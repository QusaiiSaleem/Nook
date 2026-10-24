// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Managers/DevMCPServer/Testing/AgentInput.swift \
//         scripts/tests/AgentInputCheck.swift -o /tmp/ai && /tmp/ai
//
//  MCP `type`: text and keys reach the page as trusted events (as a person's typing does, which
//  sites that ignore script-made events need), Arabic arrives intact, and the keyboard goes back
//  to whatever had it before, even in a window that is not the key window.

import AppKit
import WebKit

@MainActor
final class Loads: NSObject, WKNavigationDelegate {
    var finished = 0
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
}

@main
struct AgentInputCheck {
    static let page = """
        <html><body>
        <input id="field">
        <script>
        window.__events = [];
        const field = document.getElementById('field');
        for (const type of ['keydown', 'beforeinput', 'input']) {
            field.addEventListener(type, (e) => window.__events.push({ type: type, trusted: e.isTrusted, key: e.key || null }));
        }
        </script>
        </body></html>
        """

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let field = NSTextField(frame: NSRect(x: 0, y: 560, width: 200, height: 24))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        web.perform(NSSelectorFromString("_setWindowOcclusionDetectionEnabled:"), with: NSNumber(value: false))
        let loads = Loads()
        web.navigationDelegate = loads
        container.addSubview(field)
        container.addSubview(web)
        window.contentView = container
        window.orderBack(nil)
        web.loadHTMLString(page, baseURL: URL(string: "https://example.test/"))
        let end = Date().addingTimeInterval(10)
        while loads.finished == 0, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        precondition(loads.finished > 0, "page never loaded")

        // The person was typing in a native field (the URL bar, say), caret after "nook".
        field.stringValue = "nook.test"
        window.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: 4, length: 0)

        let value = try await AgentInput.type("مرحبا hello", keys: ["Backspace"], into: web, selector: "#field")
        precondition(value == "مرحبا hell", "value \(value)")

        let events = try await web.evaluateJavaScript("JSON.stringify(window.__events)") as? String ?? "[]"
        let list = try JSONSerialization.jsonObject(with: Data(events.utf8)) as? [[String: Any]] ?? []
        precondition(!list.isEmpty, "no events reached the page")
        precondition(list.allSatisfy { $0["trusted"] as? Bool == true }, "an untrusted event: \(events)")
        precondition(list.contains { $0["type"] as? String == "input" }, "no input event: \(events)")
        precondition(list.contains { $0["key"] as? String == "Backspace" }, "no Backspace keydown: \(events)")

        let responder = window.firstResponder
        let backToField = responder === field || ((responder as? NSTextView)?.isFieldEditor == true && (responder as? NSTextView)?.delegate === field)
        precondition(backToField, "the keyboard stayed with \(String(describing: responder))")
        let caret = (field.currentEditor() as? NSTextView)?.selectedRange
        precondition(caret == NSRange(location: 4, length: 0), "caret moved to \(String(describing: caret)): the next key would replace the text")
        precondition(field.stringValue == "nook.test", "the field's text changed: \(field.stringValue)")

        var threw = false
        do { _ = try await AgentInput.type("x", keys: [], into: web, selector: "#missing") } catch { threw = true }
        precondition(threw, "a selector that matches nothing must fail, not type somewhere else")

        print("AgentInputCheck passed")
    }
}
