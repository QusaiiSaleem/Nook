// Licensed under GPL-3.0. See LICENSE.
//
//  WebNotificationManager.swift
//  Nook
//
//  The app end of web notifications: asks the person when a site wants to notify, posts what a
//  page shows as a macOS notification, and turns a click on one into that Space and tab. The page
//  side is `WebNotificationScripts` and `WebNotificationBridge` in NookWeb.
//

import AppKit
import NookSettings
import NookWeb
import OSLog
import UserNotifications

@MainActor
final class WebNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "WebNotifications")

    private unowned let browserManager: BrowserManager
    private let createdAt = Date()
    /// Delivered request identifiers by `"<itemID>|<notification id>"`, so a page's close() finds its banner.
    private var identifiers: [String: String] = [:]
    /// A click waiting for a browser window to register.
    private var pendingClick: (itemID: UUID, notificationID: String)?

    init(browserManager: BrowserManager) {
        self.browserManager = browserManager
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    /// Asks over the page's window. With no window the page is not on screen, so nothing is
    /// stored and the page hears "default": it can ask again once the person is looking at it.
    func requestPermission(host: String, session: PageSession, completion: @escaping (SitePermissionPolicy) -> Void) {
        guard let window = session.webView?.window else { return completion(.ask) }
        let alert = NSAlert()
        alert.messageText = "“\(host)” wants to show notifications"
        alert.informativeText = "Notifications appear in Notification Center."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.beginSheetModal(for: window) { [weak self] response in
            let policy: SitePermissionPolicy = response == .alertFirstButtonReturn ? .allow : .block
            self?.browserManager.tabs.settings.setPermission(.notifications, to: policy, for: host)
            if policy == .allow {
                // macOS asks once for the whole app; a site's Allow is the moment it matters.
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            completion(policy)
        }
    }

    // MARK: - Showing

    func show(_ payload: WebNotificationPayload, from session: PageSession) {
        let itemID = session.itemID
        let tabs = browserManager.tabs
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        if let spaceName = tabs.spaceID(of: itemID).flatMap({ tabs.space($0)?.name }) {
            content.subtitle = spaceName
        }
        content.threadIdentifier = itemID.uuidString
        content.sound = payload.silent ? nil : .default
        content.userInfo = ["itemID": itemID.uuidString, "notificationID": payload.id]

        // The same tag replaces the banner it names, as in browsers.
        let identifier = "\(itemID.uuidString)|\(payload.tag.map { "tag:\($0)" } ?? payload.id)"
        identifiers["\(itemID.uuidString)|\(payload.id)"] = identifier
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("notification not posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func close(id: String, from session: PageSession) {
        guard let identifier = identifiers.removeValue(forKey: "\(session.itemID.uuidString)|\(id)") else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners show even while Nook is in front: the page that notified is usually not the one on screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let itemID = (info["itemID"] as? String).flatMap(UUID.init(uuidString:))
        let notificationID = info["notificationID"] as? String ?? ""
        Task { @MainActor in
            if let itemID { self.open(itemID: itemID, notificationID: notificationID) }
            completionHandler()
        }
    }

    // MARK: - Click

    /// Brings Nook forward on the item's Space with the item selected, then lets the page handle
    /// the click (WhatsApp opens the chat). With no browser window, one opens first.
    private func open(itemID: UUID, notificationID: String) {
        let tabs = browserManager.tabs
        guard tabs.item(itemID) != nil, let spaceID = tabs.spaceID(of: itemID) else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let window = window(showing: spaceID) else {
            // `windowDidRegister` finishes it. Right after launch the first window is on its way.
            pendingClick = (itemID, notificationID)
            if Date().timeIntervalSince(createdAt) > 3 { browserManager.createNewWindow() }
            return
        }
        window.windowHandle?.bringToFront()
        tabs.select(itemID, in: window)
        tabs.session(for: itemID)?.deliverWebNotificationClick(id: notificationID)
    }

    /// A regular window on `spaceID`, else the active (then any) regular window moved there.
    private func window(showing spaceID: UUID) -> BrowserWindowState? {
        let tabs = browserManager.tabs
        let windows = tabs.regularWindows
        if let showing = windows.first(where: { $0.spaceID == spaceID }) { return showing }
        let active = browserManager.windowRegistry?.activeWindow.flatMap { window in
            windows.contains { $0 === window } ? window : nil
        }
        guard let target = active ?? windows.first else { return nil }
        tabs.setSpace(spaceID, in: target)
        return target
    }

    /// A regular window finished setting up (`BrowserManager.setupWindowState`). Finishes a click
    /// that had no window, on the next turn so it lands after the window's own selection.
    func windowDidRegister() {
        guard let click = pendingClick else { return }
        pendingClick = nil
        Task { @MainActor in self.open(itemID: click.itemID, notificationID: click.notificationID) }
    }
}
