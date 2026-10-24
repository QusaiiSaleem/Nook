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
        case unknownKeys([String])

        var errorDescription: String? {
            switch self {
            case .noWindow: "The page is not in a window yet; call any page tool first."
            case .noElement(let selector): "No element matches \(selector)."
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

    /// Focuses `selector` (when given), types `text`, presses `keys` in order, and answers the
    /// focused element's value.
    static func type(_ text: String?, keys: [String], into webView: WKWebView, selector: String?) async throws -> String {
        guard let window = webView.window else { throw Failure.noWindow }
        let unknown = keys.filter { keyCodes[$0] == nil }
        guard unknown.isEmpty else { throw Failure.unknownKeys(unknown) }

        let previous = owner(of: window.firstResponder)
        let caret = (window.firstResponder as? NSTextView)?.selectedRanges
        window.makeFirstResponder(webView)
        defer { giveBack(to: previous, caret: caret, in: window) }

        if let selector {
            let focused = try await webView.callAsyncJavaScript(
                "const el = document.querySelector(selector); if (!el) { return false; } el.focus(); return document.activeElement === el;",
                arguments: ["selector": selector], in: nil, contentWorld: .defaultClient) as? Bool
            guard focused == true else { throw Failure.noElement(selector) }
        }
        if let text, !text.isEmpty { webView.insertText(text) }
        for name in keys {
            if let key = keyCodes[name] { press(key, in: window) }
        }
        // WebKit hands key events to the page one at a time, each after the last is handled.
        try await Task.sleep(for: .milliseconds(50 + 30 * keys.count))
        let value = try await webView.callAsyncJavaScript(
            "const el = document.activeElement; return el ? String(el.value ?? el.textContent ?? '') : '';",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        return value ?? ""
    }

    private static func press(_ key: (code: UInt16, chars: String), in window: NSWindow) {
        let flags: NSEvent.ModifierFlags = key.code >= 123 ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.chars,
                charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.code) else { continue }
            window.sendEvent(event)
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
