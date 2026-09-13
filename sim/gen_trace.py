#!/usr/bin/env python3
"""Record a golden pin trace from Sim2600 for the tia-fpga testbench.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

Sim2600 is a transistor-level simulation of the actual 6507 and TIA dies, not
an emulator, so it is the closest thing to an oracle that exists short of a
logic analyser on a real console. This script runs a cartridge on it and writes
down, for every TIA half clock, what was on the chip's pins.

The trace is deliberately pin-level and nothing else. The testbench replays the
recorded inputs into the RTL and compares the recorded outputs, so a mismatch
always means "the RTL does not behave like the die", never "my idea of what the
CPU should have done was wrong".

Because it is simulating roughly ten thousand transistors per half clock, this
is slow: about 3 ms per half clock, so 456 ms per scanline. Reaching the first
visible pixels of a game takes tens of thousands of half clocks. Use --skip to
run past the setup and --count to record only what you need.

Usage:

    python gen_trace.py --sim2600 ../../Sim2600 --rom DonkeyKong.bin \\
                        --skip 40000 --count 4000 --out traces/dk.trace
"""

import argparse
import os
import sys
import time

# The order the fields appear on every trace line. The testbench parses this
# with a matching $fscanf, so the two must be kept in step.
COLUMNS = [
    # stimulus: what the console put on the TIA's pins
    "clk0", "clk2", "rw", "cs0", "cs3", "ab", "db", "inpt",
    # response: what the TIA drove back
    "ph0", "rdy_low", "sync_low", "lum", "col", "blk_low", "au0", "au1", "dbdrv",
]


def open_console(sim2600_dir, rom):
    """Import Sim2600 from its own directory and load a cartridge.

    Sim2600 uses implicit relative imports and relative paths to its netlist
    and ROM files, so it has to be imported with its own directory both on
    sys.path and as the working directory.
    """
    sim2600_dir = os.path.abspath(sim2600_dir)
    if not os.path.isdir(sim2600_dir):
        sys.exit("No Sim2600 checkout at %s" % sim2600_dir)

    sys.path.insert(0, sim2600_dir)
    os.chdir(sim2600_dir)

    try:
        from sim2600Console import Sim2600Console
    except SyntaxError:
        sys.exit(
            "Sim2600 is still Python 2 source. Apply patches/sim2600-py3.patch\n"
            "to the checkout first -- see sim/README.md."
        )

    rom_path = rom if os.path.isabs(rom) else os.path.join("roms", rom)
    if not os.path.exists(rom_path):
        sys.exit("No such ROM: %s" % rom_path)

    return Sim2600Console(rom_path)


def bits(sim, pads):
    """Read a list of pad wire indices as an integer, LSB first."""
    value = 0
    for i, wire in enumerate(pads):
        if sim.isHigh(wire):
            value |= 1 << i
    return value


