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
| J1, J4 | 1x20 headers | Sipeed Tang Nano 9K module (GW1NR-LV9QN88PC6/I5) |
| J2, J3 | 1x20 SIP strips | Plug into the DIP-40 socket in place of the C010444 |
| **U1** | **74AHCT125** | **Φ0 and RDY buffer, powered from +5 V.** The critical part |
| U2 | 74LVC245A | D0–D7 bidirectional bus; `DIR` and `/OE` driven by the FPGA |
| U3 | 74LVC541A | A0–A5, R/W and Φ2 into the FPGA |
| U4 | 74LVC541A | /CS0, /CS3, triggers I4/I5 and the 3.579545 MHz crystal clock |
| R1–R9 | — | CX-2600A luma resistor network (4:2:1). **Not populated in rev A** |

Video and audio signals (`F_CSYNC`, `F_LUM0..2`, `F_COL`, `F_AU0`, `F_AU1`) run
straight from the FPGA to the socket pins — no level translator in the path,
because they feed resistor networks rather than logic inputs.

Pin 6 (`BLK`) is not connected on the CX-2600A. Pin 10 (`DEL`) is the colour
trim pot, which has no function in a replacement. Both are marked no-connect.

## Status

- [x] Rev A schematic — passes KiCad 10 ERC
- [ ] FPGA pin assignment (`fpga/tia_fpga.cst` still has TODOs)
- [ ] PCB layout
- [ ] TIA RTL
- [ ] Paddle circuit (phase 5)
- [ ] Composite video (phase 6)

**ERC:** 6 `isolated_pin_label` warnings, all expected. They are the paddle
circuit pins (`TIA_I0`–`TIA_I3`, `F_PADDLE_DUMP`, `F_PADDLE_CMP`), brought out to
the connectors but with no circuit between them in this revision.

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

Copyright 2026 lrrosa

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
