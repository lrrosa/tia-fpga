# Should the FPGA go straight on the board?

The board hangs a Sipeed Tang Nano 9K module off two socket strips. The alternative
is a bare FPGA soldered to the board. This note is the reasoning, so the decision
does not have to be made twice.

**Short answer:** for a board that lives inside a closed console, yes, clearly.
For hand-built prototypes, the module is the right call and you already own one.

---

## The module's pin count has shaped every compromise in this design

That is not a figure of speech. Go through what the board gives up, and every item
traces to the same 29 usable GPIO:

| Compromise | Why |
|---|---|
| Φ2 is not read by the FPGA | Its pin was traded for chroma. There was no third option |
| The four paddles are not implemented | No pins left at all |
| U5 exists | An extra gate, so the 245's `/OE` costs no FPGA pin and the two chip selects cost one |
| 8 header pins are stranded | J6/2–9 are a 1.8 V bank; unusable without a second rail |
| GND reaches the module on one pin | J6/23 is the only ground the headers expose |

A part in a TQFP-100 has **80 I/O**. The design needs about 36. The shortage
simply ends, and with it U5, the Φ2 sacrifice and the paddle limitation.

## Height is the other half, and it may be decisive

The module stack is a socket strip (8.5 mm) plus the module PCB (1.6 mm) plus
its HDMI connector (~5 mm) — roughly **20 mm above this board**, which itself
sits on pins above the console's PCB. A bare FPGA is about **1 mm**.

The vertical clearance inside a closed 2600 above a DIP-40 socket is the one
number in this project nobody has measured. If it turns out to be tight, the
bare FPGA is not an option among others — it is the only one.

## What it costs

The module is not just an FPGA. It is an FPGA **plus** regulators, configuration
storage, a USB-JTAG bridge and a known-good assembly. Dropping it means you
provide those:

- **Fine-pitch soldering.** TQFP-100 is 0.5 mm pitch. Drag-solderable by hand
  with flux and braid, but it is a different skill from 1.27 mm SOIC. QFN, which
  is where the cheapest parts live, needs hot air or reflow.
- **Configuration.** Pick a part with *internal* configuration flash or you add
  an SPI NOR chip and its plumbing.
- **Power.** Pick a part with an internal core regulator or you add a second LDO.
- **Programming.** A JTAG header and a programmer, instead of a USB-C cable.
- **No quick swap.** A dead module is replaced in seconds; a dead soldered FPGA
  is a rework job.

## The part that removes most of those costs

**`LCMXO2-1200HC-4TG100`** — Lattice MachXO2, TQFP-100.

| | |
|---|---|
| I/O | **80** (against the module's 29) |
| Logic | 1280 LUT4 — the TIA needs ~311 FF and 500–800 LUT |
| PLL | 1 — needed to synthesise the 15 chroma phases |
| Configuration | **internal flash**, instant-on, no external config chip |
| Supply | **single 2.375–3.465 V**, internal core regulator, no second LDO |
| Package | TQFP-100, 0.5 mm pitch — hand-solderable |

That combination is the point: internal flash and a single supply delete two of
the five costs above. Step up to the `-2000HC` or `-4000HC` in the same package
and footprint if you want logic headroom for a scan doubler or debug
instrumentation.

Gowin's `GW1NR-9` — the same silicon that is on the Tang Nano — also has
internal configuration flash, but it comes in QFN88 at 0.4 mm pitch, which
pushes assembly toward reflow.

## What does not change

**The level translators stay.** U1–U4 exist because no modern FPGA is 5 V
tolerant and the NMOS 6507 needs V<sub>IH</sub> = V<sub>cc</sub> − 0.2 V on Φ0,
and U6–U9 because the console pulls the TIA's video and sound pads up to 5 V.
Those are properties of the 6507 and the console, not of the module, and no
FPGA choice fixes them. Anyone hoping a bare FPGA collapses this into a
one-chip board will be disappointed — it is a board of level translators
either way, and U1 remains the part the whole design hinges on.

The analogue chroma problem does not change either. Having the `F_COL` pin is
necessary but not sufficient; the RTL still has to synthesise the subcarrier
phases through the PLL.

## Verdict

| Goal | Choice |
|---|---|
| Bring up the RTL on a bench, next to a real 6507 | **Module.** USB programming, nothing to solder, swap it when you brick it |
| One repair board, hand-assembled, case left open | **Module.** The pin compromises are liveable |
| Board that closes inside a 2600 | **Bare FPGA.** Height probably forces it |
| Anything built more than a handful of times | **Bare FPGA.** Cheaper per unit, no stacking, and the pin shortage stops dictating the design |

The sensible order is the one already underway: prove the RTL on the module,
where mistakes are cheap, then respin the board around a bare MachXO2 once the
logic is known good. The module board is the development vehicle. It was never going to be
the thing that ships inside somebody's console.
