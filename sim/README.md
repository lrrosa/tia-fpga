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
`sim/traces/` and `sim/traces/local/`, then the same cartridges recorded with
the console's wiring of the TIA's Φ2 pin, in `sim/traces/phi2/` and
`sim/traces/local/phi2/` (see *Which clock the TIA sees*). It takes a few
minutes; `--align 0` skips the alignment search and makes it quicker.

The `local` directories are different on purpose. `sim/traces/` holds traces
of the project's own test cartridges and is committed. `sim/traces/local/`
holds traces recorded from commercial cartridges and is ignored by git: even
with the bus scrubbed (see *Trace format*), what a game writes into GRP0 and
PF0-PF2 is its artwork, and that is not ours to publish. Regenerate those
locally with the commands under *Generating a trace*.

## Current results

Every trace is recorded twice from the same cartridge: once with Sim2600 as it
comes, and once with CLK2 wired the way the console wires it. "Match" means
every pin at every half clock scored — Φ0, RDY, composite sync, blanking,
luminance, colour, the data bus drivers and both audio pads.

| trace | what it exercises | half clocks scored | Sim2600's wiring | console's wiring |
|---|---|---:|:---:|:---:|
| `local/donkeykong-boot-to-picture` | a real game, power-on to its first picture | 51,657 | match | match |
| `local/donkeykong-power-on` | the first 6,000 half clocks, both RSYNCs | 3,657 | match | — |
| `playfield` | every CTRLPF mode, mid-line PF writes | 54,063 | match | match |
| `players` | every NUSIZ mode at all four sub-count phases | 46,767 | match | match |
| `missiles` | widths, copies, RESMP at every player size | 55,887 | match | match |
| `ball` | widths at every phase, RESBL retriggering, VDELBL | 44,031 | match | match |
| `collisions` | everything overlapping, all eight CX reads, input ports | 34,911 | match | match |
| `hmove` | all sixteen values, HMOVE late and mid-line, Cosmic Ark | 28,983 | match | match |
| `resets_hblank` | RESP0 at three sizes, RESM0 and RESBL, at every phase of HBLANK | 85,071 | match | match |
| `vdel` | VDELP0 and VDELP1 in all four combinations | 17,583 | match | match |
| `audio` | the volume DAC, and every AUDC mode on both channels | 90,543 | match | match |
| `audio_modes` | each AUDC mode for 80 ticks, the 9-bit polynomial for a whole period, the divider | 457,167 | match | match |

The suite reports FAIL on a single mismatched half clock, with no tolerance
anywhere, so a regression on any pin of any trace shows at once.

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

For the console's wiring, make a second checkout the same way and apply one
more patch on top:

