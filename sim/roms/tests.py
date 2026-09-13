"""Directed test cartridges for the TIA core.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

Each test is a small 4K cartridge that does one thing to the TIA across many
scanlines, so a Sim2600 trace of it covers that feature from every angle a
game might hit it. None of them bothers with VSYNC or a proper frame: the
harness compares pins, not pictures, so every line can be a test line.

A test is a function returning (ROM bytes, half clocks worth recording),
registered in TESTS.

Timing is approximate on purpose. The tests do not need to know which pixel
a RESP0 lands on -- the die's answer is in the trace -- they need to land
strobes on every phase that matters, which stepping a delay loop does.
"""

from tinyasm import Asm
from tia import *                                           # noqa: F401,F403

HALF_CLOCKS_PER_LINE = 456
_labels = [0]


def _lines(n):
    # The start-up code takes about a dozen lines; leave room for it.
    return (n + 16) * HALF_CLOCKS_PER_LINE


def fresh(prefix):
    _labels[0] += 1
    return "%s_%d" % (prefix, _labels[0])


def delay(a, count):
    """LDX #count / DEX / BNE: 5 * count + 1 CPU cycles, 15 colour clocks a step.

    15 is 3 mod 4, so consecutive counts walk a strobe through all four phases
    of an object counter.
    """
    tag = fresh("delay")
    a.ldx_imm(count)
    a.label(tag)
    a.dex()
    a.bne(tag)


def poke(a, register, value):
    a.lda_imm(value)
    a.sta_zp(register)


def wait_lines(a, n):
    for _ in range(n):
        a.sta_zp(WSYNC)


# ----------------------------------------------------------------- players
def players():
    """Every NUSIZ mode, positioned by RESP0 at four sub-count phases.

    Each configuration takes three lines: one where it is set up and RESP0
    lands, then two where only the main copy draws. REFP0 alternates, and the
    graphics are asymmetric, so a reflection error cannot hide.
    """
    a = Asm()
    cartridge_start(a)
    poke(a, COLUP0, 0x1A)
    poke(a, GRP0, 0xF1)                 # %11110001: which end is which is obvious

    a.label("frame")
    n = 0
    for nusiz in (5, 7, 0, 1, 2, 3, 4, 6):
        for step in (6, 7, 8, 9):
            poke(a, NUSIZ0, nusiz)
            poke(a, REFP0, 0x08 if n % 2 else 0x00)
            delay(a, step)
            a.sta_zp(RESP0)
            wait_lines(a, 3)
            n += 1
    a.jmp("frame")
    return a.build(reset="reset"), _lines(3 * n)


# --------------------------------------------------------------- playfield
def playfield():
    """Patterns under every CTRLPF mode, then mid-line writes to PF0-PF2.

    A quad-width player sits over the playfield so SCORE and the priority bit
    have something to act on. The second half writes $FF into one PF register
    at fourteen points along the line, which pins down exactly when a
    playfield write takes effect relative to the playfield's own clock.
    """
    a = Asm()
    cartridge_start(a)
    poke(a, COLUPF, 0x2A)
    poke(a, COLUP0, 0x84)
    poke(a, COLUP1, 0xC6)
    poke(a, NUSIZ0, 0x07)
    poke(a, GRP0, 0xFF)
    a.sta_zp(WSYNC)
    delay(a, 9)
    a.sta_zp(RESP0)
    a.sta_zp(WSYNC)

    a.label("frame")
    patterns = ((0xF0, 0xFF, 0xFF), (0x50, 0xAA, 0x55), (0xA0, 0x55, 0xAA),
                (0x10, 0x80, 0x01), (0x80, 0x01, 0x80))
    lines = 0
    for ctrl in (0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06):
        for pf0, pf1, pf2 in patterns:
            poke(a, CTRLPF, ctrl)
            poke(a, PF0, pf0)
            poke(a, PF1, pf1)
            poke(a, PF2, pf2)
            wait_lines(a, 2)
            lines += 2
    poke(a, CTRLPF, 0x00)
    for register in (PF0, PF1, PF2):
        for step in range(1, 15):
            a.lda_imm(0x00)
            a.sta_zp(PF0)
            a.sta_zp(PF1)
            a.sta_zp(PF2)
            delay(a, step)
            poke(a, register, 0xFF)
            wait_lines(a, 1)
            lines += 1
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


