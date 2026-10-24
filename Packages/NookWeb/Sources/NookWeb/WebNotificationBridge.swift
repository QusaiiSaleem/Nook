// Licensed under GPL-3.0. See LICENSE.
//
//  WebNotificationBridge.swift
//  Nook
//
//  The native end of `WebNotificationScripts`: one reply handler per web view, registered in the
//  relay world so no page script can reach it. It trusts only the main frame and takes the site
//  from the frame's security origin, never from the message.
//

import Foundation
import WebKit
import NookSettings

/// One notification a page asked to show, as the relay passed it on.
public struct WebNotificationPayload: Sendable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let tag: String?
    public let silent: Bool
    /// The site, as `SitePermissionRecord.key(for:)` spells it.
    public let host: String
}

@MainActor
final class WebNotificationBridge: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void

    private weak var session: PageSession?
    private var prompts = WebNotificationPrompts<Reply>()

    private init(session: PageSession) {
        self.session = session
        super.init()
    }

    /// Adds the shim, the relay and this handler to the view's controller. Safe to call again on
    /// the same view: the scripts go in once and the handler is replaced by name.
    static func install(on webView: WKWebView, session: PageSession) {
        let controller = webView.configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source.hasPrefix("// Nook Web Notifications") }) {
            controller.addUserScript(WebNotificationScripts.shim)
            controller.addUserScript(WebNotificationScripts.relay)
        }
        controller.removeScriptMessageHandler(
            forName: WebNotificationScripts.handlerName, contentWorld: WebNotificationScripts.relayWorld)
        controller.addScriptMessageHandler(
            WebNotificationBridge(session: session), contentWorld: WebNotificationScripts.relayWorld,
            name: WebNotificationScripts.handlerName)
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping Reply
    ) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == WebNotificationScripts.handlerName,
              message.world == WebNotificationScripts.relayWorld,
              message.frameInfo.isMainFrame,
              let session, let tabs = session.controller,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String
        else { return replyHandler(nil, nil) }

        let host = SitePermissionRecord.key(for: origin.host)
        // An insecure page reads as private: always "denied", never a prompt or a banner.
        let shielded = session.isPrivate || session.isAgentPage
            || !WebNotificationPolicy.isSecure(scheme: origin.protocol, host: origin.host)
        let stored = tabs.settings.permission(.notifications, for: host)

        switch kind {
        case "query":
            replyHandler(WebNotificationPolicy.query(stored: stored, isPrivateOrAgent: shielded), nil)
        case "request":
            switch WebNotificationPolicy.answer(stored: stored, isPrivateOrAgent: shielded) {
            case .reply(let value):
                replyHandler(value, nil)
            case .prompt:
                guard prompts.add(replyHandler, for: host) else { return }
                guard let delegate = tabs.sessionDelegate else { return finish(host, with: .ask) }
                delegate.requestWebNotificationPermission(host: host, session: session) { [weak self] policy in
                    self?.finish(host, with: policy)
                }
            }
        case "show":
            replyHandler(nil, nil)
            guard WebNotificationPolicy.mayShow(stored: stored, isPrivateOrAgent: shielded),
                  let id = Self.notificationID(body["id"]) else { return }
            let payload = WebNotificationPayload(
                id: id, title: body["title"] as? String ?? "", body: body["body"] as? String ?? "",
                tag: body["tag"] as? String, silent: body["silent"] as? Bool ?? false, host: host)
            tabs.sessionDelegate?.showWebNotification(payload, from: session)
        case "close":
            replyHandler(nil, nil)
            guard let id = Self.notificationID(body["id"]) else { return }
            tabs.sessionDelegate?.closeWebNotification(id: id, from: session)
        default:
            replyHandler(nil, nil)
        }
    }

    /// Answers every request waiting on the prompt for `host`.
    private func finish(_ host: String, with policy: SitePermissionPolicy) {
        let answer = WebNotificationPolicy.query(stored: policy, isPrivateOrAgent: false)
        for reply in prompts.resolve(host) { reply(answer, nil) }
    }

    /// The shim numbers its notifications; anything long or empty is not one of them.
    private static func notificationID(_ value: Any?) -> String? {
        guard let id = value as? String, (1...64).contains(id.count) else { return nil }
        return id
    }
}

extension PageSession {
    /// Tells the page that notification `id` was clicked, so its own click handler runs.
    public func deliverWebNotificationClick(id: String) {
        webView?.evaluateJavaScript(
            WebNotificationScripts.clickScript(id: id), in: nil, in: WebNotificationScripts.relayWorld)
    }
}
