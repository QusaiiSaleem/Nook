// Licensed under GPL-3.0. See LICENSE.
//
//  IdleUnloadPolicy.swift
//  Nook
//
//  Which hidden pages Nook may unload on its own (idle timeout, memory pressure, the Power Saving
//  budget). Favorites and pinned tabs used to be kept loaded for ever; now only a page that keeps
//  running for its alerts is, so an idle favorite gives its memory back and WhatsApp keeps its
//  connection. Unloading keeps the tab in the sidebar; selecting it loads the page again.
//

public enum IdleUnloadPolicy {
    public static func mayUnload(onScreen: Bool, audible: Bool, pictureInPicture: Bool, capturing: Bool,
                                 keepsRunningForAlerts: Bool) -> Bool {
        // A silent video nobody can see is not a reason to keep a page (news sites loop muted
        // clips forever); audible media and picture-in-picture are.
        !onScreen && !audible && !pictureInPicture && !capturing && !keepsRunningForAlerts
    }
}
