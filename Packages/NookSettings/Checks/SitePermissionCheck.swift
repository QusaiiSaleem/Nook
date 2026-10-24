// Licensed under GPL-3.0. See LICENSE.
//
//  SitePermissionCheck.swift
//  Nook
//
//  Stored per-site answers, notifications included. NookSettings has no test target, so this
//  compiles the shipped source directly:
//
//    swiftc Packages/NookSettings/Sources/NookSettings/SitePermission.swift \
//           Packages/NookSettings/Checks/SitePermissionCheck.swift -o /tmp/site-permission-check && /tmp/site-permission-check
//

import Foundation

@main
struct SitePermissionCheck {
    static func main() throws {
        precondition(SitePermission(rawValue: "notifications") == .notifications)

        // One site, one record: case and a leading www. do not split a decision.
        precondition(SitePermissionRecord.key(for: "Web.WhatsApp.com") == "web.whatsapp.com")
        precondition(SitePermissionRecord.key(for: "www.example.com") == "example.com")

        // A stored notifications answer survives encoding.
        let record = SitePermissionRecord(host: "web.whatsapp.com", policies: [.notifications: .allow, .camera: .block])
        let decoded = try JSONDecoder().decode(SitePermissionRecord.self, from: JSONEncoder().encode(record))
        precondition(decoded == record)
        precondition(decoded.policies[.notifications] == .allow)

        // Records saved before notifications existed still load.
        let old = #"{"host":"example.com","policies":["camera","allow"]}"#
        let legacy = try JSONDecoder().decode(SitePermissionRecord.self, from: Data(old.utf8))
        precondition(legacy.policies[.camera] == .allow && legacy.policies[.notifications] == nil)

        print("SitePermissionCheck passed")
    }
}
