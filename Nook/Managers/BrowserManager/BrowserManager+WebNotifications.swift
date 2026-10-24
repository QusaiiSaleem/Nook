// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+WebNotifications.swift
//  Nook
//
//  Starts the pages that keep running offscreen (`TabsController.keepsRunningOffscreen`) when
//  Nook launches, so WhatsApp reconnects and notifies without being clicked first.
//

import Foundation
import NookWeb
import OSLog

extension BrowserManager {
    private static let backgroundLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "WebNotifications")

    /// Once per launch, after the first window's page has loaded (or given up), starts the
    /// favorites and pinned tabs that were open at quit and keep running offscreen, one at a time.
    /// This is not warming, so Low Power Mode and memory pressure do not hold it back.
    func startBackgroundPagesAfterLaunch(waitingFor selected: UUID?) {
        guard !didStartBackgroundPages else { return }
        didStartBackgroundPages = true
        Task { @MainActor [weak self] in
            if let view = selected.flatMap({ self?.tabs.session(for: $0)?.webView }) {
                _ = await Self.waitForStartupNavigation(view)
            }
            guard let self else { return }
            for id in self.tabs.backgroundLaunchItems() {
                // Closed (or no longer allowed) while it waited its turn: closing stops it.
                guard self.tabs.backgroundLaunchItems().contains(id),
                      let session = self.tabs.ensureSession(for: id), session.isUnloaded else { continue }
                self.compositorManager.load(session)
                Self.backgroundLog.notice("background page started: \(session.url.host ?? "", privacy: .private)")
                if let view = session.webView { _ = await Self.waitForStartupNavigation(view) }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
}
