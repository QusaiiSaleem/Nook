// Licensed under GPL-3.0. See LICENSE.
//
//  SavedSplitRow.swift
//  Nook
//
//  A saved split (an Arc-style split item, `TabTree+Splits`) as one sidebar row. The whole row
//  is one drag source, so dragging it moves the pair; each half selects its tab, which shows
//  both side by side. A half's menu has Separate Tabs to take the pair apart.
//

import SwiftUI
import NookDesign
import NookTabsCore
import NookUI
import NookWeb

struct SavedSplitRow: View {
    let split: Item
    let zoneID: DropZoneID

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @ObservedObject private var dragSession = NookDragSessionManager.shared

    var body: some View {
        if let pair = tabs.splitTabs(split.id) {
            let isActive = windowState.selectedItemID == pair.left.id || windowState.selectedItemID == pair.right.id
            NookDragSourceView(
                item: NookDragItem(
                    tabId: split.id,
                    title: "\(tabs.title(for: pair.left)) | \(tabs.title(for: pair.right))",
                    urlString: tabs.currentURL(for: pair.left)?.absoluteString ?? ""
                ),
                icon: tabs.session(for: pair.left.id)?.favicon,
                zoneID: zoneID,
                manager: dragSession
            ) {
                HStack(spacing: 0) {
                    SplitHalfLabel(item: pair.left)
                    Rectangle()
                        .fill(NookDesign.Surface.hairline)
                        .frame(width: NookDesign.Size.hairlineWidth)
                        .padding(.vertical, NookDesign.Spacing.sm)
                    SplitHalfLabel(item: pair.right)
                }
                .frame(height: NookDesign.Size.row)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
                .nookRowSelection(isActive)
                .nookElevation(isActive ? .raised : .flat)
            }
            .opacity(dragSession.draggedItem?.tabId == split.id ? NookDesign.Surface.unloadedOpacity : 1)
            .id(split.id)
        }
    }
}
