#!/usr/bin/env python3
"""A very small 6502 assembler, for writing TIA test cartridges in Python.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

The test ROMs here need a few dozen instructions and exact control over what
happens on which scanline, and nothing else. Writing them in Python keeps the
harness dependent on nothing but Python and Icarus Verilog -- no DASM, no
toolchain to install -- and lets a test compute its own register values.

Every instruction is a method named after its mnemonic and addressing mode:

    a = Asm()
    a.label("reset")
    a.sei(); a.cld(); a.ldx_imm(0xFF); a.txs()
    a.label("loop")
    a.sta_zp(0x02)           # STA WSYNC
    a.dex()
    a.bne("loop")
    rom = a.build(reset="reset")      # 4096 bytes for $F000-$FFFF

Branches and jumps take label names, resolved when the ROM is built.
"""

IMPLIED = {
    "brk": 0x00, "clc": 0x18, "sec": 0x38, "cli": 0x58, "sei": 0x78,
    "clv": 0xB8, "cld": 0xD8, "sed": 0xF8, "tax": 0xAA, "txa": 0x8A,
    "tay": 0xA8, "tya": 0x98, "tsx": 0xBA, "txs": 0x9A, "inx": 0xE8,
    "iny": 0xC8, "dex": 0xCA, "dey": 0x88, "nop": 0xEA, "pha": 0x48,
    "pla": 0x68, "php": 0x08, "plp": 0x28, "rts": 0x60, "rti": 0x40,
    "asl_a": 0x0A, "lsr_a": 0x4A, "rol_a": 0x2A, "ror_a": 0x6A,
}

# mnemonic -> opcode, one table per addressing mode
IMMEDIATE = {
    "lda": 0xA9, "ldx": 0xA2, "ldy": 0xA0, "cmp": 0xC9, "cpx": 0xE0,
    "cpy": 0xC0, "adc": 0x69, "sbc": 0xE9, "and": 0x29, "ora": 0x09,
    "eor": 0x49,
}
ZEROPAGE = {
    "lda": 0xA5, "ldx": 0xA6, "ldy": 0xA4, "sta": 0x85, "stx": 0x86,
    "sty": 0x84, "inc": 0xE6, "dec": 0xC6, "bit": 0x24, "cmp": 0xC5,
    "adc": 0x65, "sbc": 0xE5, "and": 0x25, "ora": 0x05, "eor": 0x45,
    "asl": 0x06, "lsr": 0x46,
}
ZEROPAGE_X = {
    "lda": 0xB5, "ldy": 0xB4, "sta": 0x95, "sty": 0x94, "inc": 0xF6,
    "dec": 0xD6,
}
ABSOLUTE = {
    "lda": 0xAD, "ldx": 0xAE, "ldy": 0xAC, "sta": 0x8D, "bit": 0x2C,
    "inc": 0xEE, "dec": 0xCE,
}
ABSOLUTE_X = {"lda": 0xBD, "sta": 0x9D}
ABSOLUTE_Y = {"lda": 0xB9, "ldx": 0xBE, "sta": 0x99}
RELATIVE = {
    "bpl": 0x10, "bmi": 0x30, "bvc": 0x50, "bvs": 0x70,
    "bcc": 0x90, "bcs": 0xB0, "bne": 0xD0, "beq": 0xF0,
}


class AsmError(Exception):
    pass


class Asm(object):
    def __init__(self, org=0xF000):
        self.org = org
        self.code = bytearray()
        self.labels = {}
        self.fixups = []            # (offset in code, label, "rel" | "abs")

    @property
    def pc(self):
        return self.org + len(self.code)

    def label(self, name):
        if name in self.labels:
            raise AsmError("label %r defined twice" % name)
        self.labels[name] = self.pc

    def data(self, *values):
        for v in values:
            if not 0 <= v <= 0xFF:
                raise AsmError("byte out of range: %r" % v)
            self.code.append(v)

    # -- control flow, which needs labels -----------------------------------
    def _branch(self, opcode, target):
        self.code.append(opcode)
        self.fixups.append((len(self.code), target, "rel"))
        self.code.append(0)

    def _absolute_label(self, opcode, target):
        self.code.append(opcode)
        self.fixups.append((len(self.code), target, "abs"))
        self.code.extend(b"\x00\x00")

    def jmp(self, target):
        self._absolute_label(0x4C, target)

    def jsr(self, target):
        self._absolute_label(0x20, target)

    def lda_absx_label(self, target):
        """LDA table,X with a label for the table."""
        self._absolute_label(0xBD, target)

    # -- everything is resolved here -----------------------------------------
    def build(self, reset, size=4096, fill=0xFF):
        code = bytearray(self.code)
        for offset, target, kind in self.fixups:
            if target not in self.labels:
                raise AsmError("undefined label %r" % target)
            address = self.labels[target]
            if kind == "rel":
                delta = address - (self.org + offset + 1)
                if not -128 <= delta <= 127:
                    raise AsmError("branch to %r out of range (%d)" % (target, delta))
                code[offset] = delta & 0xFF
            else:
                code[offset] = address & 0xFF
                code[offset + 1] = (address >> 8) & 0xFF

        if self.org + size != 0x10000:
            raise AsmError("the ROM has to end at $FFFF for the vectors to land")
        if len(code) > size - 6:
            raise AsmError("program is %d bytes, which runs into the vectors" % len(code))

        rom = bytearray([fill] * size)
        rom[:len(code)] = code
        start = self.labels[reset]
        for vector in (size - 6, size - 4, size - 2):     # NMI, RESET, IRQ/BRK
            rom[vector] = start & 0xFF
            rom[vector + 1] = (start >> 8) & 0xFF
        return bytes(rom)


def _implied(opcode):
    def emit(self):
        self.code.append(opcode)
    return emit


def _operand(opcode, width):
    def emit(self, value):
        if not 0 <= value < (1 << (8 * width)):
            raise AsmError("operand $%X does not fit in %d byte(s)" % (value, width))
        self.code.append(opcode)
        self.code.append(value & 0xFF)
        if width == 2:
            self.code.append((value >> 8) & 0xFF)
    return emit


def _relative(opcode):
    def emit(self, target):
        self._branch(opcode, target)
    return emit


for _name, _op in IMPLIED.items():
    setattr(Asm, _name, _implied(_op))
for _suffix, _table, _width in (("imm", IMMEDIATE, 1), ("zp", ZEROPAGE, 1),
                                ("zpx", ZEROPAGE_X, 1), ("abs", ABSOLUTE, 2),
                                ("absx", ABSOLUTE_X, 2), ("absy", ABSOLUTE_Y, 2)):
    for _name, _op in _table.items():
        setattr(Asm, "%s_%s" % (_name, _suffix), _operand(_op, _width))
for _name, _op in RELATIVE.items():
    setattr(Asm, _name, _relative(_op))


if __name__ == "__main__":
    # A self-check against hand-assembled bytes.
    a = Asm()
    a.label("start")
    a.lda_imm(0x12)          # A9 12
    a.sta_zp(0x02)           # 85 02
    a.label("loop")
    a.dex()                  # CA
    a.bne("loop")            # D0 FD
    a.jmp("start")           # 4C 00 F0
    rom = a.build(reset="start")
    got = rom[:10].hex(" ").upper()
    want = "A9 12 85 02 CA D0 FD 4C 00 F0"
    assert got == want, (got, want)
    assert rom[0xFFC:0xFFE] == b"\x00\xF0"
    print("tinyasm self-check passed:", got)
