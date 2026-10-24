// Licensed under GPL-3.0. See LICENSE.
//
//  IdleUnloadPolicyCheck.swift
//  Nook
//
//  Which hidden pages Nook unloads on its own. NookWeb has no test target, so this compiles the
//  shipped source directly:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/IdleUnloadPolicy.swift \
//           Packages/NookWeb/Checks/IdleUnloadPolicyCheck.swift -o /tmp/iup && /tmp/iup
//

@main
struct IdleUnloadPolicyCheck {
    static func mayUnload(onScreen: Bool = false, audible: Bool = false, pictureInPicture: Bool = false,
                          capturing: Bool = false, keepsRunningForAlerts: Bool = false) -> Bool {
        IdleUnloadPolicy.mayUnload(onScreen: onScreen, audible: audible, pictureInPicture: pictureInPicture,
                                   capturing: capturing, keepsRunningForAlerts: keepsRunningForAlerts)
    }

    static func main() {
        // An idle page nobody sees gives its memory back, favorites and pinned tabs included: an
        // untouched Zoho or claude.ai favorite held about 2.3 GB for hours on 2026-10-24.
        precondition(mayUnload(), "a quiet hidden page must be unloadable")
        // A favorite that keeps running for its alerts (WhatsApp, Gmail with notifications on) stays,
        // or its banners and unread count would stop.
        precondition(!mayUnload(keepsRunningForAlerts: true), "a page kept running for alerts was unloaded")
        precondition(!mayUnload(onScreen: true), "a page on screen was unloaded")
        precondition(!mayUnload(audible: true), "a page playing sound was unloaded")
        precondition(!mayUnload(pictureInPicture: true), "a page in picture-in-picture was unloaded")
        precondition(!mayUnload(capturing: true), "a page using the camera or microphone was unloaded")
        print("IdleUnloadPolicyCheck passed")
    }
}
