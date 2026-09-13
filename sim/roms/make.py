#!/usr/bin/env python3
"""Build the TIA test cartridges and record their Sim2600 traces.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

    python make.py --list
    python make.py --roms-only                     # just the .bin files
    python make.py --sim2600 ../../../Sim2600      # every test, in parallel
    python make.py --sim2600 ../../../Sim2600 players

Cartridges go to sim/roms/build/, traces to sim/traces/. These traces come from
cartridges written for this project, so unlike traces of commercial games they
are committed.
"""

import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import tests  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="tests to build (default: all)")
    ap.add_argument("--list", action="store_true", help="list the tests and stop")
    ap.add_argument("--roms-only", action="store_true", help="build cartridges only")
    ap.add_argument("--sim2600", help="path to a patched Sim2600 checkout")
    ap.add_argument("--jobs", type=int, default=4,
                    help="Sim2600 runs in parallel (default 4)")
    args = ap.parse_args()

    names = args.names or sorted(tests.TESTS)
    unknown = [n for n in names if n not in tests.TESTS]
    if unknown:
        sys.exit("unknown test(s): %s" % ", ".join(unknown))

    build_dir = os.path.join(HERE, "build")
    os.makedirs(build_dir, exist_ok=True)

    jobs = []
    for name in names:
        rom, half_clocks = tests.TESTS[name]()
        path = os.path.join(build_dir, name + ".bin")
        with open(path, "wb") as f:
            f.write(rom)
        if args.list:
            print("%-16s %6d half clocks  (%.0f s of Sim2600)"
                  % (name, half_clocks, half_clocks * 0.003))
        jobs.append((name, path, half_clocks))

    if args.list or args.roms_only:
        return 0
    if not args.sim2600:
        sys.exit("--sim2600 is needed to record traces (or use --roms-only)")

    traces = os.path.join(SIM, "traces")
    os.makedirs(traces, exist_ok=True)

    running = []
    pending = list(jobs)
    failed = []
    start = time.time()
    while pending or running:
        while pending and len(running) < args.jobs:
            name, rom, count = pending.pop(0)
            cmd = [sys.executable, os.path.join(SIM, "gen_trace.py"),
                   "--sim2600", args.sim2600, "--rom", rom,
                   "--skip", "0", "--count", str(count), "--quiet",
                   "--out", os.path.join(traces, name + ".trace")]
            print("recording %s (%d half clocks)" % (name, count))
            running.append((name, subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                                   stderr=subprocess.STDOUT, text=True)))
        for entry in list(running):
            name, proc = entry
            if proc.poll() is not None:
                out = proc.stdout.read()
                running.remove(entry)
                if proc.returncode:
                    failed.append(name)
                    print("FAILED %s:\n%s" % (name, out))
                else:
                    print("done %s: %s" % (name, out.strip().splitlines()[-1]))
        time.sleep(1)

    print("%d traces in %.0f s" % (len(jobs) - len(failed), time.time() - start))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
