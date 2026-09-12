# tia-fpga

An FPGA replacement for the **Television Interface Adaptor (TIA)** — the custom
`C010444` / `C010444D` (NTSC) video and sound chip of the Atari 2600.

Revision **A** is the digital interface board between a Sipeed Tang Nano 9K
module and the TIA's DIP-40 socket, for use with a real 6507 (on a breadboard or
in an actual 2600). Composite video and paddles are deferred to later revisions.

---

## Why this exists

The TIA has **6,193 transistors** — 1,657 of which are NMOS pull-ups, leaving
about 4,500 of actual logic. It fits in any modern FPGA with room to spare:
synthesising a known implementation yields **311 flip-flops** and roughly 2,200
basic gates.

Size was never the problem. Two other things are:

1. **The analogue boundary.** The chroma generator is an analogue delay line
   trimmed by an external 500 kΩ potentiometer (pin 10, `DEL`). It has no direct
   digital equivalent.
2. **5 volts.** No FPGA with enough capacity is 5 V tolerant. And the TIA
   generates the 6507's Φ0 clock, which requires
   V<sub>IH</sub> = V<sub>cc</sub> − 0.2 V ≈ **4.8 V** — not a TTL level. A 3.3 V
   output will not clock the 6507 reliably, and the failure mode is nasty: it
   works intermittently, or works cold and quits once warm.

This revision solves (2) and leaves (1) for later.

## What is on the board

| Ref | Part | Function |
|-----|------|----------|
| J1, J4 | 1x24 headers | Sipeed Tang Nano 9K module (GW1NR-LV9QN88PC6/I5) |
| J2, J3 | 1x20 SIP strips | Plug into the DIP-40 socket in place of the C010444 |
| **U1** | **74AHCT125** | **Φ0 and RDY buffer, powered from +5 V.** The critical part |
| U2 | 74LVC245A | D0–D7 bidirectional bus. A side = FPGA, B side = TIA |
| U3 | 74LVC541A | A0–A5 and R/W into the FPGA; Φ2 buffered to a spare pad |
| U4 | 74LVC541A | /CS0, /CS3, triggers I4/I5 and the 3.579545 MHz crystal clock |
| U5 | 74LVC1G32 | `/OE` for the 245: `/CS0 OR /CS3` |
| R1–R9 | — | CX-2600A luma + chroma network. **Leave unpopulated in a real 2600** |

Video and audio signals (`F_CSYNC`, `F_LUM0..2`, `F_COL`, `F_AU0`, `F_AU1`) run
straight from the FPGA to the socket pins — no level translator in the path,
because they feed resistor networks rather than logic inputs.

Pin 6 (`BLK`) is not connected on the CX-2600A. Pin 10 (`DEL`) is the colour
trim pot, which has no function in a replacement. Both are marked no-connect.

Neither of the 245's control lines comes from the FPGA. The A side faces the
FPGA, so `DIR` can be driven straight from the buffered R/W (`DIR`=1, a read,
sends FPGA → TIA), and `/OE` comes from U5. That is deliberate — see the pin
budget below.

## The pin budget, and why it constrains everything

The Tang Nano 9K's headers are 2×24, but **only 29 of those 48 pins are usable
3.3 V GPIO**:

| | Count | |
|---|---|---|
| J5 pins 1–22 | 22 | banks 1/2 at 3.3 V — all usable |
| J6 pins 1, 10, 11, 19–22 | 7 | 3.3 V — usable |
| J6 pins 2–9 | 8 | **BANK3 at 1.8 V — not usable at 3.3 V** |
| J5 23–24, J6 12–17 | 8 | HDMI differential pairs — not GPIO |
| J6 18, 23, 24 | 3 | +5V, GND, +3V3 |

Verified against both revisions of the official Sipeed board schematic (3672 and
3674), which agree exactly. Many of the 29 are shared with onboard peripherals
(SD card, RGB LCD, SPI LCD); they are free to reuse as long as you do not fit
those.

