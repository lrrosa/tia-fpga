#!/usr/bin/env python3
"""Record every wire of the simulated TIA die, every half clock.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

gen_trace.py records the chip's pins, which is what the RTL is judged on. When
a mismatch will not yield to thinking about pins, this records the inside of
the die instead: all 2,660 wires of Sim2600's TIA netlist, one bit each, for
every half clock from power-on. With `netlist.py` to read the logic around a
wire, it turns "what does the chip do here?" into something you can look up.

It runs the cartridge exactly as gen_trace.py --skip 0 does, so record k of
the probe is record k of the trace recorded from the same cartridge.

    pip install numpy
    python sim/probe_die.py --sim2600 ../Sim2600 \\
        --rom sim/roms/build/players.bin --count 51072 --out players.npy

The output is a (count, 333) uint8 array of packed bits, most significant bit
first, in Sim2600's wire index order: wire w of record k is
(data[k, w >> 3] >> (7 - (w & 7))) & 1. Recording costs little on top of the
simulation itself, about a megabyte per 3,000 half clocks.
"""

import argparse
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen_trace import open_console  # noqa: E402

# Sim2600's Wire.state values that read as high: PULLED_HIGH, HIGH, FLOATING_HIGH.
HIGH_STATES = 1 | 8 | 16


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim2600", default="Sim2600", help="path to a patched Sim2600 checkout")
    ap.add_argument("--rom", required=True, help="cartridge, a path or a name under Sim2600/roms")
    ap.add_argument("--count", type=int, required=True, help="half clocks to record")
    ap.add_argument("--out", required=True, help="output .npy file")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    rom = os.path.abspath(args.rom) if os.path.exists(args.rom) else args.rom
    console = open_console(args.sim2600, rom)
    wires = console.simTIA.wireList
    n = len(wires)

    data = np.zeros((args.count, (n + 7) // 8), dtype=np.uint8)
    sys.stdout = open(os.devnull, "w")           # Sim2600's own commentary
    start = time.time()
    for k in range(args.count):
        console.advanceOneHalfClock()
        states = np.fromiter((w.state if w is not None else 0 for w in wires),
                             dtype=np.uint8, count=n)
        data[k] = np.packbits((states & HIGH_STATES) != 0)
    sys.stdout = sys.__stdout__

    np.save(out, data)
    print("recorded %d half clocks of %d wires to %s in %.0f s"
          % (args.count, n, out, time.time() - start))


if __name__ == "__main__":
    main()
