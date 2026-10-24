// Licensed under GPL-3.0. See LICENSE.
//
//  SplitDividerView.swift
//  Nook
//
//  The gap between a split's two panes: drag to resize both, double-click for half and half.
//  Live moves only re-frame the panes (`refreshCompositor`); the position is stored on mouse-up.
//

import AppKit

final class SplitDividerView: NSView {
    weak var splitManager: SplitViewManager?
    var windowId: UUID?
    private var dragged = false
    private var fraction = 0.5

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        guard event.clickCount == 2, let windowId else { return }
        splitManager?.setDividerFraction(0.5, for: windowId, persist: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let windowId, let container = superview, container.bounds.width > 0 else { return }
        let x = container.convert(event.locationInWindow, from: nil).x
        fraction = Double((x - container.bounds.minX) / container.bounds.width)
        dragged = true
        splitManager?.setDividerFraction(fraction, for: windowId, persist: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragged, let windowId else { return }
        dragged = false
        splitManager?.setDividerFraction(fraction, for: windowId, persist: true)
    }
}