**Rev A uses all 29 with nothing spare.** A fully featured TIA needs about 36.

**Chroma is fitted.** `F_COL` took the pin that used to carry Φ2, and that trade
is deliberate rather than grudging: the FPGA generates Φ0 itself, so it knows
where it is in the bus cycle and can time accesses off its own clock instead of
the 6507's output. It costs a little timing fidelity and buys back colour on the
composite and RF path — which is the difference between a board that only works
with an HDMI monitor and one that revives a console with a dead TIA while
keeping its original video. Φ2 is still buffered by U3, brought out to an
unconnected pad for a future revision.

What still does not fit: the four paddle inputs plus their dump/compare control.

Two ways to get the remaining pins back:

1. **Recover J6/2–9** (8 pins) with a local 1.8 V LDO and a fourth buffer powered
   at 1.8 V. LVC parts run down to 1.65 V and their inputs stay 5 V tolerant, so
   this works — it just adds a rail. This is the cheapest rev B fix.
2. **Drop the module and put a bare FPGA on the board.** A part in a TQFP-100
   gives ~78 I/O against the module's 29, which ends the pin shortage outright,
   removes U5, brings Φ2 back and makes the paddles possible — and collapses a
   ~20 mm tall stack into a 1 mm chip, which matters if this has to live inside
   a closed console. It costs fine-pitch soldering and your own configuration
   and power plumbing. See `docs/bare-fpga.md`.

This is the single most important thing to know before ordering parts: the Tang
Nano 9K is big enough in *logic* by a wide margin, and tight in *pins*. Every
compromise in this design traces back to that.

## The board

Rev A is a 2-layer, **70 × 32 mm** board — roughly the Tang Nano's own footprint.
In a real 2600 the TIA, the 6507 and the RIOT sit millimetres apart, ringed by
resistor networks and the cartridge slot, so the board cannot spread sideways.
All four connector rows are **concentric**, and the two sets face opposite ways:

| y (mm) | Row | Side | Faces |
|---|---|---|---|
| 5.84 | J1 — Tang Nano row A | F.Cu | socket, **up** |
| 8.38 | J2 — TIA pins 1–20 | **B.Cu** | pins, **down** into the socket |
| 23.62 | J3 — TIA pins 21–40 | **B.Cu** | pins, **down** |
| 26.16 | J4 — Tang Nano row B | F.Cu | socket, **up** |

The two pitches coexist because everything lands on the 2.54 mm grid. SMD logic
sits on the front in the 15.24 mm channel between the DIP rows; passives go in
the outer margins.

| | |
|---|---|
| Size | 70 × 32 mm, 2 layers |
| Components | 24 — SOIC/SOT-23 logic, 0805 passives, through-hole connectors |
| Routing | 601 segments, 31 vias, 1.68 m of copper |
| Ground | B.Cu pour, 1075 mm² filled |
| Track / clearance | 0.18 mm / 0.13 mm |
| **DRC** | **0 clearance, 0 unconnected, 0 shorts** |

### Pin assignment is solved, not listed

Which signal sits on which header position is free — any GPIO can carry any
signal — so it is chosen to put each FPGA pin next to the TIA pin it serves.
Solving that as an assignment problem (Hungarian, over the 29 usable positions)
took the summed |x_header − x_TIA| from **737 mm to 127 mm**, with several
signals landing at exactly the same x as their target.

The buffers are then ordered left to right by the centroid of what they carry:
**U1, U4, U3, U2**. Together those two changes cut the board's copper by about a
quarter and a third of its vias:

| | before | after |
|---|---|---|
| Segments | 758 | **601** |
| Vias | 47 | **31** |
| Copper | 2.19 m | **1.68 m** |

`fpga/tia_fpga.cst` carries the result. Do not reshuffle those `IO_LOC` lines
casually — the layout depends on them.

