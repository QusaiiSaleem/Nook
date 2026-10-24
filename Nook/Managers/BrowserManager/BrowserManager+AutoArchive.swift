// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+AutoArchive.swift
//  Nook
//
//  Runs auto-archive (`TabsController.archiveStaleTabs`) once the first window is up, whenever
//  Nook becomes active, and on one timer set for the next tab due — not a polling loop.
//

import AppKit
import NookTabsCore
import NookWeb

extension BrowserManager {
    /// Called when a window finishes setting up; the first call starts auto-archive.
    func startAutoArchive() {
        guard autoArchiveObserver == nil else { return }
        autoArchiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.autoArchiveReady else { return }
                self.runAutoArchive()
            }
        }
        // Off the launch path, and after the other saved windows have reopened.
        autoArchiveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoArchiveReady = true
                self?.runAutoArchive()
            }
        }
    }

    private func runAutoArchive() {
        autoArchiveTimer?.invalidate()
        // With no tab due (all on screen, or none recorded yet), look again in an hour.
        let next = tabs.archiveStaleTabs() ?? Date().addingTimeInterval(60 * 60)
        // Never more often than every five minutes, even if a close keeps failing.
        let delay = min(max(next.timeIntervalSinceNow, 300), AutoArchive.maxAge)
        autoArchiveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAutoArchive() }
        }
    }
}
