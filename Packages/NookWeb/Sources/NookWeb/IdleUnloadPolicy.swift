// Licensed under GPL-3.0. See LICENSE.
//
//  IdleUnloadPolicy.swift
//  Nook
//
//  Which hidden pages Nook may unload on its own (idle timeout, memory pressure, the Power Saving
//  budget). Favorites and pinned tabs used to be kept loaded for ever; now an idle one gives its
//  memory back unless it keeps running for alerts, shows unread counts, keeps WhatsApp's local
//  copy, or holds text the person typed. Unloading keeps the tab in the sidebar; selecting it
//  loads the page again.
//

public enum IdleUnloadPolicy {
    public static func mayUnload(onScreen: Bool, audible: Bool, pictureInPicture: Bool, capturing: Bool,
                                 inFullScreen: Bool, keepsRunningForAlerts: Bool, isFavoriteOrPinned: Bool,
                                 hasShownUnreadCount: Bool, keepsLocalCopy: Bool, hasTypedSinceLoad: Bool) -> Bool {
        // A silent video nobody can see is not a reason to keep a page (news sites loop muted
        // clips forever); audible media and picture-in-picture are. Unloading a page in full
        // screen would pull it out of WebKit's full-screen window and strand it.
        if onScreen || audible || pictureInPicture || capturing || inFullScreen || keepsRunningForAlerts { return false }
        // What a favorite or pinned tab offers only while loaded: its unread count (badge, space
        // dot, Dock), WhatsApp's local copy, and text the person typed since it loaded. Tabs in
        // the tabs section keep their old rules: any site may put "(1)" in its title.
        if isFavoriteOrPinned, hasShownUnreadCount || keepsLocalCopy || hasTypedSinceLoad { return false }
        return true
    }
}
