// Licensed under GPL-3.0. See LICENSE.
//
//  LocalCopyMenuRows.swift
//  Nook
//
//  The site menu's local WhatsApp copy rows: on WhatsApp, a switch for this Space's copy, its
//  size, and the folder. Wording approved by Qusai (2026-10-24).
//

import AppKit
import NookUI
import NookWeb
import SwiftUI

struct LocalCopyMenuRows: View {
    let browserManager: BrowserManager
    let session: PageSession
    let spaceID: UUID

    @State private var isOn = false
    @State private var detail: String?

    private var manager: MessageArchiveManager { browserManager.messageArchiveManager }

    var body: some View {
        MoreMenuItem(icon: "archivebox.fill", iconColor: .teal, label: "Keep a Local Copy", detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(NookSwitchToggleStyle())
        }
        .onAppear {
            isOn = manager.isEnabled(spaceID: spaceID)
            refresh()
        }
        .onChange(of: isOn) { _, enabled in
            guard enabled != manager.isEnabled(spaceID: spaceID) else { return }
            manager.setEnabled(enabled, spaceID: spaceID)
            // A fresh load installs the capture once (WA-JS must not load twice into one page);
            // turning it off stops the page's capture on its next message.
            if enabled { session.webView?.reload() }
            refresh()
        }

        if isOn {
            MoreMenuItem(icon: "folder.fill", iconColor: .blue, label: "Show in Finder", action: {
                NSWorkspace.shared.activateFileViewerSelecting([MessageArchiveManager.directory])
            })
        }
    }

    private func refresh() {
        guard isOn else { return detail = nil }
        if let status = manager.status[spaceID], !status.running { return detail = "Paused" }
        manager.stats(spaceID: spaceID) { stats in
            guard let stats else { return }
            let messages = "\(stats.messages.formatted()) messages"
            detail = stats.bytes > 0
                ? "\(messages) · \(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))"
                : messages
        }
    }
}
