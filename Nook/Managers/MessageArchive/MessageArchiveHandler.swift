// Licensed under GPL-3.0. See LICENSE.
//
//  MessageArchiveHandler.swift
//  Nook
//
//  The native end of the capture relay, registered only in its isolated world. It accepts the
//  main frame of https://web.whatsapp.com in an enabled Space and can only save, delete, and
//  receive media chunks. The account is the Space this handler was installed for.
//

import Foundation
import NookWeb
import WebKit

@MainActor
final class MessageArchiveHandler: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void

    private weak var manager: MessageArchiveManager?
    private weak var session: PageSession?
    private let spaceID: UUID

    init(manager: MessageArchiveManager, session: PageSession, spaceID: UUID) {
        self.manager = manager
        self.session = session
        self.spaceID = spaceID
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping Reply
    ) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == MessageArchiveScripts.handlerName,
              message.world == MessageArchiveScripts.relayWorld,
              let session, let manager,
              MessageArchivePolicy.accepts(
                scheme: origin.protocol, host: origin.host, isMainFrame: message.frameInfo.isMainFrame,
                isPrivateOrAgent: session.isPrivate || session.isAgentPage),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String
        else { return replyHandler(nil, nil) }
        // Turned off: the page stops reading, not just Nook saving.
        guard manager.isEnabled(spaceID: spaceID) else { return replyHandler(["stop": true], nil) }

        let account = spaceID.uuidString
        switch kind {
        case "upsert":
            let raw = (body["messages"] as? [[String: Any]] ?? []).prefix(500)
            let records = raw.compactMap { MessageArchivePolicy.record(from: $0, account: account) }
            let withMedia = raw.filter { $0["hasMedia"] as? Bool == true && $0["viewOnce"] as? Bool != true }
                .compactMap { $0["id"] as? String }
            manager.upsert(records, mediaCandidates: withMedia, account: account) { wanted in
                replyHandler(["needMedia": wanted], nil)
            }
        case "delete":
            let ids = (body["ids"] as? [Any] ?? []).prefix(1000).compactMap { $0 as? String }
            manager.delete(ids: ids, account: account)
            replyHandler(nil, nil)
        case "mediaAttempt":
            guard let id = body["id"] as? String else { return replyHandler(nil, nil) }
            manager.markMedia(id: id, state: "attempted", account: account)
            replyHandler(nil, nil)
        case "mediaFailed":
            guard let id = body["id"] as? String, let reason = body["reason"] as? String,
                  ["unavailable", "tooLarge", "old"].contains(reason) else { return replyHandler(nil, nil) }
            manager.markMedia(id: id, state: reason, account: account)
            replyHandler(nil, nil)
        case "mediaBegin":
            guard let id = body["id"] as? String else { return replyHandler(nil, nil) }
            manager.beginMedia(id: id, fileName: body["fileName"] as? String, mimeType: body["mimeType"] as? String,
                               account: account) { replyHandler(nil, nil) }
        case "mediaChunk":
            guard let id = body["id"] as? String, let base64 = body["base64"] as? String,
                  let data = MessageArchivePolicy.chunk(from: base64) else { return replyHandler(nil, nil) }
            manager.appendMedia(data, id: id, account: account) { replyHandler(nil, nil) }
        case "mediaEnd":
            guard let id = body["id"] as? String else { return replyHandler(nil, nil) }
            manager.finishMedia(id: id, account: account) { replyHandler(nil, nil) }
        case "status":
            manager.setStatus(running: body["state"] as? String == "running", reason: body["reason"] as? String,
                              spaceID: spaceID)
            replyHandler(nil, nil)
        default:
            replyHandler(nil, nil)
        }
    }
}