Autorouted with [Freerouting](https://github.com/freerouting/freerouting) 2.2.4;
all 111 connections in 11 s. The channel leaves only ~1.1 mm between the header
pads and the SOIC pads, so the geometry is what decides whether it routes at
all: it took 0.13 mm clearance and 0.18 mm track to close. The ground pour is
added **after** routing — Freerouting reads a pour as an obstacle and goes
effectively single-layer if one is present.

Files: `tia-fpga.kicad_pcb`, renders in `docs/`, fabrication output in `gerbers/`.

### Ordering a board

`tia-fpga-rev-a-gerbers.zip` is ready to upload to any PCB house as-is — Gerber
X2 plus Excellon drill, files at the root of the archive, with
`FABRICATION-NOTES.txt` alongside them. Nothing in it needs more than standard
low-cost capability:

| | |
|---|---|
| Size / layers | 70 × 32 mm, 2 layers, 1.6 mm FR4 |
| Min track / clearance | 0.18 mm / 0.13 mm |
| Drills | 0.30 mm (vias), 1.00 mm (connectors) |

`docs/bom-production.csv` is the parts list with suggested orderable numbers.
Two assembly points that are easy to get wrong:

- **J2/J3 mount on the BACK, pins facing DOWN**, and want **round machined
  pins** — square header pins damage a DIP socket.
- **Leave R1–R9 unpopulated** in a real 2600.

### ⚠ Verify before ordering a board

**The Tang Nano 9K header row spacing is an assumption.** Sipeed documents the
module as 70.0 × 26.0 mm with 2.54 mm pitch but does not publish the distance
between the two 24-pin rows. This layout uses **20.32 mm** (8 × 2.54), the only
value that leaves sensible pad-to-edge clearance on a 26 mm wide board — but it
is deduced, not measured. **Put a caliper on your own module first.** If it is
wrong, only J1 and J4 move.

The DIP-40 row spacing (15.24 mm) is fixed by the package and is not a guess.

**The board needs tall pins.** It overhangs the neighbouring 6507 and RIOT, which
sit proud of the 2600's PCB in their own sockets. Standard DIP header pins would
put this board straight into them; a socket extender or long machined pins are
required. Measure the vertical clearance in your console — the Tang Nano's HDMI
connector adds roughly 5 mm on top.

**There are no mounting holes.** The board is held by its own pins in the TIA
socket, and there is nothing to screw into inside a 2600. Adding holes only
forced the board larger, so they were dropped.

**Do not populate R1–R9 when the board goes into a real 2600.** That resistor
network is a copy of the console's own luma/chroma ladder, for standalone and
breadboard use. A second one in parallel with the console's would shift every
level. In a real machine the board just drives the socket pins and the 2600's
existing video path does the rest.

### Known limitations

- Two DRC notes remain, both checked by hand and both benign: one silkscreen
  mark crossing copper, and one courtyard overlap between U5 and J1 where the
  actual copper clears by **1.24 mm** — KiCad's courtyard is assembly margin,
  not a clash.
- The four paddle inputs still do not fit — see the pin budget above.
- No ground pour on F.Cu; only B.Cu is poured.

## Two ways to use this

**Reviving a dead console.** Pull the failed TIA, drop this in its socket, and
keep the 2600's own RF modulator or composite mod. Chroma, luma, sync and audio
all come out of the socket pins exactly as the original chip drove them, so the
console's video path is untouched. Leave R1–R9 unpopulated.

**As a development target.** Plug it into a breadboard next to a real 6507 and
take colour video out of the Tang Nano's HDMI connector instead — that costs no
header pins, because the HDMI pins are dedicated differential pairs on the
module. Useful while the RTL is still being brought up against the composite
output.

## Status

- [x] Rev A schematic — passes KiCad 10 ERC with 0 violations
- [x] FPGA pin assignment (`fpga/tia_fpga.cst`)
- [x] PCB layout — rev A routed, ground pour, mounting holes, DRC clean
- [ ] TIA RTL
- [ ] Paddle circuit (still needs pins, see above)
- [x] Composite video path wired (chroma pin fitted; the RTL still has to
      synthesise the 15 subcarrier phases)

## Opening the project

Requires **KiCad 10**. Only stock libraries are used — there are no custom
symbols or footprints to install.

```bash
kicad tia-fpga.kicad_pro
```

To run ERC from the command line:

```bash
kicad-cli sch erc tia-fpga.kicad_sch -o erc.rpt --severity-error --severity-warning
```

## Suggested order of work

1. **Build the test harness first.** Compare your RTL cycle by cycle against
   [Sim2600](https://github.com/gregjames/Sim2600) — not an emulator, but the
   netlist extracted from the die shot, simulated transistor by transistor.
   Without a trustworthy oracle you cannot tell "my HMOVE is wrong" from "that
   is how the game actually looks".
2. **Run an existing core** on the Tang Nano over HDMI before touching real
   hardware. This separates bugs in your TIA from bugs in your bench wiring.
3. **Rewrite the TIA one block at a time**, in dependency order: horizontal sync
   counter → playfield → players → missiles and ball → collisions → HMOVE (leave
   HMOVE for last, it is the most treacherous).
4. **This board** — TIA-only, with a real 6507.
5. Audio and paddles.
6. Composite video.

## Timing quirks that matter

Almost every one of these is a bug in the original chip that games came to rely
on. They are what separates "runs Combat" from "runs Pitfall II":

- **None of the TIA's counters are binary.** They are polynomial counters (LFSRs)
  with wired-AND decode matrices — the horizontal sync counter, all five object
  position counters, and the audio generators. Binary counters with comparators
  will run games but get the edge effects wrong.
- **HMOVE comb.** Strobing `HMOVE` delays the end of HBlank (the LRHB line),
  producing the 8-pixel black bar at the left edge. Pitfall II depends on it.
- **Cosmic Ark starfield.** Writing HMxx during the HMOVE window makes the
  comparator see a still-running counter. The resulting pattern *differs between
  TIA revisions*.
- **RESPn latency.** A manual reset does not zero the counter; it forces the
  decode state and takes 4–5 CLK, with different behaviour inside and outside
  HBlank.
- There are at least **12 NTSC TIA revisions** with observable differences.
  Decide which one you are cloning before you start.

## References

- [TIA Hardware Notes](https://www.atarihq.com/danb/files/TIA_HW_Notes.txt) — Andrew Towers, 2003. Polynomial counters, HCount tables, HMOVE timing. Does not cover audio or colour generation.
- [TIA internal schematics](https://www.atariage.com/2600/archives/schematics_tia/index.html) — 5 sheets scanned by Mark De Smet. Sheet 1: sync counter, playfield and motion registers. Sheet 2: collision register. Sheet 3: object/missile motion counters. Sheet 4: audio circuits. Sheet 5: ball motion counter.
- [10444D die shots](http://www.visual6502.org/images/pages/Atari_10444D_TIA.html) — visual6502
- [TIA Technical Manual](https://archive.org/stream/Atari_2600_TIA_Technical_Manual/Atari_2600_TIA_Technical_Manual_djvu.txt)
- [Atari 2600 Specs](https://problemkaputt.de/2k6specs.htm) — Nocash; the cleanest register map there is
- [Tang Nano 9K documentation](https://dl.sipeed.com/shareURL/TANG/Nano%209K/) — Sipeed

---

## Licence

Copyright 2026 Leonardo Roman da Rosa

```
SPDX-License-Identifier: CERN-OHL-S-2.0
```

This source describes Open Hardware and is licensed under the CERN-OHL-S v2.

You may redistribute and modify this source and make products using it under
the terms of the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt).

This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING OF
MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A PARTICULAR PURPOSE.
Please see the CERN-OHL-S v2 for applicable conditions.

Source location: https://github.com/lrrosa/tia-fpga

As per CERN-OHL-S v2 section 4, should You produce hardware based on this source,
You must where practicable maintain the Source Location visible on the external
case of the Gizmo or other products you make using this source.
