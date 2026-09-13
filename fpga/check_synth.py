#!/usr/bin/env python3
"""Synthesise the TIA core for the Tang Nano 9K's GW1NR-9 with Yosys.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

This is a check, not a build: it runs Yosys's synth_gowin on rtl/ and reports
what the core uses and whether Yosys had anything to complain about. It does
not place, route or time anything, and it knows nothing about the board -- the
real bitstream still has to come out of Gowin EDA, with a wrapper that maps the
core onto fpga/tia_fpga.cst.

    pip install yowasp-yosys        # or have a native yosys on PATH
    python fpga/check_synth.py

Exits non-zero if Yosys warns about anything.
"""

import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# GW1NR-LV9QN88PC6/I5, the part on the Tang Nano 9K.
LUT4_AVAILABLE = 8640
FF_AVAILABLE = 6480


def yosys_command():
    native = shutil.which("yosys")
    if native:
        return [native]
    try:
        import yowasp_yosys  # noqa: F401
    except ImportError:
        sys.exit("No Yosys found. Install one with `pip install yowasp-yosys`, "
                 "or put a native yosys on PATH.")
    return [sys.executable, "-c",
            "import sys, yowasp_yosys; sys.argv[0] = 'yosys'; "
            "sys.exit(yowasp_yosys._run_yosys_argv())"]


def main():
    sources = sorted("rtl/" + f for f in os.listdir(os.path.join(ROOT, "rtl"))
                     if f.endswith(".v"))
    build = os.path.join(HERE, "build")
    os.makedirs(build, exist_ok=True)

    # Paths are relative to the repository root: the WebAssembly Yosys only
    # sees the directory it was started in.
    script = ("read_verilog -Irtl %s; hierarchy -check -top tia; proc; check; "
              "synth_gowin -top tia; tee -q -o fpga/build/stat.txt stat"
              % " ".join(sources))
    result = subprocess.run(yosys_command() + ["-q", "-l", "fpga/build/synth.log",
                                               "-p", script], cwd=ROOT)
    if result.returncode:
        sys.exit("Yosys failed; see fpga/build/synth.log")

    with open(os.path.join(build, "synth.log")) as f:
        warnings = [line for line in f.read().splitlines() if line.startswith("Warning")]
    with open(os.path.join(build, "stat.txt")) as f:
        stat = f.read()

    cells = {name: int(count) for count, name in
             re.findall(r"^\s+(\d+)\s+([A-Z][A-Z0-9_]*)\s*$", stat, re.M)}
    ffs = sum(n for name, n in cells.items() if name.startswith("DFF"))
    luts = sum(n for name, n in cells.items() if re.fullmatch(r"LUT\d", name))
    muxes = sum(n for name, n in cells.items() if name.startswith("MUX2_LUT"))
    carries = cells.get("ALU", 0)

    print("flip-flops  %5d   (%.1f%% of the GW1NR-9's %d)" % (ffs, 100.0 * ffs / FF_AVAILABLE, FF_AVAILABLE))
    print("LUTs        %5d   (%.1f%% of its %d LUT4s)" % (luts, 100.0 * luts / LUT4_AVAILABLE, LUT4_AVAILABLE))
    print("wide muxes  %5d   carry cells %d" % (muxes, carries))
    print("warnings    %5d" % len(warnings))
    for line in warnings[:20]:
        print("  " + line)
    return 1 if warnings else 0


if __name__ == "__main__":
    sys.exit(main())
