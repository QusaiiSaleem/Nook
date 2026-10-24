// Licensed under GPL-3.0. See LICENSE.
//
//  WebNotificationPolicyCheck.swift
//  Nook
//
//  What Nook answers when a page asks about notifications, and when it may show one.
//  NookWeb has no test target, so this compiles the shipped source directly:
//
//    swiftc Packages/NookSettings/Sources/NookSettings/SitePermission.swift \
//           Packages/NookWeb/Sources/NookWeb/WebNotificationPolicy.swift \
//           Packages/NookWeb/Checks/WebNotificationPolicyCheck.swift -o /tmp/wnpol && /tmp/wnpol
//

import Foundation

@main
struct WebNotificationPolicyCheck {
    static func main() {
        // A request prompts only while the site has no stored answer.
        precondition(WebNotificationPolicy.answer(stored: .ask, isPrivateOrAgent: false) == .prompt)
        precondition(WebNotificationPolicy.answer(stored: .block, isPrivateOrAgent: false) == .reply("denied"), "no second prompt after Block")
        precondition(WebNotificationPolicy.answer(stored: .allow, isPrivateOrAgent: false) == .reply("granted"))

        // Private windows and the Agent space never prompt.
        precondition(WebNotificationPolicy.answer(stored: .ask, isPrivateOrAgent: true) == .reply("denied"))
        precondition(WebNotificationPolicy.answer(stored: .allow, isPrivateOrAgent: true) == .reply("denied"))

        // Notification.permission at document start.
        precondition(WebNotificationPolicy.query(stored: .ask, isPrivateOrAgent: false) == "default")
        precondition(WebNotificationPolicy.query(stored: .allow, isPrivateOrAgent: false) == "granted")
        precondition(WebNotificationPolicy.query(stored: .block, isPrivateOrAgent: false) == "denied")
        precondition(WebNotificationPolicy.query(stored: .allow, isPrivateOrAgent: true) == "denied")

        // Showing is decided again at show time, so Block takes effect on an open page.
        precondition(WebNotificationPolicy.mayShow(stored: .allow, isPrivateOrAgent: false))
        precondition(!WebNotificationPolicy.mayShow(stored: .block, isPrivateOrAgent: false))
        precondition(!WebNotificationPolicy.mayShow(stored: .ask, isPrivateOrAgent: false))
        precondition(!WebNotificationPolicy.mayShow(stored: .allow, isPrivateOrAgent: true))

        // Only secure pages may use notifications, as in browsers: a plain-http copy of a site
        // (which a network can forge) must not inherit the https site's answer.
        precondition(WebNotificationPolicy.isSecure(scheme: "https", host: "web.whatsapp.com"))
        precondition(!WebNotificationPolicy.isSecure(scheme: "http", host: "web.whatsapp.com"))
        precondition(WebNotificationPolicy.isSecure(scheme: "http", host: "localhost"))
        precondition(WebNotificationPolicy.isSecure(scheme: "http", host: "127.0.0.1"))
        precondition(!WebNotificationPolicy.isSecure(scheme: "file", host: ""))
        precondition(!WebNotificationPolicy.isSecure(scheme: "https", host: ""))

        // Which pages keep running with no window: favorites and pinned tabs of a secure site the
        // person allowed. Everything else unloads as before.
        let whatsapp = URL(string: "https://web.whatsapp.com/")
        precondition(WebNotificationPolicy.keepsRunning(isSynced: true, url: whatsapp, stored: .allow))
        precondition(!WebNotificationPolicy.keepsRunning(isSynced: false, url: whatsapp, stored: .allow), "a Today tab unloads")
        precondition(!WebNotificationPolicy.keepsRunning(isSynced: true, url: whatsapp, stored: .ask))
        precondition(!WebNotificationPolicy.keepsRunning(isSynced: true, url: whatsapp, stored: .block))
        precondition(!WebNotificationPolicy.keepsRunning(isSynced: true, url: URL(string: "http://web.whatsapp.com/"), stored: .allow))
        precondition(!WebNotificationPolicy.keepsRunning(isSynced: true, url: nil, stored: .allow))
        precondition(!WebNotificationPolicy.keepsRunning(isSynced: true, isAgent: true, url: whatsapp, stored: .allow),
                     "an Agent-space page never keeps running")

        // Requests arriving while a prompt is open for the same site join it.
        var prompts = WebNotificationPrompts<Int>()
        precondition(prompts.add(1, for: "web.whatsapp.com"), "the first request opens a prompt")
        precondition(!prompts.add(2, for: "web.whatsapp.com"), "a second request joins it")
        precondition(prompts.add(3, for: "example.com"), "another site gets its own prompt")
        precondition(prompts.resolve("web.whatsapp.com") == [1, 2])
        precondition(prompts.resolve("web.whatsapp.com").isEmpty)
        precondition(prompts.add(4, for: "web.whatsapp.com"), "after the answer, a new request may prompt again")

        print("WebNotificationPolicyCheck passed")
    }
}