class Probes(object):
    """Cached wire indices for everything the trace records."""

    def __init__(self, tia):
        self.tia = tia
        w = tia.getWireIndex
        self.sync_low = w("SYNC_lowCtrl")
        self.blk_low = w("BL_lowCtrl")
        # Sim2600's names are the other way round from the registers: the
        # AU1_* taps follow AUDC0/AUDF0/AUDV0 and the AU0_* taps follow
        # channel 1. A volume ramp on AUDV0 shows up on AU1_* and nowhere else.
        self.au0 = [w("AU1_30k"), w("AU1_15k"), w("AU1_7.5k"), w("AU1_3.75k")]
        self.au1 = [w("AU0_30k"), w("AU0_15k"), w("AU0_7.5k"), w("AU0_3.75k")]

    def sample(self):
        tia = self.tia
        return {
            # ---- stimulus
            "clk0": int(tia.isHigh(tia.padIndCLK0)),
            "clk2": int(tia.isHigh(tia.padIndCLK2)),
            "rw": int(tia.isHigh(tia.padIndRW)),
            "cs0": int(tia.isHigh(tia.padIndCS0)),
            "cs3": int(tia.isHigh(tia.padIndCS3)),
            "ab": bits(tia, tia.addressBusPads),
            "db": bits(tia, tia.dataBusPads),
            "inpt": bits(tia, tia.inputPads),
            # ---- response
            "ph0": int(tia.isHigh(tia.padIndPH0)),
            "rdy_low": int(tia.isHigh(tia.indRDY_lowCtrl)),
            "sync_low": int(tia.isHigh(self.sync_low)),
            # get3BitLuminance already accounts for the pads being pulled low
            "lum": tia.get3BitLuminance(),
            "col": tia.get4BitColor(),
            "blk_low": int(tia.isHigh(self.blk_low)),
            "au0": bits(tia, self.au0),
            "au1": bits(tia, self.au1),
            # {DB7_drvHi, DB7_drvLo, DB6_drvHi, DB6_drvLo}
            "dbdrv": (int(tia.isHigh(tia.indDB7_drvHi)) << 3)
            | (int(tia.isHigh(tia.indDB7_drvLo)) << 2)
            | (int(tia.isHigh(tia.indDB6_drvHi)) << 1)
            | int(tia.isHigh(tia.indDB6_drvLo)),
        }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim2600", default="Sim2600",
                    help="path to a Sim2600 checkout (default: ./Sim2600)")
    ap.add_argument("--rom", default="DonkeyKong.bin",
                    help="cartridge, either a path or a name under Sim2600/roms")
    ap.add_argument("--skip", type=int, default=0,
                    help="TIA half clocks to run before recording anything")
    ap.add_argument("--count", type=int, default=2000,
                    help="TIA half clocks to record")
    ap.add_argument("--wait-visible", type=int, default=0, metavar="MAX",
                    help="after --skip, run up to MAX more half clocks until "
                         "the picture is unblanked, then start recording. "
                         "Games spend tens of thousands of half clocks in "
                         "vertical blank before the first visible pixel, and "
                         "how many varies by cartridge, so this beats guessing "
                         "a skip count")
    ap.add_argument("--raw-bus", action="store_true",
                    help="keep the address and data bus in records where the "
                         "TIA is not selected. Off by default: those records "
                         "carry the cartridge's program bytes, and neither the "
                         "die nor the core looks at them")
    ap.add_argument("--out", default="traces/trace.txt", help="output file")
    ap.add_argument("--quiet", action="store_true",
                    help="silence Sim2600's own running commentary")
    args = ap.parse_args()

    out_path = os.path.abspath(args.out)
    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir)

    console = open_console(args.sim2600, args.rom)
    probes = Probes(console.simTIA)

    if args.quiet:
        sys.stdout = open(os.devnull, "w")

    start = time.time()
    for i in range(args.skip):
        console.advanceOneHalfClock()

    waited = 0
    if args.wait_visible:
        while waited < args.wait_visible:
            if not console.simTIA.isHigh(probes.blk_low):
                break
            console.advanceOneHalfClock()
            waited += 1

    rows = []
    for i in range(args.count):
        console.advanceOneHalfClock()
        row = probes.sample()
        if not args.raw_bus and (row["cs0"] or row["cs3"]):
            # While the TIA is not chip-selected the die ignores the bus, and
            # so does the core: nothing the comparison uses is lost. What is
            # lost is the cartridge's program, which rides the same data bus
            # whenever the 6507 fetches from ROM and would otherwise end up
            # copied into the trace.
            row["ab"] = 0
            row["db"] = 0
        rows.append(row)

    if args.quiet:
        sys.stdout = sys.__stdout__

    elapsed = time.time() - start

    with open(out_path, "w", newline=chr(10)) as f:
        f.write("# tia-fpga golden trace from Sim2600\n")
        f.write("# rom=%s skip=%d wait=%d count=%d\n"
                % (args.rom, args.skip, waited, args.count))
        f.write("# one record per TIA half clock; bus %s while the TIA is "
                "not selected\n" % ("recorded" if args.raw_bus else "zeroed"))
        f.write("# %s\n" % " ".join(COLUMNS))
        for row in rows:
            f.write(" ".join("%x" % row[c] for c in COLUMNS) + "\n")

    print("wrote %d records to %s in %.1f s (%.2f ms per half clock)"
          % (len(rows), out_path, elapsed,
             elapsed / max(1, args.skip + waited + args.count) * 1000.0))
    if args.wait_visible:
        print("waited %d half clocks past --skip for the picture to unblank%s"
              % (waited, "" if waited < args.wait_visible else " (HIT THE CAP)"))


if __name__ == "__main__":
    main()
