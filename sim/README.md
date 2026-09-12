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
`sim/traces/` and `sim/traces/local/`.

The two directories are different on purpose. `sim/traces/` holds traces from
the project's own test ROMs and is committed. `sim/traces/local/` holds traces
recorded from commercial cartridges and is ignored by git: even with the bus
scrubbed (see *Trace format*), what a game writes into GRP0 and PF0-PF2 is its
artwork, and that is not ours to publish. Regenerate those locally with the
commands under *Generating a trace*.

Current result, against Donkey Kong from power-on to its first visible pixels
(`sim/traces/local/donkeykong-boot-to-picture.trace`, 51,657 scored half
clocks, about 113 scanlines):

| signal | mismatches |
|---|---|
| `sync_low` | **0** |
| `blank` | **0** |
| `rdy_low` (WSYNC) | **0** |
| `dbdrv` (bus reads) | **0** |
| `au0`, `au1` | **0** |
| `ph0` (CPU clock) | 1 |
| `lum`, `col` | 12 |

The thirteen are two specific, located things, both described under Known gaps
below. The suite reports FAIL because of them, and it should keep doing so
until they are fixed rather than being papered over with a tolerance.

To make new traces you need Sim2600 itself — see below.

## What you need

| | |
|---|---|
| **Icarus Verilog** 11 or later | `winget install Icarus.Verilog`, `apt install iverilog`, `brew install icarus-verilog` |
| **Python 3.8+** | only to generate traces and to drive the build |
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

## Generating a trace

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
  about 118 lines -- enough for Donkey Kong to get from power-on to its first
  visible pixels, which is what it takes.
- `--skip N` runs N half clocks without recording. Useful for looking at
  something specific, but see the warning below before you reach for it.
- `--wait-visible MAX` runs on after `--skip` until the picture unblanks. Games
  sit in vertical blank for tens of thousands of half clocks before the first
  visible pixel and how many varies per cartridge, so this beats guessing.

**Start traces at power-on: use `--skip 0`.** A trace that begins in the middle
of a game is not a fair test, because the die's register file holds whatever
the cartridge wrote before the recording started, while the core comes out of
reset with everything at zero. Nothing in the trace can tell it what COLUP0
was. Replaying from power-on costs a bigger file and a couple of minutes of
Sim2600, and in exchange every register the core holds got there through its own
bus interface, from the same writes the die saw. The Donkey Kong trace behind
the numbers above is 54,000 half clocks for exactly this reason: that is how
long Donkey Kong takes to put something on screen.

A trace with no visible picture in it still checks sync, blank, the CPU clock,
RDY and the bus, but it tells you nothing about the graphics path — every pixel
is legitimately black. Check that a new trace actually contains picture before
you trust a PASS from it.

## Running the comparison

```bash
python sim/run.py sim/traces/local/donkeykong-power-on.trace
python sim/run.py --quiet                       # all traces, summary only
python sim/run.py --debug --from 53668 --to 53700 \
       sim/traces/local/donkeykong-boot-to-picture.trace
```

`--debug` switches to `tb_debug.v`, which prints the core's internal state —
counter, phases, HBLANK, HSYNC — beside the die's pins for a window of records.
That is the tool for working out *why* something diverges.

### Alignment

A trace starts wherever the recording started, somewhere in the middle of a
scanline, while the core comes out of reset at the top of one. The testbench
therefore replays the trace at every one of the 456 offsets within a scanline
and keeps the one with the fewest sync errors, then reports the offset it
chose.

This is a property of the harness, not a tolerance in the RTL. Sync is a pure
decode of the horizontal counter: if no offset produces a clean match, the
counter is wrong and that is a real finding. Nothing before the first HBLANK
edge is scored, because the core needs one line boundary to lock on; after it,
every record is checked.

## Trace format

One line per TIA half clock, all fields hexadecimal:

```
clk0 clk2 rw cs0 cs3 ab db inpt | ph0 rdy_low sync_low lum col blk_low au0 au1 dbdrv
```

The first eight are stimulus, the rest are what the die drove. `lum` and `col`
come from Sim2600's own `get3BitLuminance()` and `get4BitColor()`. `sync_low`,
`rdy_low` and `blk_low` are the drive-low control wires, so 1 means the chip is
pulling that pad to ground. `au0`/`au1` are the four weighted taps of each
audio pad, MSB first (3.75k, 7.5k, 15k, 30k). `dbdrv` is
`{DB7_drvHi, DB7_drvLo, DB6_drvHi, DB6_drvLo}` — the TIA only ever drives those
two data lines.

**`ab` and `db` are zeroed wherever the TIA is not chip-selected.** The die
ignores the bus in those records and so does the core, so the comparison loses
nothing -- replaying a scrubbed copy of the Donkey Kong trace gives exactly the
same thirteen mismatches as the raw one. What it does lose is the cartridge's
program, which otherwise rides the data bus into the trace every time the 6507
fetches from ROM. `gen_trace.py --raw-bus` keeps everything, for local
investigation.

