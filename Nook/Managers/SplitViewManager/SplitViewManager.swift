// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookTabsCore
import NookWeb

/// Split view per window. The pair lives on `BrowserWindowState.split` (item ids, saved with the
/// window); the active side is whichever pane the window selects. Only the drag preview state is
/// kept here.
@MainActor
final class SplitViewManager: ObservableObject {
    enum Side { case left, right }

    /// A read-only snapshot of one window's split and preview state.
    struct WindowSplitState {
        var isSplit: Bool = false
        var leftTabId: UUID? = nil
        var rightTabId: UUID? = nil
        var dividerFraction: CGFloat = 0.5
        var isPreviewActive: Bool = false
        var previewSide: Side? = nil
        var activeSide: Side? = nil
        var dragLocation: CGPoint? = nil
    }

    private struct Preview {
        var isActive = false
        var side: Side?
        var dragLocation: CGPoint?
    }

    weak var browserManager: BrowserManager?

    @Published private var previews: [UUID: Preview] = [:]

    init(browserManager: BrowserManager? = nil) {
        self.browserManager = browserManager
    }

    private func window(_ windowId: UUID) -> BrowserWindowState? {
        browserManager?.windowRegistry?.windows[windowId]
    }

    // MARK: - State

    func getSplitState(for windowId: UUID) -> WindowSplitState {
        let preview = previews[windowId] ?? Preview()
        var state = WindowSplitState(
            isPreviewActive: preview.isActive, previewSide: preview.side, dragLocation: preview.dragLocation)
        guard let window = window(windowId), let split = window.split else { return state }
        state.isSplit = true
        state.leftTabId = split.leftItemID
        state.rightTabId = split.rightItemID
        state.dividerFraction = CGFloat(split.fraction)
        state.activeSide = side(for: window.selectedItemID, in: split)
        return state
    }

    func isSplit(for windowId: UUID) -> Bool { window(windowId)?.split != nil }
    func leftTabId(for windowId: UUID) -> UUID? { window(windowId)?.split?.leftItemID }
    func rightTabId(for windowId: UUID) -> UUID? { window(windowId)?.split?.rightItemID }
    func dividerFraction(for windowId: UUID) -> CGFloat { CGFloat(window(windowId)?.split?.fraction ?? 0.5) }
    func activeSide(for windowId: UUID) -> Side? { getSplitState(for: windowId).activeSide }

    func side(for itemID: UUID, in windowId: UUID) -> Side? {
        window(windowId)?.split.flatMap { side(for: itemID, in: $0) }
    }

    private func side(for itemID: UUID?, in split: SplitRecord) -> Side? {
        switch itemID {
        case split.leftItemID: return .left
        case split.rightItemID: return .right
        default: return nil
        }
    }

    // MARK: - Entering and Leaving

    /// Puts `itemID` on `side`. Outside a split it pairs with the window's selection, which stays
    /// selected; inside a split it replaces that pane and becomes the selection.
    func enterSplit(with itemID: UUID, placeOn side: Side = .right, in window: BrowserWindowState) {
        guard let tabs = browserManager?.tabs, tabs.item(itemID) != nil else { return }
        // A saved split: replacing a pane swaps the tab inside it, and a new pair becomes one.
        // The window keeps its last pair while it shows another tab, so only a pair on screen
        // has panes to replace.
        let showsSplit = window.split.map { [$0.leftItemID, $0.rightItemID].contains(window.selectedItemID) } ?? false
        if showsSplit, let split = window.split, let saved = tabs.split(holding: split.leftItemID) {
            let old = side == .left ? split.leftItemID : split.rightItemID
            if old != itemID, tabs.replaceInSplit(saved.id, replacing: old, with: itemID) {
                tabs.select(itemID, in: window)
                loadPanes(of: window)
                return
            }
        } else if !showsSplit, let current = window.selectedItemID, current != itemID {
            let (left, right) = side == .left ? (itemID, current) : (current, itemID)
            if tabs.makeSplit(left: left, right: right, at: current) != nil {
                tabs.select(current, in: window)
                loadPanes(of: window)
                return
            }
        }
        // A favorite in the pair: a split of this window only, as before saved splits.
        if var split = window.split {
            switch side {
            case .left: split.leftItemID = itemID
            case .right: split.rightItemID = itemID
            }
            guard split.leftItemID != split.rightItemID else { return }
            window.split = split
            loadPanes(of: window)
            tabs.select(itemID, in: window)
            return
        }
        guard let current = window.selectedItemID, current != itemID else { return }
        let (left, right) = side == .left ? (itemID, current) : (current, itemID)
        window.split = SplitRecord(leftItemID: left, rightItemID: right, fraction: 0.5)
        loadPanes(of: window)
        // Selecting again saves the window record with its new split.
        tabs.select(current, in: window)
    }

