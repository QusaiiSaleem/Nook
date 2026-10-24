#!/usr/bin/env python3
"""Per-browser totals: memory footprint (Activity Monitor's "Memory"), CPU time, energy, processes.

Every helper process (Chromium renderers, WebKit WebContent/Networking/GPU) is counted under the
app macOS holds responsible for it (responsibility_get_pid_responsible_for_pid).
Usage: measure.py            -> one JSON line {browser: {...}}
"""
import ctypes
import json
import subprocess
import time

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
RUSAGE_INFO_V6 = 6


class RUsageV6(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size "
        "phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time "
        "child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime "
        "diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance "
        "cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy "
        "cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time "
        "serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles "
        "billed_energy serviced_energy interval_max_phys_footprint runnable_time flags "
        "user_ptime system_ptime pinstructions pcycles energy_nj penergy_nj "
        "secure_time_in_system secure_ptime_in_system neural_footprint "
        "lifetime_max_neural_footprint interval_max_neural_footprint").split()] + [
        ("ri_reserved", ctypes.c_uint64 * 9)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


tb = Timebase()
libc.mach_timebase_info(ctypes.byref(tb))
TICK_NS = tb.numer / tb.denom
libc.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int

APPS = {"Arc": "/Applications/Arc.app/", "Nook": "/nook/build/DerivedData/Build/Products/Release/Nook.app/"}


def processes():
    out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        yield int(pid), comm


def snapshot():
    procs = dict(processes())
    roots = {name: [p for p, c in procs.items() if path in c and c.endswith(("MacOS/Arc", "MacOS/Nook"))]
             for name, path in APPS.items()}
    totals = {name: {"footprint_mb": 0.0, "cpu_s": 0.0, "energy_j": 0.0, "processes": 0} for name in APPS}
    for pid in procs:
        owner = libc.responsibility_get_pid_responsible_for_pid(pid)
        for name, rootpids in roots.items():
            if owner in rootpids or pid in rootpids:
                ru = RUsageV6()
                if libc.proc_pid_rusage(pid, RUSAGE_INFO_V6, ctypes.byref(ru)) != 0:
                    continue
                t = totals[name]
                t["footprint_mb"] += ru.phys_footprint / 2**20
                t["cpu_s"] += (ru.user_time + ru.system_time) * TICK_NS / 1e9
                t["energy_j"] += ru.energy_nj / 1e9
                t["processes"] += 1
    return {"t": time.time(), **{k: {kk: round(vv, 2) for kk, vv in v.items()} for k, v in totals.items()}}


if __name__ == "__main__":
    print(json.dumps(snapshot()))