# -------------------------------------------------------------------- ball
def ball():
    """Ball widths at four phases, retriggering with RESBL, and VDELBL."""
    a = Asm()
    cartridge_start(a)
    poke(a, COLUPF, 0x4E)
    poke(a, ENABL, 0x02)

    a.label("frame")
    lines = 0
    for size in (0x00, 0x10, 0x20, 0x30):
        for step in (6, 7, 8, 9):
            poke(a, CTRLPF, size)
            delay(a, step)
            a.sta_zp(RESBL)
            wait_lines(a, 3)
            lines += 3
    # Unlike every other object, RESBL starts the ball drawing at once, so
    # strobing it repeatedly on one line draws it repeatedly.
    for size in (0x00, 0x10, 0x20, 0x30):
        for gap in (0, 1, 2, 3):
            poke(a, CTRLPF, size)
            delay(a, 5)
            for _ in range(4):
                a.sta_zp(RESBL)
                for _ in range(gap):
                    a.nop()
            wait_lines(a, 2)
            lines += 2
    # VDELBL shows the old ENABL, which is copied from the new one on every
    # write to GRP1.
    poke(a, CTRLPF, 0x20)
    poke(a, VDELBL, 0x01)
    for enable, touch_grp1 in ((0x02, False), (0x02, True), (0x00, False),
                               (0x00, True), (0x02, True)):
        poke(a, ENABL, enable)
        if touch_grp1:
            a.sta_zp(GRP1)
        wait_lines(a, 2)
        lines += 2
    poke(a, VDELBL, 0x00)
    poke(a, ENABL, 0x02)
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


# ---------------------------------------------------------------- missiles
def missiles():
    """Missile widths and copies at two phases, then RESMP at every player size."""
    a = Asm()
    cartridge_start(a)
    poke(a, COLUP0, 0x1A)
    poke(a, COLUP1, 0x7C)
    poke(a, ENAM0, 0x02)
    poke(a, ENAM1, 0x02)

    a.label("frame")
    lines = 0
    for size in (0x00, 0x10, 0x20, 0x30):
        for copies in (0, 1, 3, 6):
            for step in (6, 7):
                a.lda_imm(size | copies)
                a.sta_zp(NUSIZ0)
                a.sta_zp(NUSIZ1)
                delay(a, step)
                a.sta_zp(RESM0)
                a.nop()
                a.sta_zp(RESM1)
                wait_lines(a, 3)
                lines += 3
    # RESMP parks the missile in the middle of its player, and where the
    # middle is depends on the player's size.
    poke(a, GRP0, 0xFF)
    for nusiz in (0x00, 0x05, 0x07, 0x03):
        poke(a, NUSIZ0, nusiz)
        delay(a, 8)
        a.sta_zp(RESP0)
        poke(a, RESMP0, 0x02)
        wait_lines(a, 3)
        poke(a, RESMP0, 0x00)
        wait_lines(a, 2)
        lines += 5
    poke(a, GRP0, 0x00)
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


# ------------------------------------------------------------------- hmove
def hmove():
    """All sixteen motion values, late and mid-line HMOVE, and Cosmic Ark."""
    a = Asm()
    cartridge_start(a)
    poke(a, COLUP0, 0x1A)
    poke(a, COLUP1, 0x7C)
    poke(a, COLUPF, 0x4E)
    poke(a, GRP0, 0x81)
    poke(a, GRP1, 0xC3)
    poke(a, ENAM0, 0x02)
    poke(a, ENAM1, 0x02)
    poke(a, ENABL, 0x02)
    poke(a, CTRLPF, 0x10)
    poke(a, NUSIZ0, 0x10)
    a.sta_zp(WSYNC)
    delay(a, 6)
    a.sta_zp(RESP0)
    a.sta_zp(RESM0)
    delay(a, 3)
    a.sta_zp(RESP1)
    a.sta_zp(RESM1)
    delay(a, 2)
    a.sta_zp(RESBL)
    a.sta_zp(WSYNC)

    def set_motion(value):
        a.lda_imm(value)
        for register in (HMP0, HMP1, HMM0, HMM1, HMBL):
            a.sta_zp(register)

    a.label("frame")
    lines = 0
    # The documented way: HMOVE first thing after WSYNC. The motion registers
    # are changed well clear of it, ready for the next one.
    for value in range(16):
        a.sta_zp(HMOVE)
        delay(a, 7)
        set_motion((value << 4) & 0xFF)
        wait_lines(a, 2)
        lines += 2
    # HMOVE later in HBLANK, so its pulses run past the end of it.
    for value in (0x70, 0x80, 0x00):
        set_motion(value)
        delay(a, 13)
        a.sta_zp(HMOVE)
        wait_lines(a, 2)
        lines += 2
    # HMOVE during the visible line.
    set_motion(0x70)
    for step in (6, 8, 10):
        delay(a, step)
        a.sta_zp(HMOVE)
        wait_lines(a, 2)
        lines += 2
    # Cosmic Ark: rewrite HMM0 while the HMOVE is still counting, so its
    # comparator never matches and the missile keeps moving on every line.
    set_motion(0x70)
    a.sta_zp(WSYNC)
    a.sta_zp(HMOVE)
    delay(a, 3)
    poke(a, HMM0, 0x60)
    wait_lines(a, 6)
    # HMCLR partway through, the other way to get stuck.
    a.sta_zp(HMOVE)
    delay(a, 3)
    a.sta_zp(HMCLR)
    wait_lines(a, 4)
    lines += 11
    set_motion(0x00)
    a.sta_zp(HMOVE)
    wait_lines(a, 2)
    lines += 2
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


