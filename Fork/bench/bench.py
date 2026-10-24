#!/usr/bin/env python3
"""Nook vs Arc: the same 10 sites, measured as the change each browser shows.

Phases: baseline -> Arc opens the sites (new window), waits for load, settles 60 s -> Nook opens
the same sites (DevMCP, Agent space), waits, settles 60 s -> both idle 120 s -> close test tabs.
Writes results.json next to this file.
"""
import ctypes
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.argv = [sys.argv[0]]


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


measure, mcp = load("measure"), load("mcp")

URLS = [
    "https://en.wikipedia.org/wiki/Web_browser",
    "https://www.youtube.com/",
    "https://github.com/nook-browser/Nook",
    "https://www.bbc.com/news",
    "https://www.apple.com/",
    "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
    "https://www.reddit.com/r/apple/",
    "https://www.theverge.com/",
    "https://stackoverflow.com/questions",
    "https://www.aljazeera.net/",
]
SETTLE, IDLE = 60, 120


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def per_process():
    """{browser: {pid: (footprint_mb, cpu_s, energy_j)}}"""
    procs = dict(measure.processes())
    roots = {n: [p for p, c in procs.items() if path in c and c.endswith(("MacOS/Arc", "MacOS/Nook"))]
             for n, path in measure.APPS.items()}
    out = {n: {} for n in measure.APPS}
    for pid in procs:
        owner = measure.libc.responsibility_get_pid_responsible_for_pid(pid)
        for n, rp in roots.items():
            if owner in rp or pid in rp:
                ru = measure.RUsageV6()
                if measure.libc.proc_pid_rusage(pid, 6, ctypes.byref(ru)) == 0:
                    out[n][pid] = (ru.phys_footprint / 2**20,
                                   (ru.user_time + ru.system_time) * measure.TICK_NS / 1e9,
                                   ru.energy_nj / 1e9)
    return out


def total(snap, browser, pids=None):
    rows = [v for p, v in snap[browser].items() if pids is None or p in pids]
    return {"footprint_mb": round(sum(r[0] for r in rows), 1), "cpu_s": round(sum(r[1] for r in rows), 2),
            "energy_j": round(sum(r[2] for r in rows), 2), "processes": len(rows)}


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=180).stdout.strip()


def arc_tab_ids(wid):
    out = osa(f'tell application "Arc" to get id of every tab of window id "{wid}"')
    return {t.strip() for t in out.split(",") if t.strip()}


def arc_open():
    """Adds the sites to Arc's front window. `make new window` returns missing value in Arc
    1.169, so the test tabs are found as the tab ids that are new afterwards."""
    wid = osa('tell application "Arc" to get id of front window')
    before = arc_tab_ids(wid)
    urls = "{" + ", ".join(f'"{u}"' for u in URLS) + "}"
    osa(f'''tell application "Arc"
        repeat with u in {urls}
            tell window id "{wid}" to make new tab with properties {{URL:u}}
        end repeat
    end tell''')
    new = arc_tab_ids(wid) - before
    log(f"Arc: {len(new)} new tabs in window {wid[:8]}")
    # Arc leaves background tabs unloaded until shown, so show each one and wait for its load,
    # the way Nook's run selects each tab and waits (wait_for_load, 30 s).
    start = time.time()
    for t in new:
        osa(f'tell application "Arc" to select tab id "{t}" of window id "{wid}"')
        began = time.time()
        while time.time() - began < 30:
            time.sleep(1)
            if osa(f'tell application "Arc" to get loading of tab id "{t}" of window id "{wid}"') == "false":
                break
    return wid, new, round(time.time() - start, 1)


def arc_close(wid, new):
    for t in new:
        osa(f'tell application "Arc" to close tab id "{t}" of window id "{wid}"')


def nook_call(tool, args=None):
    mcp.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}})
    return mcp.rpc("tools/call", {"name": tool, "arguments": args or {}}, rid=3)


def nook_open():
    start = time.time()
    for u in URLS:
        nook_call("createTab", {"url": u})
        nook_call("wait_for_load", {"timeout": 30})
    return round(time.time() - start, 1)


def main():
    results = {"urls": URLS, "settle_s": SETTLE, "idle_s": IDLE}
    nook_call("closeTabs", {"regular": True})          # empty the Agent space first
    time.sleep(5)
    s0 = per_process(); log(f"baseline  Arc {total(s0,'Arc')}  Nook {total(s0,'Nook')}")

    wid, arc_new, arc_load = arc_open(); log(f"Arc loaded {len(arc_new)} sites in {arc_load}s")
    if len(arc_new) != len(URLS):
        log("ABORT: Arc did not open every test tab"); arc_close(wid, arc_new); return
    time.sleep(SETTLE)
    s1 = per_process(); log(f"Arc settled {total(s1,'Arc')}")

    nook_load = nook_open(); log(f"Nook loaded 10 sites in {nook_load}s")
    time.sleep(SETTLE)
    s2 = per_process(); log(f"Nook settled {total(s2,'Nook')}")

    time.sleep(IDLE)
    s3 = per_process(); log("idle window done")

    for b, before, after in (("Arc", s0, s1), ("Nook", s1, s2)):
        new = set(after[b]) - set(before[b])
        a, z = total(before, b), total(after, b)
        idle_new_a, idle_new_z = total(s2 if b == "Arc" else s2, b, new), total(s3, b, new)
        idle_all_a, idle_all_z = total(s2, b), total(s3, b)
        results[b] = {
            "load_seconds": arc_load if b == "Arc" else nook_load,
            "memory_added_mb": round(z["footprint_mb"] - a["footprint_mb"], 1),
            "processes_added": z["processes"] - a["processes"],
            "cpu_s_to_load_and_settle": round(z["cpu_s"] - a["cpu_s"], 1),
            "energy_j_to_load_and_settle": round(z["energy_j"] - a["energy_j"], 1),
            "idle_cpu_s_new_processes": round(idle_new_z["cpu_s"] - idle_new_a["cpu_s"], 2),
            "idle_energy_j_new_processes": round(idle_new_z["energy_j"] - idle_new_a["energy_j"], 2),
            "idle_cpu_s_whole_browser": round(idle_all_z["cpu_s"] - idle_all_a["cpu_s"], 2),
            "before": a, "after": z,
        }
    json.dump(results, open(os.path.join(HERE, "results.json"), "w"), indent=2)
    log(json.dumps({b: {k: v for k, v in results[b].items() if k not in ("before", "after")} for b in ("Arc", "Nook")}, indent=1))

    arc_close(wid, arc_new)
    nook_call("closeTabs", {"regular": True})
    log("test tabs closed in both browsers")


if __name__ == "__main__":
    main()
