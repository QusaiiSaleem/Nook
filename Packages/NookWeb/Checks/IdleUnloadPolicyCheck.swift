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
                          capturing: Bool = false, inFullScreen: Bool = false, keepsRunningForAlerts: Bool = false,
                          isFavoriteOrPinned: Bool = false, hasShownUnreadCount: Bool = false,
                          keepsLocalCopy: Bool = false, hasTypedSinceLoad: Bool = false) -> Bool {
        IdleUnloadPolicy.mayUnload(onScreen: onScreen, audible: audible, pictureInPicture: pictureInPicture,
                                   capturing: capturing, inFullScreen: inFullScreen, keepsRunningForAlerts: keepsRunningForAlerts,
                                   isFavoriteOrPinned: isFavoriteOrPinned, hasShownUnreadCount: hasShownUnreadCount,
                                   keepsLocalCopy: keepsLocalCopy, hasTypedSinceLoad: hasTypedSinceLoad)
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
        // Pulling a page out of WebKit's full-screen window strands it in no window.
        precondition(!mayUnload(inFullScreen: true), "a page in full screen was unloaded")

        // An idle favorite that sends no alerts may go...
        precondition(mayUnload(isFavoriteOrPinned: true), "a quiet idle favorite must be unloadable")
        // ...but not one whose badge the person relies on: unread counts come from the live page.
        precondition(!mayUnload(isFavoriteOrPinned: true, hasShownUnreadCount: true), "a favorite showing unread counts was unloaded")
        // Nor WhatsApp while its local copy is on: the copy is read from the live page.
        precondition(!mayUnload(isFavoriteOrPinned: true, keepsLocalCopy: true), "WhatsApp with a local copy was unloaded")
        // Nor a favorite the person has typed into since it loaded: unloading would lose the text.
        precondition(!mayUnload(isFavoriteOrPinned: true, hasTypedSinceLoad: true), "a favorite with typed text was unloaded")
        // Tabs in the tabs section keep their old rules: any site may put "(1)" in its title.
        precondition(mayUnload(hasShownUnreadCount: true, hasTypedSinceLoad: true), "a normal tab's rules changed")
        print("IdleUnloadPolicyCheck passed")
    }
}
