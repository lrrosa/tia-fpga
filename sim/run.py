#!/usr/bin/env python3
"""Build the TIA core with Icarus Verilog and replay a Sim2600 trace into it.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

    python run.py                          # traces/ and traces/local/
    python run.py traces/local/donkeykong-power-on.trace
    python run.py --debug --from 680 --to 700 traces/...   # dump the guts

Exits non-zero if any trace fails, so it works as a pre-commit check.
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(os.path.dirname(HERE), "rtl")


def find_tool(name):
    """Icarus is often installed somewhere that is not on PATH on Windows."""
    found = shutil.which(name)
    if found:
        return found
    for candidate in (
        r"C:\iverilog\bin",
        r"C:\Program Files\iverilog\bin",
        "/usr/local/bin",
        "/usr/bin",
    ):
        path = os.path.join(candidate, name + (".exe" if os.name == "nt" else ""))
        if os.path.exists(path):
            return path
    sys.exit(
        "%s not found. Install Icarus Verilog (winget install Icarus.Verilog,\n"
        "apt install iverilog, brew install icarus-verilog) or put it on PATH."
        % name
    )


def build(top, tb_source, out):
    cmd = [find_tool("iverilog"), "-g2005", "-I", RTL, "-o", out, "-s", top,
           tb_source] + sorted(glob.glob(os.path.join(RTL, "*.v")))
    result = subprocess.run(cmd)
    if result.returncode != 0:
        sys.exit("compile failed")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="*", help="trace files (default: traces/*.trace)")
    ap.add_argument("--debug", action="store_true",
                    help="use the debug testbench and dump internal state")
    ap.add_argument("--align", type=int, help="force the replay alignment")
    ap.add_argument("--from", dest="dfrom", type=int, default=0,
                    help="--debug: first record to print")
    ap.add_argument("--to", dest="dto", type=int, default=200,
                    help="--debug: last record to print")
    ap.add_argument("--first", type=int, default=20,
                    help="how many mismatches to describe in detail")
    ap.add_argument("--quiet", action="store_true", help="summary only")
    args = ap.parse_args()

    traces = args.traces or sorted(
        glob.glob(os.path.join(HERE, "traces", "*.trace")) +
        glob.glob(os.path.join(HERE, "traces", "local", "*.trace")))
    if not traces:
        sys.exit("no traces. Make one with gen_trace.py -- see README.md.")

    tmp = tempfile.mkdtemp(prefix="tia-sim-")
    vvp_file = os.path.join(tmp, "tb.vvp")
    tb = "tb_debug" if args.debug else "tb_trace"
    build(tb, os.path.join(HERE, tb + ".v"), vvp_file)

    failures = 0
    for trace in traces:
        print("=" * 70)
        print(trace)
        print("=" * 70)
        cmd = [find_tool("vvp"), vvp_file, "+trace=" + trace]
        if args.align is not None:
            cmd.append("+align=%d" % args.align)
        if args.debug:
            cmd += ["+from=%d" % args.dfrom, "+to=%d" % args.dto]
        else:
            cmd.append("+first=%d" % args.first)
            if args.quiet:
                cmd.append("+quiet")
        out = subprocess.run(cmd, capture_output=True, text=True)
        sys.stdout.write(out.stdout)
        sys.stderr.write(out.stderr)
        if not args.debug and "PASS" not in out.stdout:
            failures += 1

    shutil.rmtree(tmp, ignore_errors=True)

    if not args.debug:
        print()
        print("%d of %d traces passed" % (len(traces) - failures, len(traces)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
