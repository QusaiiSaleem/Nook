// Licensed under GPL-3.0. See LICENSE.
//
//  AgentPageHostView.swift
//  Nook
//

import AppKit

/// Holds the agent's page out of sight: transparent, outside the content area, never the target
/// of a click.
final class AgentPageHostView: NSView {
    /// How far left of the content area the host sits; wider than any window.
    static let offset: CGFloat = 20_000
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }

    // Keys an agent sends that its page does not use stop here. Climbing on, an Escape reaches the
    // person's window, which takes it as theirs: it closes their Peek or leaves full screen.
    override func cancelOperation(_ sender: Any?) {}
    override func keyDown(with event: NSEvent) {}
    override func doCommand(by selector: Selector) {}
}