## What the traces have settled so far

Things the harness pinned down that the published documentation does not say,
each of them now a comment in the RTL:

- **The horizontal counter runs on the falling edge of the colour clock, and
  the sync latch on the rising edge**, three half clocks earlier. Towers' table
  lists both as "delayed 4 CLK", which is right to within a count but not to
  within a colour clock. The giveaway: HBLANK always rises on a record where
  `clk0` is low, sync always on a record where `clk0` is high, and sync rise is
  always exactly 37 half clocks after HBLANK rise — 40 for five counter states,
  minus three.

- **Φ0 is a 50 per cent square wave** — three half colour clocks high, three
  low. A divider clocked on one edge of CLK can only make 2:1 or 1:2, so the
  die must count both edges.

- **Φ0 is reloaded by the horizontal counter.** It rises on exactly the half
  clock where HBLANK starts, every line without exception. Towers mentions
  "some auto-synchronisation between the two-phase clock and the div-by-3
  counter for the CPU clock" without pinning it down; this is it, and it means
  the CPU phase cannot drift against the picture.

- **WSYNC releases RDY one colour clock before HBLANK starts**, not with it.

- **The data bus drivers are enabled only while Φ2 is high** — three half
  clocks of the six-half-clock bus cycle, released either side.

- **RSYNC restarts the counter four colour clocks after the strobe, rounded up
  to the counter's own falling edge.** Towers describes this as "a full
  H@1-H@2 cycle after RSYNC is strobed" and then writes "This one requires more
  investigation." Donkey Kong strobes RSYNC twice during boot; both times the
  scanline stretches from 456 to 514 half clocks and the counter grid comes back
  shifted by two colour clocks, which is what pins the rule down. Getting this
  wrong is not subtle: it leaves every later line two colour clocks out and the
  picture never lines up again.

- **The pixel pads are latched on the falling colour clock edge** — the same
  edge the horizontal counter runs on, not the MOTCK edge the object counters
  use.

- **A RESxx strobe clears its counter four colour clocks later**, which is
  Towers' "resetting the counter takes 4 CLK" and is worth taking literally.
  Sweeping that delay from 4 to 11 colour clocks against the trace, 4 gives 12
  mismatched records and every other value gives between 184 and 368. The 4 CLK
  reset, the 4 CLK decode and the 1 CLK start latch together are the famous
  9 CLK between `STA RESP0` and the first player pixel; leave the first four out
  and every object sits eight half clocks left of where the die draws it.

## Known gaps

Two real divergences, both located to the record:

- **Φ0 at an RSYNC, one half clock, trace record 4223.** The die truncates the
  high half of Φ0 to two half clocks instead of three just before the RSYNC
  restart, then resumes cleanly at record 4225; the core holds it high for the
  full three. The restart point itself is right — only the half clock before it
  is wrong. One sample is not enough to say what the rule is, and guessing one
  from it would be worse than leaving it written down.
  `sim/traces/local/donkeykong-power-on.trace` reproduces it in nine seconds of
  simulation, which is a good place to start.

- **Double-size players, 12 records, from trace record 53679.** With
  `NUSIZ0 = %101` the core draws the player six half clocks (three colour
  clocks) to the left of where the die draws it. Same width, same pixels, wrong
  position. It is specific to the stretched mode: the three-copies-close player
  earlier in the same trace, positioned by the same RESP0 machinery and then
  moved by an HMOVE, matches exactly. Three colour clocks is not a whole number
  of stretched pixels, so it is not simply a start one step late; the scan
  counter's gating from the two-phase clock is the thing to look at.

And gaps in coverage rather than in the core:

- Audio is compared but never exercised: both channels are silent throughout.
  `tia_audio.v` is built from the published AUDC mode table rather than from
  sheet 4 of the schematics and is the least trustworthy block here. Zero
  mismatches on `au0`/`au1` currently means only that silence works.
- Nothing drives the joystick or console switches. Sim2600 pulls I0–I5 high and
  leaves them there, so the input path is only checked in that state.
- Collisions, the playfield, the ball, the missiles and HMOVE have no dedicated
  coverage — only whatever Donkey Kong happens to do on its title screen, which
  is players and not much else. More cartridges would help; Sim2600 ships
  Pitfall, Space Invaders, Adventure and Asteroids.
- One cartridge, one revision. There are at least twelve NTSC TIA revisions with
  observable differences, and Sim2600's netlist is the 10444D.
- The core has never been synthesised. There is no board-level wrapper yet: no
  pin mapping onto `fpga/tia_fpga.cst`, no PLL, no tri-state on the data bus.
  Note also that the TIA's audio pad is a four-bit weighted current DAC — that
  is what `au0`/`au1` are — while the board gives each channel a single 3.3 V
  pin, so AUDV has to come back as PWM or sigma-delta on the way out.
