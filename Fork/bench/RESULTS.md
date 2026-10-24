# Nook (fork, Release) vs Arc 1.169 — same 10 sites, 2026-10-24

Method: `bench.py`. Same 10 public sites in each browser, each tab shown and waited for
(Arc: AppleScript `select` + `loading`; Nook: DevMCP `createTab` + `wait_for_load`), settle 60 s,
then 2 min idle. Memory = phys_footprint (Activity Monitor's Memory) summed over every process
the browser is responsible for. Numbers are the change each browser shows, because Arc already
held Qusai's own tabs (~4 GB) during the test.

Sites: Wikipedia, YouTube, GitHub (Nook repo), BBC News, Apple, MDN JavaScript, r/apple,
The Verge, Stack Overflow, Al Jazeera (Arabic).

| Same 10 sites (run 3) | Arc | Nook |
|---|---|---|
| Memory added | +2,933 MB | **+2,432 MB** (−17%) |
| Processes added | +43 | **+10** |
| CPU to load + settle | 64.0 s | 62.1 s |
| Energy to load + settle | 33.0 J | 33.4 J |
| Idle 2 min, CPU of the test pages | **4.3 s** | 18.1 s |
| Idle 2 min, energy of the test pages | **0.7 J** | 3.5 J |

Caveats:
- Nook's pages ran in the Agent Space (DevMCP), which keeps the agent's page visible to WebKit
  (60 rAF, occlusion detection off) by design; Arc throttles background tabs hard. The idle rows
  favour Arc for that reason; a fair idle test needs the pages in a normal Space (manual).
- Run 1: Arc's `make new window` returns missing value, so Arc opened nothing (discarded).
- Run 2: Arc leaves background tabs unloaded until shown (+3 processes, +435 MB); not comparable.
- Load seconds are not comparable (different "loaded" signals).
- One run each; web content varies minute to minute (ads, video).

Raw: `results.json` (run 3), `results-run2-arc-lazy.json`, logs `bench*.log`.
