# Testing the RTL against Sim2600

This is the oracle the project README argues for. [Sim2600](https://github.com/gregjames/Sim2600)
is not an emulator — it is the 6507 and TIA netlists pulled off die photographs
by the visual6502 project, simulated transistor by transistor. It is the
closest thing to a reference TIA that exists short of putting a logic analyser
on a real console, and it is the only way to tell "my HMOVE is wrong" apart
from "that is how the chip actually behaves".

The idea is deliberately narrow:

1. Run a cartridge on Sim2600 and write down, every TIA half clock, **what was
   on the chip's pins** — both what the console drove in and what the die drove
   back.
2. Replay the recorded **inputs** into the RTL and check the recorded
   **outputs**.

Nothing in the loop depends on anyone's idea of what the 6507 should have been
doing. A mismatch always means the RTL does not behave like the silicon.

---

## Quick start

```bash
python sim/run.py
```

That builds the core with Icarus Verilog and replays every trace in
`sim/traces/` and `sim/traces/local/`. It takes a few minutes.

The two directories are different on purpose. `sim/traces/` holds traces of
the project's own test cartridges and is committed. `sim/traces/local/` holds
traces recorded from commercial cartridges and is ignored by git: even with the
bus scrubbed (see *Trace format*), what a game writes into GRP0 and PF0-PF2 is
its artwork, and that is not ours to publish. Regenerate those locally with the
commands under *Generating a trace*.

## Current results

Mismatched half clocks, against every half clock scored in each trace. Φ0,
RDY, composite sync and blanking are **zero on every trace** and are left out.

| trace | what it exercises | scored | lum/col | data bus | audio |
|---|---|---:|---:|---:|---:|
| `local/donkeykong-boot-to-picture` | a real game, power-on to its first picture | 51,657 | **0** | **0** | **0** |
| `local/donkeykong-power-on` | the first 6,000 half clocks, both RSYNCs | 3,657 | **0** | **0** | **0** |
| `playfield` | every CTRLPF mode, mid-line PF writes | 54,063 | **0** | **0** | **0** |
| `vdel` | VDELP0 and VDELP1 in all four combinations | 17,583 | **0** | **0** | **0** |
| `ball` | widths at every phase, RESBL retriggering, VDELBL | 44,031 | 6 | **0** | **0** |
| `missiles` | widths, copies, RESMP at every player size | 55,887 | 8 | **0** | **0** |
| `hmove` | all sixteen values, HMOVE late and mid-line, Cosmic Ark | 28,983 | 12 | **0** | **0** |
| `players` | every NUSIZ mode at all four sub-count phases | 46,767 | 56 | **0** | **0** |
| `collisions` | everything overlapping, all eight CX reads, input ports | 34,911 | 652 | 45 | **0** |
| `audio` | the volume DAC, and a glimpse of every AUDC mode | 90,543 | **0** | **0** | 25,104 / 40,816 |

Every remaining mismatch is located and described under *Known gaps*. The suite
reports FAIL for every trace that still has one, and it should keep doing so
until each is fixed rather than being papered over with a tolerance.

## What you need

| | |
|---|---|
| **Icarus Verilog** 11 or later | `winget install Icarus.Verilog`, `apt install iverilog`, `brew install icarus-verilog` |
| **Python 3.8+** | to generate traces and to drive the build |
| **Sim2600** | only to generate traces |

`run.py` looks for `iverilog` and `vvp` on PATH and then in `C:\iverilog\bin`,
which is where the Windows installer puts them and where it does not add them
to PATH.

## Setting up Sim2600

```bash
git clone -c core.autocrlf=false https://github.com/gregjames/Sim2600.git
cd Sim2600
git checkout af3bc453e253172503967ffb826377517b95a62a
git apply ../tia-fpga/sim/patches/sim2600-py3.patch
```

**`core.autocrlf=false` is not optional on Windows.** `chips/net_TIA.pkl` is a
protocol-0 pickle, which is mostly ASCII, so git's autocrlf heuristic decides
it is a text file and rewrites every `\n` in it as `\r\n`. The file still looks
fine and is still about the right size; it just fails to unpickle, with
`UnpicklingError: the STRING opcode argument must be quoted`. If you already
cloned it the wrong way, delete the checkout and clone again — `git checkout`
alone will not undo it. Put the `-c` after `clone`, as above: that writes the
setting into the new repository's own config, so the `checkout` and `apply`
that follow keep it too.

`sim2600-py3.patch` ports Sim2600 to Python 3. It is small and mechanical:
`print` statements, `xrange`, integer division, `RuntimeException`, iterating
over bytes, and `pickle.load(..., encoding='latin1')` for the Python 2 netlist
files. It also fixes one upstream typo — `writeMemory` sets `pia.timerVal`
where every reader says `pia.timerValue`, so the PIA timer never actually
loaded its initial value. That does not change the shape of the comparison (the
trace is replayed either way) but it makes the oracle a more faithful 2600.

Sim2600 is MIT licensed, and the patch is a modification of it, so the patch
is offered under the MIT licence too, not the CERN-OHL-S that covers the rest
of this repository. Its header says so.

## Test cartridges

`sim/roms/` builds the cartridges behind the committed traces:

- `tinyasm.py` — a 6502 assembler small enough to read in one sitting, so the
  harness needs nothing beyond Python and Icarus. Every instruction is a
  method named after its mnemonic and addressing mode: `a.sta_zp(WSYNC)`,
  `a.bne("loop")`.
- `tests.py` — one function per cartridge. None of them bothers with VSYNC or a
  proper frame: the harness compares pins, not pictures, so every scanline can
  be a test line.
- `make.py` — builds the cartridges and records their traces, several
  Sim2600 runs at a time.

```bash
python sim/roms/make.py --list
python sim/roms/make.py --sim2600 ../Sim2600                 # every test
python sim/roms/make.py --sim2600 ../Sim2600 players hmove   # just these
```

Every cartridge starts by clearing zero page, which writes every TIA register —
RSYNC included. That is on purpose: RSYNC restarts the die's horizontal counter
from the bus, so nothing after it depends on whatever phase the die powered up
in.

The tests do not try to predict where a strobe lands; the die's answer is in
the trace. They step a delay loop so strobes land on every phase that matters:
a five-cycle step is 15 colour clocks, which is 3 mod 4, so four consecutive
steps visit all four phases of an object counter.

They exist because a game only covers what it happens to do. Donkey Kong's
title screen uses players and very little else, and it passed cleanly while the
playfield was still a colour clock late and an HMOVE of −8 moved objects
sixteen pixels the wrong way.

## Generating a trace from a game

```bash
python sim/gen_trace.py --sim2600 ../Sim2600 --rom DonkeyKong.bin --quiet \
       --skip 0 --count 54000 \
       --out sim/traces/local/donkeykong-boot-to-picture.trace
python sim/gen_trace.py --sim2600 ../Sim2600 --rom DonkeyKong.bin --quiet \
       --skip 0 --count 6000 \
       --out sim/traces/local/donkeykong-power-on.trace
```

Sim2600 settles roughly ten thousand transistors per half clock, so it runs at
about **3 ms per half clock** — half a second per scanline, two and a half
minutes per frame. Plan around that:

- `--count N` records N half clocks. 456 of them is one scanline, so 54,000 is
  about 118 lines — enough for Donkey Kong to get from power-on to its first
  visible pixels, which is what it takes.
- `--skip N` runs N half clocks without recording. Useful for looking at
  something specific, but see the warning below before you reach for it.
- `--wait-visible MAX` runs on after `--skip` until the picture unblanks.

**Start traces at power-on: use `--skip 0`.** A trace that begins in the middle
of a game is not a fair test, because the die's register file holds whatever
the cartridge wrote before the recording started, while the core comes out of
reset with everything at zero. Nothing in the trace can tell it what COLUP0
was.

A trace with no visible picture in it still checks sync, blank, the CPU clock,
RDY and the bus, but it tells you nothing about the graphics path — every pixel
is legitimately black. Check that a new trace actually contains picture before
you trust a PASS from it.

## Running the comparison

```bash
python sim/run.py sim/traces/hmove.trace
python sim/run.py --quiet                       # all traces, summary only
python sim/run.py --debug --from 53668 --to 53700 \
       sim/traces/local/donkeykong-boot-to-picture.trace
```

`--debug` switches to `tb_debug.v`, which prints the core's internal state
beside the die's pins for a window of records. `tb_trace.v` also takes
`+dump=FILE`, which writes the core's luminance, colour, sync, blank, RDY and
data bus drive for every scored record; comparing that with the trace a
scanline at a time is the fastest way to see *how* something diverges — a
constant offset, a pixel too wide, a copy missing.

### Alignment

A trace starts wherever the recording started, while the core comes out of
reset at the top of a scanline. The testbench therefore replays the trace at
every one of the 456 offsets within a scanline and keeps the one with the
fewest sync errors, then reports the offset it chose. Every trace in this
repository starts with an RSYNC, which makes the choice moot; `+align=0` skips
the search.

This is a property of the harness, not a tolerance in the RTL. Sync is a pure
decode of the horizontal counter: if no offset produces a clean match, the
counter is wrong and that is a real finding. Nothing is scored for the first
2,000 records (`+warm=N`) or before the next HBLANK edge, because a trace that
starts at power-on begins inside the 6507's reset sequence; after that, every
record is checked.

## Trace format

One line per TIA half clock, all fields hexadecimal:

```
clk0 clk2 rw cs0 cs3 ab db inpt | ph0 rdy_low sync_low lum col blk_low au0 au1 dbdrv
```

The first eight are stimulus, the rest are what the die drove. `lum` and `col`
come from Sim2600's own `get3BitLuminance()` and `get4BitColor()`. `sync_low`,
`rdy_low` and `blk_low` are the drive-low control wires, so 1 means the chip is
pulling that pad to ground. `dbdrv` is
`{DB7_drvHi, DB7_drvLo, DB6_drvHi, DB6_drvLo}` — the TIA only ever drives those
two data lines.

`au0` and `au1` are the four weighted taps of each audio pad, 3.75k as the
most significant bit and 30k as the least, so they read back as the AUDV value
while the tone is high. Sim2600 names its taps the other way round from the
registers — its `AU1_*` wires follow AUDV0 — and `gen_trace.py` swaps them
back.

**`ab` and `db` are zeroed wherever the TIA is not chip-selected.** The die
ignores the bus in those records and so does the core, so the comparison loses
nothing — replaying a scrubbed copy of the Donkey Kong trace gives exactly the
same result as the raw one. What it does lose is the cartridge's program, which
otherwise rides the data bus into the trace every time the 6507 fetches from
ROM. `gen_trace.py --raw-bus` keeps everything, for local investigation.

## What the traces have settled

Everything here contradicts, sharpens or simply is not in the published
documentation, and each is now a comment in the RTL next to the code that
implements it.

**Clocks and the horizontal counter**

- **The horizontal counter runs on the falling edge of the colour clock, and
  the sync latch on the rising edge**, three half clocks earlier. Towers' table
  lists both as "delayed 4 CLK", which is right to within a count but not to
  within a colour clock. HBLANK always rises on a record where `clk0` is low,
  sync always on one where it is high, and sync rise is always exactly 37 half
  clocks after HBLANK rise — 40 for five counter states, minus three.
- **Φ0 is a 50 per cent square wave**, three half colour clocks high and three
  low, so the die divides by three on both edges. **The horizontal counter
  reloads it:** it rises on exactly the half clock where HBLANK starts, every
  line, and an RSYNC cuts its high half short one colour clock before the
  counter restarts.
- **RSYNC restarts the counter four colour clocks after the strobe, rounded up
  to the counter's own falling edge.** Towers left it as "requires more
  investigation". Both RSYNCs in the Donkey Kong trace stretch their scanline
  from 456 to 514 half clocks and shift the counter grid by two colour clocks.

**The bus**

- **The data bus drivers are enabled only while Φ2 is high** — three half
  clocks of the six-half-clock bus cycle — on every selected read, including
  the two read addresses with no register behind them, which read as zeros.
- **WSYNC releases RDY one colour clock before HBLANK starts**, and a WSYNC
  whose phase 2 contains that release is ignored: the release wins.

**The picture**

- **The playfield and blanking reach the pads directly on the falling edge;
  objects and the colour registers go through a latch on it.** Latching the
  playfield too puts it a colour clock right of the die and lets the last pixel
  of every line leak into HBLANK.
- **Each playfield bit is read out of PF0-PF2 on H@1 and shown from the next
  H@2**, so a mid-line write appears at the next bit boundary only if it beats
  that boundary's H@1.
- **SCORE switches to the right-hand colour one colour clock before the second
  half starts, and the priority bit turns SCORE off** — with PFP set the
  playfield keeps COLUPF.

**Objects**

- **A RESxx strobe realigns the object's two-phase clock one colour clock after
  it, and clears the counter four colour clocks after it.** The four is
  Towers' "resetting the counter takes 4 CLK", taken literally; a sweep from 4
  to 11 has 4 best by a wide margin. Realigning the phase early is what lets
  the die draw a copy that was already decoded a colour clock early instead of
  losing it.
- **RESBL starts the ball when the counter clears, not at the strobe.**
- **Double- and quad-size players start one colour clock later than
  single-size ones**, and their scan counter is clocked from H@1 alone (4×) or
  both phases (2×), so the first stretched pixel is as wide as the rest.

**HMOVE**

- **The first compare has to come before the first decrement.** Whether the
  counter steps down first depends only on where in the two-phase cycle
  `STA HMOVE` lands; when it does, an HMxx of −8 never matches, and the object
  receives sixteen pulses instead of none.
- **Stuffed pulses only count before RHB.** After that they coincide with
  MOTCK and are absorbed: an HMOVE in the middle of the visible line moves
  nothing, and one strobed late in HBLANK loses every pulse past RHB — even
  though the HMOVE latch holds HBLANK on until LRHB.

**Audio and inputs**

- **The audio clock ticks twice a line, at counts 9 and 37** of the horizontal
  counter, 112 and 116 colour clocks apart rather than an even 114.
- **AUDC 0 and B hold the output at the AUDV level** — a DC offset, not silence.
- **VBLANK D7 grounds the paddle inputs**, which then read as zero.

## Known gaps

Located divergences, largest first:

- **A double-size player reset during HBLANK** (`collisions`: 652 pixels, and
  all 45 of the bus mismatches). RESP1 lands thirteen half clocks into the
  line with NUSIZ1 = %101, and on every following line the core draws that
  player six half clocks left of the die. The collision reads that disagree
  are the knock-on effect: the misplaced pixels overlap objects the die's do
  not. The reset model above was fitted to strobes in the visible line; while
  HBLANK stops MOTCK, only the free-running colour clock advances its delays,
  and that is evidently not what the die does. The same trace also switches a
  player from 1× to 4× while a copy is being drawn, which the core draws too
  wide.
- **A quad-size player reset while a copy is on screen** (`players`, 56):
  RESP0 landing inside a quad-size copy holds the die's next stretched pixel
  for four colour clocks longer than the core does. Double-size copies reset
  the same way already match.
- **HMM0 rewritten at the very end of an HMOVE** (`hmove`, 12) — the Cosmic Ark
  trick. Afterwards the core's missile sits one pixel left of the die's.
- **Missiles** (`missiles`, 8): a copy wrapping into the start of the next line
  that the core does not draw, and the pixel where RESMP0 releases a missile
  from a three-copy player.
- **RESBL retriggered within the ball's own width** (`ball`, 6): four strobes
  nine colour clocks apart with an 8-pixel ball. The die draws one unbroken
  run; the core leaves a colour clock's gap between each copy.
- **The audio polynomial counters** (`audio`). The clock, the volume taps and
  the constant modes match; the 4-, 5- and 9-bit polynomial counters and the
  divide-by-three do not, and `audio` switches mode too often to see their
  sequences. The `audio_modes` cartridge holds each mode for 80 audio clock
  ticks and the 9-bit counter for a whole period, which is what pinning them
  down takes.

And gaps in coverage rather than in the core:

- Nothing drives the joystick or console switches. Sim2600 holds I0-I5 high,
  so the trigger latch has never been exercised.
- One cartridge revision. There are at least twelve NTSC TIA revisions with
  observable differences, and Sim2600's netlist is the 10444D.
- The core has never been synthesised, and there is no board-level wrapper
  yet: no pin mapping onto `fpga/tia_fpga.cst`, no PLL, no tri-state on the
  data bus. Note also that the TIA's audio pad is a four-bit weighted current
  DAC — that is what `au0` and `au1` are — while the board gives each channel a
  single 3.3 V pin, so AUDV has to come back as PWM or sigma-delta on the way
  out.
