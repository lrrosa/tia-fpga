"""TIA register addresses and the start-up code every test cartridge shares.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

# ------------------------------------------------------------------ writes
VSYNC, VBLANK, WSYNC, RSYNC = 0x00, 0x01, 0x02, 0x03
NUSIZ0, NUSIZ1 = 0x04, 0x05
COLUP0, COLUP1, COLUPF, COLUBK = 0x06, 0x07, 0x08, 0x09
CTRLPF, REFP0, REFP1 = 0x0A, 0x0B, 0x0C
PF0, PF1, PF2 = 0x0D, 0x0E, 0x0F
RESP0, RESP1, RESM0, RESM1, RESBL = 0x10, 0x11, 0x12, 0x13, 0x14
AUDC0, AUDC1, AUDF0, AUDF1, AUDV0, AUDV1 = 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A
GRP0, GRP1, ENAM0, ENAM1, ENABL = 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
HMP0, HMP1, HMM0, HMM1, HMBL = 0x20, 0x21, 0x22, 0x23, 0x24
VDELP0, VDELP1, VDELBL = 0x25, 0x26, 0x27
RESMP0, RESMP1 = 0x28, 0x29
HMOVE, HMCLR, CXCLR = 0x2A, 0x2B, 0x2C

# ------------------------------------------------------------------- reads
CXM0P, CXM1P, CXP0FB, CXP1FB = 0x30, 0x31, 0x32, 0x33
CXM0FB, CXM1FB, CXBLPF, CXPPMM = 0x34, 0x35, 0x36, 0x37
INPT0, INPT1, INPT2, INPT3, INPT4, INPT5 = 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D


def cartridge_start(a, settle_lines=3):
    """What every cartridge does first, with one deliberate side effect.

    Clearing $00-$7F writes every TIA register twice -- the TIA only decodes
    A0-A5 -- and among those writes is RSYNC. That is the point: RSYNC
    restarts the die's horizontal counter from the bus, so whatever phase the
    die powered up in, the rest of the trace no longer depends on it. The core
    sees the same write and does the same thing.

    WSYNC is written too, which simply parks the CPU until the next line.
    PIA RAM is left alone; the tests do not use it.
    """
    a.label("reset")
    a.sei()
    a.cld()
    a.ldx_imm(0xFF)
    a.txs()
    a.ldx_imm(0x7F)
    a.lda_imm(0x00)
    a.label("clear")
    a.sta_zpx(0x00)
    a.dex()
    a.bpl("clear")
    for _ in range(settle_lines):
        a.sta_zp(WSYNC)
