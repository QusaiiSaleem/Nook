# Qusai's Nook fork

A personal fork of [Nook](https://github.com/nook-browser/Nook) (GPL-3.0) on branch `qusai`,
based on official releases. Everything that makes this copy different lives in `Fork/` or in
small, clearly marked changes, so official releases merge cleanly.

## What's different from Nook

- **Arc import** that keeps Arc's order, folders inside folders, titles, favorites per Space and
  Space colors, and brings Arc split views in as saved splits.
- **Saved splits** (Arc-style): two tabs side by side as one sidebar row that can be pinned, put in
  a folder, dragged, and kept across relaunches. Hold a dragged tab over another tab's middle for a
  moment to make one; drag the gap between the pages to resize; *Separate Tabs* to undo.
- **Capture Full Page**: the camera button in the address bar saves the whole page as a PNG and
  copies it.
- **Magic Mouse**: one-finger swipe on the sidebar switches Spaces, as in Arc.
- **WhatsApp in Spaces**: Mac notifications from any site that asks, unread counts on Favorites,
  and per Space an optional local, searchable copy of WhatsApp ("Keep a Local Copy" in the
  WhatsApp site menu). The copy stays on this Mac and only reads.
- **Auto-archive**: a Today tab nobody looked at for 12 hours closes into History, as in Arc.
- **Capture Area**: the camera menu marks a part of the page, with an arrow or a highlight.
- **Idle favorites unload**: idle Favorites and pinned tabs give their memory back, except pages
  that alert you, show unread counts, keep WhatsApp's copy, hold typed text, or are in full screen.
- **Mobile View**: ⋯ More → Mobile View shows a tab as an iPhone would.
- **Space marks**: an emoji or your own SVG in place of a Space's dot (Settings > Spaces).
- **Agent testing tools** for Claude Code (Developer Mode + Browser Control): `inspect`, `type`,
  `upload`, `record_start`/`record_stop` and slow-network profiles.
- Its own app ID (`com.qusai.nook`), so it never shares data with an official Nook.

## Daily use

| Task | Command |
|---|---|
| Get the newest official Nook release, keep these changes, rebuild, install | `Fork/update.sh` |
| Only check whether a newer official release exists | `Fork/update.sh --check` |
| Build and install the current code | `Fork/build.sh --install` |
| Tab model tests | `cd Packages/NookTabsCore && swift test` |
| Re-install the pinned WA-JS, or fetch a newer release to pin (when the WhatsApp copy pauses) | `Fork/update-wa-js.sh [tag]` |
| Compare Arc's sidebar with this Nook's tabs, item by item | `Fork/verify-arc-import.py` |
| Nook vs Arc memory/CPU benchmark | `Fork/bench/bench.py` (needs Settings > Developer > Browser Control on) |

`Fork/update.sh` stops before building on a merge conflict and prints how to undo it.

## Sharing with friends

**Not yet allowed under the name "Nook".** Nook's [TRADEMARK.md](../TRADEMARK.md): building and
running it for yourself under any name is fine, but *distributing a modified Nook named "Nook"*
needs the maintainer's permission. "Rename your fork and use your own icon. That is the whole
requirement." So, before a friend gets a build, one of:

1. **Ask permission**: open an issue at https://github.com/nook-browser/Nook/issues, for example:

   > Hi Bain, I keep a personal fork of Nook (github.com/QusaiiSaleem/Nook, branch `qusai`) with
   > an improved Arc import, Arc-style saved splits and a full-page capture. A few friends would
   > like to use it. May I share builds with them under the Nook name, with a note that it is an
   > unofficial fork? If not, I'll rename it and use my own icon. (My Arc import fix is also
   > offered upstream as a pull request.)

2. **Rename it**: pick a name and design an icon (not Nook's), then set them in `Fork/build.sh`
   (`PRODUCT_NAME`/`INFOPLIST_KEY_CFBundleDisplayName` overrides and an `ASSETCATALOG_COMPILER_APPICON_NAME`
   pointing at a new icon set under `Fork/`).

**What a friend does** (free signing, no paid Apple account): unzip, move the app to Applications,
open it once, then System Settings > Privacy & Security > *Open Anyway*. GPL-3.0 also means they
must be able to get the source: this public repo covers that.

**Updates for friends** (later): create a Sparkle signing key, put the public key in
`Fork/build.sh` (`SUPublicEDKey`), turn `AUTO_CHECKS` on, and publish each zip with an
`appcast.xml` at the `FEED_URL` already set in `Fork/build.sh`.
