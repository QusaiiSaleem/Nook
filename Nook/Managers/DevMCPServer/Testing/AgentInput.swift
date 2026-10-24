// Licensed under GPL-3.0. See LICENSE.
//
//  AgentInput.swift
//  Nook
//
//  MCP `type`: text and keys arrive as trusted events, the way a person's typing does, which
//  sites that ignore script-made events (Google Forms, rich editors) need. The web view takes the
//  keyboard only for the call and gives it back to whatever had it, with the caret where it was.
//

import AppKit
import WebKit

@MainActor
enum AgentInput {
    enum Failure: LocalizedError {
        case noWindow
        case noElement(String)
        case cannotFocus(String)
        case unknownKeys([String])
        case busy

        var errorDescription: String? {
            switch self {
            case .noWindow: "The page is not in a window yet; call any page tool first."
            case .busy: "Another type call is still running; wait for it to finish."
            case .noElement(let selector): "No element matches \(selector)."
            case .cannotFocus(let selector): "\(selector) exists but cannot take focus (hidden or disabled); open whatever reveals it first."
            case .unknownKeys(let keys):
                "Unknown keys: \(keys.joined(separator: ", ")). Known: \(AgentInput.keyCodes.keys.sorted().joined(separator: ", "))."
            }
        }
    }

    nonisolated static let keyCodes: [String: (code: UInt16, chars: String)] = [
        "Enter": (36, "\r"),
        "Tab": (48, "\t"),
        "Backspace": (51, "\u{8}"),
        "Escape": (53, "\u{1b}"),
        "ArrowLeft": (123, "\u{F702}"),
        "ArrowRight": (124, "\u{F703}"),
        "ArrowDown": (125, "\u{F701}"),
        "ArrowUp": (126, "\u{F700}"),
    ]

    /// One call at a time: two interleaved calls would type into each other's fields, and the later
    /// one would "give back" the keyboard to the page the earlier one had taken it for.
    private static var running = false

    /// Focuses `selector` (when given), types `text`, presses `keys` in order, and answers the
    /// focused element's value. The keyboard goes back as soon as the keys are in; the value is
    /// read after.
    static func type(_ text: String?, keys: [String], into webView: WKWebView, selector: String?) async throws -> String {
        guard let window = webView.window else { throw Failure.noWindow }
        let unknown = keys.filter { keyCodes[$0] == nil }
        guard unknown.isEmpty else { throw Failure.unknownKeys(unknown) }
        guard !running else { throw Failure.busy }
        running = true
        defer { running = false }

        // Named before the page focuses anything: WebKit takes the keyboard for the web view as
        // soon as the page focuses an element.
        let previous = owner(of: window.firstResponder)
        let caret = (window.firstResponder as? NSTextView)?.selectedRanges
        if let selector {
            let focus = try? await webView.callAsyncJavaScript(
                "const el = document.querySelector(selector); if (!el) { return 'missing'; } el.focus(); return document.activeElement === el ? 'ok' : 'unfocusable';",
                arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? String
            guard focus == "ok" else {
                giveBack(to: previous === webView ? nil : previous, caret: caret, in: window)
                throw focus == "unfocusable" ? Failure.cannotFocus(selector) : Failure.noElement(selector)
            }
        }
        window.makeFirstResponder(webView)
        if let text, !text.isEmpty { webView.insertText(text) }
        for name in keys {
            if let key = keyCodes[name] { press(key, into: webView, window: window) }
        }
        // WebKit hands key events to the page one at a time, each after the last is handled.
        try? await Task.sleep(for: .milliseconds(50 + 30 * keys.count))
        giveBack(to: previous === webView ? nil : previous, caret: caret, in: window)

        let value = try await webView.callAsyncJavaScript(
            "const el = document.activeElement; return el ? String(el.value ?? el.textContent ?? '') : '';",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        return value ?? ""
    }

    /// Straight to the page, not through the window, so a key can only reach the agent's page.
    private static func press(_ key: (code: UInt16, chars: String), into webView: WKWebView, window: NSWindow) {
        let flags: NSEvent.ModifierFlags = key.code >= 123 ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.chars,
                charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.code) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    /// A native text field edits through a shared field editor, which AppKit detaches from the
    /// field as soon as the field loses the keyboard, so the field is named before that happens.
    private static func owner(of responder: NSResponder?) -> NSResponder? {
        guard let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField else {
            return responder
        }
        return field
    }

    /// Puts a text field's caret back where it was, since a field that takes the keyboard selects
    /// all its text and the person's next key would replace it.
    private static func giveBack(to previous: NSResponder?, caret: [NSValue]?, in window: NSWindow) {
        window.makeFirstResponder(previous)
        if let field = previous as? NSTextField, let caret, let editor = field.currentEditor() as? NSTextView {
            editor.selectedRanges = caret
        }
    }
}
