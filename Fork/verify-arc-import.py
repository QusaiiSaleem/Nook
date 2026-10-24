#!/usr/bin/env python3
"""Fork/verify-arc-import.py: compare Arc's sidebar with this Nook's tabs, item by item.

Read-only. Prints, per Space: every Arc favorite, pinned tab/folder and Today tab, and
whether Nook has it in the same place (Space > section > folder path), with the same title,
in the same order.

Usage: Fork/verify-arc-import.py [nook-bundle-id]      (default com.qusai.nook)
"""
import json
import os
import sys

HOME = os.path.expanduser("~")
ARC = f"{HOME}/Library/Application Support/Arc/StorableSidebar.json"
BUNDLE = sys.argv[1] if len(sys.argv) > 1 else "com.qusai.nook"
NOOK = f"{HOME}/Library/Application Support/{BUNDLE}/Tabs"


def pairs(flat):
    """Arc stores maps as [key, value, key, value, ...]."""
    return [(flat[i], flat[i + 1]) for i in range(0, len(flat) - 1, 2)]


def profile_name(p):
    if not isinstance(p, dict):
        return None
    if "default" in p:
        return "default"
    return p.get("custom", {}).get("_0", {}).get("directoryBasename")


# ---------- Arc: entries = (space, section, folder path, url, title) in Arc order ----------
def load_arc():
    side = json.load(open(ARC))["sidebar"]["containers"][1]
    items = {k: v for k, v in pairs(side["items"]) if isinstance(k, str)}
    spaces = [v for k, v in pairs(side["spaces"]) if isinstance(k, str)]
    favorites = {profile_name(k): cid for k, cid in pairs(side.get("topAppsContainerIDs", []))}

    def walk(cid, path, out, splits):
        for child in items.get(cid, {}).get("childrenIds", []):
            it = items.get(child, {})
            data = it.get("data", {})
            if "tab" in data:
                tab = data["tab"] or {}
                out.append((path, tab.get("savedURL", ""), it.get("title") or tab.get("savedTitle") or ""))
            elif "splitView" in data:
                # A split's tabs sit at the split's place; the pair itself is checked separately.
                kids = [items.get(k, {}) for k in it.get("childrenIds", [])]
                splits.append(tuple(norm((k.get("data", {}).get("tab") or {}).get("savedURL", "")) for k in kids))
                walk(child, path, out, splits)
            else:  # list = folder
                walk(child, path + (it.get("title") or "",), out, splits)

    result = []
    for s in spaces:
        ids = dict((k, v) for k, v in pairs(s.get("containerIDs", [])) if isinstance(k, str))
        entry = {"name": s.get("title", ""), "sections": {}, "splits": []}
        for section, cid in (("favorites", favorites.get(profile_name(s.get("profile")))),
                             ("pinned", ids.get("pinned")), ("tabs", ids.get("unpinned"))):
            out = []
            if cid:
                walk(cid, (), out, entry["splits"])
            entry["sections"][section] = out
        result.append(entry)
    return result


# ---------- Nook: same shape, ordered by each item's order key ----------
def load_nook():
    structure = json.load(open(f"{NOOK}/structure.json"))
    device = json.load(open(f"{NOOK}/device.json")) if os.path.exists(f"{NOOK}/device.json") else {}
    # Deleted spaces and items stay in the files for 30 days as tombstones (deletedAt set).
    items = [i for i in structure.get("items", []) + device.get("items", []) if not i.get("deletedAt")]
    children = {}
    for it in items:
        (kind, ref), = it["parent"].items()
        key = (kind, ref.get("spaceID") or ref.get("itemID"))
        children.setdefault(key, []).append(it)
    for kids in children.values():
        kids.sort(key=lambda i: i["order"])

    def walk(key, path, out, splits):
        for it in children.get(key, []):
            if "tab" in it["kind"]:
                tab = it["kind"]["tab"]
                out.append((path, tab.get("url", ""), it.get("customTitle") or tab.get("pageTitle") or ""))
                walk(("folder", it["id"]), path, out, splits)  # trails: tabs opened from this tab
            elif it.get("split") is not None:
                # A saved split is not a folder level: its two tabs sit at its place.
                kids = children.get(("folder", it["id"]), [])
                splits.append(tuple(norm(k["kind"].get("tab", {}).get("url", "")) for k in kids))
                walk(("folder", it["id"]), path, out, splits)
            else:
                walk(("folder", it["id"]), path + (it.get("customTitle") or "",), out, splits)

    result = []
    # The Agent space (DevMCP's, marked in its icon) is Nook's own, not an imported one.
    spaces = (s for s in structure["spaces"] if not s.get("deletedAt") and not str(s.get("icon", "")).startswith("nook.agent:"))
    for s in sorted(spaces, key=lambda s: s["order"]):
        entry = {"name": s["name"], "sections": {}, "splits": []}
        for section in ("favorites", "pinned", "tabs"):
            out = []
            walk((section, s["id"]), (), out, entry["splits"])
            entry["sections"][section] = out
        result.append(entry)
    return result


def norm(url):
    return url.rstrip("/")


def main():
    arc, nook = load_arc(), load_nook()
    nook_by_name = {s["name"]: s for s in nook}
    problems = 0
    print(f"Space order  Arc : {[s['name'] for s in arc]}")
    print(f"             Nook: {[s['name'] for s in nook]}")
    extra = [s["name"] for s in nook if s["name"] not in {a["name"] for a in arc}]
    if extra:
        print(f"  ! extra Spaces in Nook (not in Arc): {extra}")
        problems += len(extra)
    if [s["name"] for s in arc] != [s["name"] for s in nook if s["name"] in {a["name"] for a in arc}]:
        print("  ! Space order differs")
        problems += 1

    for a in arc:
        n = nook_by_name.get(a["name"])
        print(f"\n=== {a['name']} ===")
        if not n:
            print("  ! Space missing in Nook")
            problems += 1
            continue
        nook_all = {sec: n["sections"][sec] for sec in n["sections"]}
        for sec, entries in a["sections"].items():
            ok = 0
            for path, url, title in entries:
                where = [(s, p, t) for s, lst in nook_all.items() for p, u, t in lst if norm(u) == norm(url)]
                place = " > ".join((sec,) + path)
                if not where:
                    print(f"  ✗ missing    {place} :: {title or url}")
                    problems += 1
                elif not any(s == sec and p == path for s, p, _ in where):
                    s, p, _ = where[0]
                    print(f"  ✗ misplaced  {place} :: {title or url}   (Nook: {' > '.join((s,) + p)})")
                    problems += 1
                elif not any(s == sec and p == path and t == title for s, p, t in where):
                    t = next(t for s, p, t in where if s == sec and p == path)
                    print(f"  ~ title      {place} :: Arc {title!r} vs Nook {t!r}")
                    problems += 1
                else:
                    ok += 1
            order_arc = [norm(u) for _, u, _ in entries]
            order_nook = [norm(u) for _, u, _ in n["sections"][sec] if norm(u) in set(order_arc)]
            in_order = order_nook == [u for u in order_arc if u in set(order_nook)]
            print(f"  {sec:9} {ok}/{len(entries)} in place" + ("" if in_order else "   ✗ ORDER differs"))
            problems += 0 if in_order else 1
        for pair in a["splits"]:
            if pair in n["splits"]:
                print(f"  ✓ split      {' | '.join(pair)}")
            else:
                print(f"  ✗ split lost {' | '.join(pair)}")
                problems += 1

    print(f"\n{'ALL MATCH ✓' if problems == 0 else f'{problems} problem(s)'}")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