```bash
git clone -c core.autocrlf=false https://github.com/gregjames/Sim2600.git Sim2600-phi2
cd Sim2600-phi2
git checkout af3bc453e253172503967ffb826377517b95a62a
git apply ../tia-fpga/sim/patches/sim2600-py3.patch
git apply ../tia-fpga/sim/patches/sim2600-phi2.patch
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

`sim2600-phi2.patch` is the clock wiring, explained in the next section.

Sim2600 is MIT licensed, and the patches are modifications of it, so they are
offered under the MIT licence too, not the CERN-OHL-S that covers the rest of
this repository. Their headers say so.

## Which clock the TIA sees

Upstream `sim2600Console.py` drives the TIA's CLK2 pad from the 6507's
**CLK1OUT**. On the console, TIA pin 26 is wired to the 6507's Φ2 output — in
the visual6502 netlist, **CLK2OUT**, the other polarity. The traces say so too:
in an upstream trace `clk2` is the inverse of `ph0` one half clock later, and
the 6507 puts a new address on the bus as that pad rises, its write data as it
falls. On a 6502 the address comes out in phase 1 and the data in phase 2, so
the pad the die was given is high in phase 1.

The die only looks at that pin through its bus strobes, so the simulation ran
happily either way. What changes is where every write lands against the colour
clock: each write strobe on the die is high for the three half clocks CLK2 is
low after the write, and with the wiring flipped those three half clocks sit
on the other side of PH0 and start on the other edge of the colour clock. Any
rule this core had fitted from one wiring alone could have been fitted to the
wrong side, and several were: RSYNC's restart, RDY's release, how long a
reset holds an object's clock, the size gate of stretched players, and when
HMOVE's comparators see a new HMxx value (all below, as read off the
netlist).

`sim2600-phi2.patch` takes CLK2 from CLK2OUT, and updates it at the start of
each half clock, before the bus, because on the console Φ2 falls before the
6507 moves its address. `sim/traces/phi2/` was recorded with it.

Two things in the harness follow from that order. A trace record shows the bus
*after* the 6507 moved it, so with the console's wiring the record in which
CLK2 falls already shows the next cycle, while the die latched the old one.
`tb_trace.v` therefore tells the two wirings apart by how `clk2` follows `ph0`
and, for the console's, holds the bus while CLK2 is low, which is what the
die's own latch does. And the board has no Φ2 pin at all — it rebuilds Φ2 from
the Φ0 it makes — so `tb_board.v` checks the rebuilt one against these traces.

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
python sim/roms/make.py --sim2600 ../Sim2600-phi2 --traces sim/traces/phi2
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
python sim/gen_trace.py --sim2600 ../Sim2600-phi2 --rom DonkeyKong.bin --quiet \
       --skip 0 --count 54000 \
       --out sim/traces/local/phi2/donkeykong-boot-to-picture.trace
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
`+dump=FILE`, which writes the core's luminance, colour, sync, blank, RDY, data
bus drive and colour burst for every scored record; comparing that with the
trace a scanline at a time is the fastest way to see *how* something diverges —
a constant offset, a pixel too wide, a copy missing.

### The board around the core

`tb_board.v` replays a console-wired trace into `rtl/tia_board.v` instead —
the logic between the core and rev A's pins — and checks what the board
drives: the colour clock counted out of the PLL clock and CLK2 rebuilt from
Φ0, record for record against the trace; Φ0, RDY, sync and luma on the pins;
D7/D6 wherever the die drove them, with A5-A0 beneath; the chroma waveform's
phase for every hue, measured against the burst's; and the pulse widths on
both sound pins, for both settings of `AUDIO_STEREO` at once.

```bash
iverilog -g2005 -I rtl -s tb_board -o tb_board.vvp sim/tb_board.v rtl/*.v
vvp tb_board.vvp +trace=sim/traces/phi2/ball.trace
```

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

## Looking inside the die

When a mismatch will not give way to reasoning about pins, look inside the
die. Sim2600's TIA has 2,660 wires, and every one of them can be recorded:

```bash
pip install numpy
python sim/probe_die.py --sim2600 ../Sim2600 \
       --rom sim/roms/build/players.bin --count 51072 --out players.npy
```

This runs the cartridge exactly as `gen_trace.py --skip 0` does, so record k
of the probe is record k of the committed trace, and it adds little to the
simulation's own running time. Only the pads, the register strobes and a few
buses have names; every other wire is `N<index>`, so the other half of the job
is reading the logic around a wire:

```bash
python sim/netlist.py --sim2600 ../Sim2600 node  RESP0_metal
python sim/netlist.py --sim2600 ../Sim2600 tree  N2203 --depth 4
python sim/netlist.py --sim2600 ../Sim2600 loads N1703
python sim/netlist.py --sim2600 ../Sim2600 waves --probe audio.npy \
       --trace sim/traces/audio.trace --line 60 N1703 N2591
```

The recipe behind the reset and audio findings below: follow a named strobe
to the latches it forces; find a register's bits by correlating every wire
with a model's state, since a real bit agrees on every sample; read where each
clock sits in the line with `waves`; then read the logic with `tree`. Where a
model still disagreed with the die, the die's own latches showed which tick
went wrong. With two wirings to record, one more trick earns its keep: probe
the same cartridge through both checkouts and print the same wires around the
same write side by side.

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
  line, with either wiring.
- **RSYNC restarts the counter seven half clocks after the last half clock its
  strobe shares with PH0 low.** RSYNC's decode is a NOR that takes PH0 as one of
  its inputs, so of the three half clocks its strobe is high, only those with
  PH0 low count. HBLANK comes on at the restart and Φ0 reloads, which cuts both
  its halves to two half clocks with Sim2600's wiring and cuts nothing with the
  console's. Towers left RSYNC as "requires more investigation"; counting from
  the write instead, as this core first did, fits one wiring and misses the
  other by four half clocks.

**The bus**

- **The data bus drivers are enabled only while the die's CLK2 pad is high** —
  three half clocks of the six-half-clock bus cycle, Φ2 on a console — on every
  selected read, including the two read addresses with no register behind
  them, which read as zeros.
- **Every write strobe is high for the three half clocks CLK2 is low after the
  write.** The decode is latched while CLK2 is high; the strobe follows.
- **RDY is released by a pulse eight half clocks long, starting three half
  clocks before HBLANK.** WSYNC's strobe sets a latch that pulls RDY low; the
  pulse clears it in whichever of its half clocks the colour clock is low, the
  first of them one colour clock before HBLANK. The same pulse is an input to
  WSYNC's decode, so a strobe that overlaps it only sets RDY once it ends, and
  a strobe entirely inside it is lost.

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
- **The colour pad carries the colour clock itself, and is released when there
  is no colour.** For hues 1-15 it toggles every half clock; for hue 0, and
  through blanking, it is left alone. The burst runs from RHS to RCB — Towers'
  "reset colour burst" — starting one half clock after the sync pulse ends,
  and it is not sent on lines VBLANK blanks.

**The pads**

- **Every video and sound pad is a pull-down transistor and nothing else**:
  SYNC, LUM0-2, COL, AUD0, AUD1, BLK and RDY. The console supplies the
  pull-ups. Φ0 is the only output driven both ways.

**Objects** — read off the netlist, with the tools under *Looking inside the
die*

- **A RESxx strobe does not reset the counter. It holds the object's
  two-phase clock in H@1 and sets a latch.** The two-phase clock is a ring of
  four half-clock stages. For as long as the strobe is high the ring is cleared
  and read as H@1; on the next H@2 the latch lets go and starts a pulse one
  count long that forces every stage of the counter to zero. The counter
  therefore clears on the first H@2 after the strobe and counts on from there.
- **How many object clocks the hold swallows depends on where the strobe
  falls.** Its three half clocks cover one MOTCK phase with Sim2600's wiring
  and two with the console's. On this core's clock grid, which runs three half
  clocks behind the die's ring, the hold is the strobe's window three half
  clocks later.
- **That is why a copy already on its way can survive a reset.** START decodes
  pass through a latch that follows them for all of H@1, so holding the ring
  in H@1 catches a START decoded just before the strobe and clocks it out on
  the new phase — if the decode is still true when the held H@1 ends, which
  with the console's wiring it more often is not.
- **In HBLANK the ring cannot move**, because MOTCK is stopped: a reset there
  waits in H@1 for the first colour clock of the visible line and clears the
  counter on the second.
- **The ball's START is its counter's clear pulse, and its width is that pulse
  plus a delayed copy.** The clear, whether from RESBL or from the wrap, lasts
  one count, and a second latch stage repeats it for the count after. One and
  two pixels are the first colour clocks of the first count, four is that
  count, eight is both. Strobe RESBL again while the copy is running and the
  die draws one unbroken run, which a width counter reloaded on every START
  cannot do. Missiles take their width the same way.
- **Double- and quad-size players start one colour clock later than
  single-size ones**, and their first stretched pixel is as wide as the rest.
  The scan counter itself counts every colour clock, behind a gate that holds
  it back after a half clock in neither phase (2×) or in anything but H@2
  (4×). The gate is the object's two-phase state caught by a pair of latches
  on MOTCK — the same latches START goes through — so it holds its value
  through HBLANK and follows a NUSIZ write one MOTCK late. A reset's hold reads
  as H@1, which opens a double-size player's gate and closes a quad-size
  one's: reset a stretched copy while it is being drawn and one of its pixels
  comes out half width with Sim2600's wiring, three with the console's.
- **RESMP's lock is decoded at scan position 1** of the player's main copy.

**HMOVE**

- **The first compare has to come before the first decrement.** Whether the
  counter steps down first depends only on where in the two-phase cycle
  `STA HMOVE` lands; when it does, an HMxx of −8 never matches, and the object
  receives sixteen pulses instead of none.
- **The motion process runs 12 half clocks behind the horizontal counter.**
  An HMOVE at the start of a line stuffs its pulses 33, 41, … 145 half clocks
  into it, and they count while HBLANK is on — through the HMOVE latch's
  extension to LRHB too, since that is when MOTCK is stopped. The comparators
  read the HMxx registers on that later grid, which is why Cosmic Ark's HMM0
  write, 139 half clocks into the line, still withholds the missile's last
  pulse.
- **The comparators look a little early, and the counter stops at zero.** The
  die catches each compare in a latch on the motion clock and acts on it half
  a count later, so a new HMxx value only counts if it was written a few half
  clocks before the compare. With the console's wiring Cosmic Ark's write
  lands at 142 half clocks, just too late: the missile's latch is never
  cleared, the motion counter sits at zero instead of wrapping round to match
  again, and the missile moves on every line until the next HMOVE — the
  starfield proper.
- **Past HBLANK a pulse merges into MOTCK, and the pads see it.** The motion
  clock never stops, and each object's clock is MOTCK OR (its latch AND the
  motion clock), so in the visible line a pulse fills in a low half of MOTCK.
  That gains no count — an HMOVE in the middle of the line moves nothing —
  but Sim2600 settles MOTCK's fall before the motion clock's rise, and in that
  instant the object's latches step: the probe shows M0's slave latch
  changing on a half clock that ends with its clock high, which only a
  momentary low can do. The object shows its next state half a colour clock
  early, on exactly the half clock the pads latch it, and its next MOTCK
  finds nothing left to do. That is how a one-pixel missile beside its player
  vanishes after a mid-line HMOVE, and how Cosmic Ark's moving missile loses
  or gains a pixel on some lines.

**Audio** — also read off the netlist, then checked tick by tick against the
die's own divider and counters, not just its pads

- **Each audio tick has two phases.** Phase A, at counts 1 and 19, compares
  the divider with AUDF, latches the result as the tick's enable and, on an
  enabled tick, latches the hold decision and the feedback bits from AUDC as
  it is at that moment. Phase B, at counts 9 and 37, shifts the counters; the
  pads change there, 112 and 116 colour clocks apart rather than an even 114.
- **AUDF is compared, not loaded.** The divider is a binary counter cleared on
  an enabled tick, so lowering AUDF below the count lets it run on to 31 and
  wrap before the channel ticks again.
- **The pulse counter has no lockup guards.** Stella keeps its 4-bit
  polynomial away from %1010 and the divide-by-6 away from %0000; the netlist
  has neither term, and the simulated die does step from %0000 to %1111 in
  AUDC C.
- **The two channels are not wired alike.** Channel 0's phase-A latches follow
  the enable latched in that same phase; channel 1 takes the enable through one
  more latch and follows the tick before, which is how Stella models both.
  The difference only shows on the first tick after the divider lets a
  channel run again with AUDC changed in the meantime — one period of one
  channel, which on a console that joins the two sound pins, as an unmodified
  2600 does, is lost in the mix.
- **AUDC 0 and B hold the output at the AUDV level** — a DC offset, not silence.

**Inputs**

- **VBLANK D7 grounds the paddle inputs**, which then read as zero.

## Known gaps

- **Merged HMOVE pulses are a race.** On the die MOTCK falls as the motion
  clock rises; Sim2600 settles the fall first and the core follows it (see
  *HMOVE*). A real chip may not glitch at all, and no trace reads collisions
  while a pulse merges.
- **Whether real chips share the audio channels' asymmetry** (see *Audio*), or
  it came in with the extraction of the netlist. Sim2600 is the only oracle,
  so the core follows it and `tia_audio.v` keeps the difference to one
  parameter; on an unmodified console it is inaudible either way.
- Nothing drives the joystick or console switches. Sim2600 holds I0-I5 high,
  so the trigger latch has never been exercised.
- One die revision. There are at least twelve NTSC TIA revisions with
  observable differences, and Sim2600's netlist is the 10444D.
- The board wrapper has been simulated and synthesised with Yosys
  (`fpga/check_synth.py`), but not built with Gowin EDA or run on hardware,
  and rev A's video and sound pins cannot reproduce the TIA's levels — see
  *Pads and levels* in the project README.