# -------------------------------------------------------------- collisions
def collisions():
    """Everything overlapping everything, read back every line; input ports."""
    a = Asm()
    cartridge_start(a)
    poke(a, COLUP0, 0x1A)
    poke(a, COLUP1, 0x7C)
    poke(a, COLUPF, 0x4E)
    poke(a, GRP0, 0xFF)
    poke(a, GRP1, 0xFF)
    poke(a, ENAM0, 0x02)
    poke(a, ENAM1, 0x02)
    poke(a, ENABL, 0x02)
    poke(a, PF1, 0x81)
    poke(a, PF2, 0x18)
    poke(a, CTRLPF, 0x31)
    poke(a, NUSIZ0, 0x37)
    poke(a, NUSIZ1, 0x35)

    a.label("frame")
    lines = 0
    strobes = (RESP0, RESP1, RESM0, RESM1, RESBL)
    for i in range(30):
        a.sta_zp(WSYNC)
        for register in range(CXM0P, CXPPMM + 1):
            a.lda_zp(register)
        a.lda_zp(0x3E)                 # no register here
        a.sta_zp(CXCLR)
        delay(a, 2 + (i * 7) % 11)
        a.sta_zp(strobes[i % 5])
        a.sta_zp(WSYNC)
        lines += 2
    # Input ports: VBLANK D7 grounds the paddle inputs, D6 latches the
    # trigger inputs. Sim2600 holds every input pad high.
    for vblank in (0x00, 0x80, 0x40, 0xC0, 0x00):
        poke(a, VBLANK, vblank)
        a.sta_zp(WSYNC)
        for register in range(INPT0, INPT5 + 1):
            a.lda_zp(register)
        a.sta_zp(WSYNC)
        lines += 2
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


# ------------------------------------------------------------------ audio
def audio():
    """The volume DAC at every level, then every AUDC mode on both channels."""
    a = Asm()
    cartridge_start(a)

    a.label("frame")
    lines = 0
    poke(a, AUDC0, 0x04)                # a pure tone, to see the taps switch
    poke(a, AUDF0, 0x00)
    for volume in range(16):
        poke(a, AUDV0, volume)
        wait_lines(a, 2)
        lines += 2
    poke(a, AUDV0, 0x0F)
    poke(a, AUDV1, 0x08)
    for mode in range(16):
        poke(a, AUDC0, mode)
        poke(a, AUDC1, 15 - mode)
        for freq in (0x00, 0x11):
            poke(a, AUDF0, freq)
            poke(a, AUDF1, freq ^ 0x1F)
            wait_lines(a, 5)
            lines += 5
    poke(a, AUDV0, 0x00)
    poke(a, AUDV1, 0x00)
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


def audio_modes():
    """Each AUDC mode on channel 0 for 80 audio clock ticks, then the 9-bit poly
    for a full period, then the frequency divider.

    The short sections of `audio` show which modes make a tone at all; this one
    is long enough to see each polynomial counter's whole sequence, which is
    what it takes to pin down its taps and the order its stages run in.
    """
    a = Asm()
    cartridge_start(a)

    a.label("frame")
    lines = 0
    poke(a, AUDV1, 0x00)
    poke(a, AUDV0, 0x0F)
    poke(a, AUDF0, 0x00)
    for mode in range(16):
        poke(a, AUDC0, mode)
        wait_lines(a, 40)
        lines += 40
    poke(a, AUDC0, 0x08)
    wait_lines(a, 260)
    lines += 260
    poke(a, AUDC0, 0x04)
    for freq in (0x01, 0x02, 0x05, 0x1F):
        poke(a, AUDF0, freq)
        wait_lines(a, 24)
        lines += 24
    poke(a, AUDV0, 0x00)
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


# -------------------------------------------------------------- vertical delay
def vdel():
    """VDELP0 and VDELP1 in all four combinations, graphics changing every line."""
    a = Asm()
    cartridge_start(a)
    poke(a, COLUP0, 0x1A)
    poke(a, COLUP1, 0x7C)
    a.sta_zp(WSYNC)
    delay(a, 7)
    a.sta_zp(RESP0)
    delay(a, 3)
    a.sta_zp(RESP1)
    a.sta_zp(WSYNC)

    a.label("frame")
    lines = 0
    shapes = (0x81, 0x3C, 0xFF, 0x18, 0xE7, 0x00, 0xA5, 0x5A)
    for vdel0, vdel1 in ((0, 0), (1, 0), (0, 1), (1, 1)):
        poke(a, VDELP0, vdel0)
        poke(a, VDELP1, vdel1)
        for i in range(8):
            poke(a, GRP0, shapes[i])
            poke(a, GRP1, shapes[(i + 3) % 8])
            wait_lines(a, 1)
            lines += 1
    a.jmp("frame")
    return a.build(reset="reset"), _lines(lines)


TESTS = {
    "players": players,
    "playfield": playfield,
    "ball": ball,
    "missiles": missiles,
    "hmove": hmove,
    "collisions": collisions,
    "audio": audio,
    "audio_modes": audio_modes,
    "vdel": vdel,
}