    /// A pane shows its page, so the sidebar gives it back first.
    private func loadPanes(of window: BrowserWindowState) {
        guard let bm = browserManager, let split = window.split else { return }
        for id in [split.leftItemID, split.rightItemID] {
            bm.exitSidebarPiP(showing: id)
            if let session = bm.tabs.ensureSession(for: id) {
                PiPManager.shared.leaveAutomatic(session)
                bm.compositorManager.load(session)
            }
        }
    }

    /// Leaves the split. When the window selects a pane, the kept side becomes the selection.
    func exitSplit(keep side: Side, for windowId: UUID) {
        guard let window = window(windowId), let split = window.split else { return }
        let showsPane = self.side(for: window.selectedItemID, in: split) != nil
        window.split = nil
        let kept = side == .left ? split.leftItemID : split.rightItemID
        if showsPane, let tabs = browserManager?.tabs, tabs.item(kept) != nil {
            tabs.select(kept, in: window)
        } else {
            // No selection change to save the record, so save it here.
            browserManager?.tabs.mirror(window)
            window.refreshCompositor()
        }
    }

    /// Ends the split and keeps both tabs open. The active pane stays selected.
    func separate(in window: BrowserWindowState) {
        let keep = activeSide(for: window.id) ?? .left
        if let split = window.split, let tabs = browserManager?.tabs, let saved = tabs.split(holding: split.leftItemID) {
            tabs.separateSplit(saved.id)
        }
        exitSplit(keep: keep, for: window.id)
    }

    // MARK: - Divider

    /// Moves the divider of the window's split to `fraction` of the width (each pane keeps at
    /// least `SplitInfo.minFraction`). `persist` stores it: on the saved split, or the window record.
    func setDividerFraction(_ fraction: Double, for windowId: UUID, persist: Bool) {
        guard let window = window(windowId), var split = window.split, let tabs = browserManager?.tabs else { return }
        split.fraction = SplitInfo(fraction: fraction).clamped().fraction
        if split != window.split {
            window.split = split
            window.refreshCompositor()
        }
        guard persist else { return }
        if let saved = tabs.split(holding: split.leftItemID) {
            tabs.setSplitLayout(saved.id, fraction: split.fraction)
        } else {
            tabs.mirror(window)
        }
    }

    func cleanupWindow(_ windowId: UUID) {
        previews.removeValue(forKey: windowId)
    }

    // MARK: - Preview During Drag-Over

    func beginPreview(side: Side?, for windowId: UUID) {
        previews[windowId, default: Preview()].isActive = true
        previews[windowId]?.side = side
        window(windowId)?.refreshCompositor()
    }

    func updatePreviewSide(_ side: Side?, for windowId: UUID) {
        guard previews[windowId]?.isActive == true else { return }
        previews[windowId]?.side = side
    }

    func updateDragLocation(_ location: CGPoint?, for windowId: UUID) {
        previews[windowId, default: Preview()].dragLocation = location
    }

    func dragLocation(for windowId: UUID) -> CGPoint? {
        previews[windowId]?.dragLocation
    }

    func endPreview(cancel: Bool, for windowId: UUID) {
        previews[windowId] = Preview()
        window(windowId)?.refreshCompositor()
    }
}
