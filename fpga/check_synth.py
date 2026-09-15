#!/usr/bin/env python3
"""Synthesise the TIA core and the board top for the GW1NR-9 with Yosys.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

This is a check, not a build: it runs Yosys's synth_gowin twice -- on the core
alone (rtl/tia.v) and on the whole board top (fpga/tia_fpga_top.v, with its
PLL, bus buffers and chroma ODDR) -- and reports what each uses and whether
Yosys had anything to complain about. It does not place, route or time
anything; the bitstream comes out of Gowin EDA (fpga/build_gowin.tcl).

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


def synth(name, script):
    """Run one Yosys script; return (cell counts, warnings)."""
    log = "fpga/build/%s.log" % name
    stat = "fpga/build/%s_stat.txt" % name
    result = subprocess.run(yosys_command() + ["-q", "-l", log, "-p",
                                               script + "; tee -q -o %s stat" % stat],
                            cwd=ROOT)
    if result.returncode:
        sys.exit("Yosys failed; see %s" % log)
    with open(os.path.join(ROOT, log)) as f:
        warnings = [line for line in f.read().splitlines() if line.startswith("Warning")]
    with open(os.path.join(ROOT, stat)) as f:
        cells = {cell: int(count) for count, cell in
                 re.findall(r"^\s+(\d+)\s+([A-Za-z][A-Za-z0-9_]*)\s*$", f.read(), re.M)}
    return cells, warnings


def report(title, cells, warnings):
    ffs = sum(n for cell, n in cells.items() if cell.startswith("DFF"))
    luts = sum(n for cell, n in cells.items() if re.fullmatch(r"LUT\d", cell))
    muxes = sum(n for cell, n in cells.items() if cell.startswith("MUX2_LUT"))
    print(title)
    print("  flip-flops  %5d   (%.1f%% of the GW1NR-9's %d)" % (ffs, 100.0 * ffs / FF_AVAILABLE, FF_AVAILABLE))
    print("  LUTs        %5d   (%.1f%% of its %d LUT4s)" % (luts, 100.0 * luts / LUT4_AVAILABLE, LUT4_AVAILABLE))
    print("  wide muxes  %5d   carry cells %d" % (muxes, cells.get("ALU", 0)))
    prims = ["%s %d" % (cell, cells[cell]) for cell in ("rPLL", "IOBUF", "ODDR", "IBUF", "OBUF")
             if cell in cells]
    if prims:
        print("  primitives  " + ", ".join(prims))
    print("  warnings    %5d" % len(warnings))
    for line in warnings[:20]:
        print("    " + line)


def main():
    rtl = " ".join(sorted("rtl/" + f for f in os.listdir(os.path.join(ROOT, "rtl"))
                          if f.endswith(".v")))
    os.makedirs(os.path.join(HERE, "build"), exist_ok=True)

    # Paths are relative to the repository root: the WebAssembly Yosys only
    # sees the directory it was started in.
    core = synth("core", "read_verilog -Irtl %s; hierarchy -check -top tia; proc; check; "
                         "synth_gowin -top tia" % rtl)
    board = synth("board", "read_verilog -Irtl %s fpga/tia_fpga_top.v; "
                           "synth_gowin -top tia_fpga_top" % rtl)

    report("core (rtl/tia.v)", *core)
    report("board top (fpga/tia_fpga_top.v)", *board)
    return 1 if core[1] or board[1] else 0


if __name__ == "__main__":
    sys.exit(main())
