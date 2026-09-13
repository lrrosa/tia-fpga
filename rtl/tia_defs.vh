// tia_defs.vh -- shared constants for the tia-fpga TIA core
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Polynomial counter state constants are written exactly as they appear in
// Andrew Towers' TIA Hardware Notes, left to right, so a decode in the RTL
// can be checked against the table by eye:
//
//     Value   HCount  CLK  Control
//     111100      4    16  Set H-SYNC        [SHS]
//     110111      8    32  Reset H-SYNC      [RHS]
//
// The leftmost bit of the printed value is the most significant bit of the
// Verilog literal, so 6'b111100 is state 4 with no further translation.
//
// Both the horizontal counter and the five object counters use the same
// 6-bit LFSR: shift right, with bit 5 fed by XNOR of the two bits that have
// just fallen off the end.  q_next = { ~(q[1] ^ q[0]), q[5:1] }.

`ifndef TIA_DEFS_VH
`define TIA_DEFS_VH

// ---------------------------------------------------------------- horizontal
`define TIA_HC_SHS   6'b111100   // 4   set HSYNC
`define TIA_HC_RHS   6'b110111   // 8   reset HSYNC
`define TIA_HC_RCB   6'b001111   // 12  colour burst
`define TIA_HC_RHB   6'b011100   // 16  reset HBLANK
`define TIA_HC_LRHB  6'b010111   // 18  late reset HBLANK (after HMOVE)
`define TIA_HC_CNT   6'b101100   // 36  centre: second half of the playfield
`define TIA_HC_SHB   6'b010100   // 56  start HBLANK, reset the counter
`define TIA_HC_AUD1  6'b111011   // 9   audio clock, first tick of the line
`define TIA_HC_AUD2  6'b110110   // 37  audio clock, second tick
`define TIA_LFSR_ERR 6'b111111   // illegal state, force a reset

// ------------------------------------------------------------ object counters
`define TIA_OC_CLOSE 6'b111000   // 3   START for NUSIZ 001, 011
`define TIA_OC_MED   6'b101111   // 7   START for NUSIZ 011, 010, 110
`define TIA_OC_FAR   6'b111001   // 15  START for NUSIZ 100, 110
`define TIA_OC_MAIN  6'b101101   // 39  wrap around, START always

// --------------------------------------------------------- write register map
`define TIA_VSYNC   6'h00
`define TIA_VBLANK  6'h01
`define TIA_WSYNC   6'h02
`define TIA_RSYNC   6'h03
`define TIA_NUSIZ0  6'h04
`define TIA_NUSIZ1  6'h05
`define TIA_COLUP0  6'h06
`define TIA_COLUP1  6'h07
`define TIA_COLUPF  6'h08
`define TIA_COLUBK  6'h09
`define TIA_CTRLPF  6'h0A
`define TIA_REFP0   6'h0B
`define TIA_REFP1   6'h0C
`define TIA_PF0     6'h0D
`define TIA_PF1     6'h0E
`define TIA_PF2     6'h0F
`define TIA_RESP0   6'h10
`define TIA_RESP1   6'h11
`define TIA_RESM0   6'h12
`define TIA_RESM1   6'h13
`define TIA_RESBL   6'h14
`define TIA_AUDC0   6'h15
`define TIA_AUDC1   6'h16
`define TIA_AUDF0   6'h17
`define TIA_AUDF1   6'h18
`define TIA_AUDV0   6'h19
`define TIA_AUDV1   6'h1A
`define TIA_GRP0    6'h1B
`define TIA_GRP1    6'h1C
`define TIA_ENAM0   6'h1D
`define TIA_ENAM1   6'h1E
`define TIA_ENABL   6'h1F
`define TIA_HMP0    6'h20
`define TIA_HMP1    6'h21
`define TIA_HMM0    6'h22
`define TIA_HMM1    6'h23
`define TIA_HMBL    6'h24
`define TIA_VDELP0  6'h25
`define TIA_VDELP1  6'h26
`define TIA_VDELBL  6'h27
`define TIA_RESMP0  6'h28
`define TIA_RESMP1  6'h29
`define TIA_HMOVE   6'h2A
`define TIA_HMCLR   6'h2B
`define TIA_CXCLR   6'h2C

// ---------------------------------------------------------- read register map
// Reads decode only A3..A0, so every read address mirrors every 16 bytes.
`define TIA_CXM0P   4'h0
`define TIA_CXM1P   4'h1
`define TIA_CXP0FB  4'h2
`define TIA_CXP1FB  4'h3
`define TIA_CXM0FB  4'h4
`define TIA_CXM1FB  4'h5
`define TIA_CXBLPF  4'h6
`define TIA_CXPPMM  4'h7
`define TIA_INPT0   4'h8
`define TIA_INPT1   4'h9
`define TIA_INPT2   4'hA
`define TIA_INPT3   4'hB
`define TIA_INPT4   4'hC
`define TIA_INPT5   4'hD

`endif
