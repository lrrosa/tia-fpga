// tia_fpga_top.v -- top level, Sipeed Tang Nano 9K (GW1NR-LV9QN88PC6/I5).
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/lrrosa/tia-fpga
//
// The port names are the FPGA-side net labels of tia-fpga.kicad_sch and the
// IO_LOC names of tia_fpga.cst. Only Gowin primitives live here -- the PLL,
// the data bus buffers and the chroma ODDR. Everything else is in
// rtl/tia_board.v, which the testbench can drive without them.

module tia_fpga_top #(
    parameter OSC_MULT     = 16,   // PLL ratio; ODIV below suits 12 to 20
    parameter AUDIO_STEREO = 0     // see rtl/tia_board.v before changing
) (
    input  wire F_OSC,             // 3.579545 MHz from the console, via U4

    input  wire F_A0, F_A1, F_A2, F_A3, F_A4, F_A5,
    input  wire F_CS_N,            // /CS0 OR /CS3, from U5
    input  wire F_RW,
    inout  wire F_D0, F_D1, F_D2, F_D3, F_D4, F_D5, F_D6, F_D7,

    output wire F_PHI0,
    output wire F_RDY,
    input  wire F_I4, F_I5,

    output wire F_CSYNC,
    output wire F_BLK,
    output wire F_LUM0, F_LUM1, F_LUM2,
    output wire F_COL,
    output wire F_AU0, F_AU1
);

    // ================================================================= PLL
    // The colour clock times OSC_MULT: 57.27 MHz by default. The compiler
    // holds the VCO to 600..1200 MHz; ODIV = 16 puts it at 687..1145 MHz for
    // OSC_MULT 12 to 20. The phase detector runs at the input frequency,
    // inside its 3 MHz minimum.
    wire clk, locked;

    rPLL #(
        .FCLKIN           ("3.579545"),
        .DEVICE           ("GW1NR-9C"),
        .DYN_IDIV_SEL     ("false"),
        .IDIV_SEL         (0),
        .DYN_FBDIV_SEL    ("false"),
        .FBDIV_SEL        (OSC_MULT - 1),
        .DYN_ODIV_SEL     ("false"),
        .ODIV_SEL         (16),
        .PSDA_SEL         ("0000"),
        .DYN_DA_EN        ("false"),
        .DUTYDA_SEL       ("1000"),
        .CLKOUT_FT_DIR    (1'b1),
        .CLKOUTP_FT_DIR   (1'b1),
        .CLKOUT_DLY_STEP  (0),
        .CLKOUTP_DLY_STEP (0),
        .CLKFB_SEL        ("internal"),
        .CLKOUT_BYPASS    ("false"),
        .CLKOUTP_BYPASS   ("false"),
        .CLKOUTD_BYPASS   ("false"),
        .DYN_SDIV_SEL     (2),
        .CLKOUTD_SRC      ("CLKOUT"),
        .CLKOUTD3_SRC     ("CLKOUT")
    ) u_pll (
        .CLKIN    (F_OSC),
        .CLKFB    (1'b0),
        .RESET    (1'b0),
        .RESET_P  (1'b0),
        .FBDSEL   (6'd0),
        .IDSEL    (6'd0),
        .ODSEL    (6'd0),
        .PSDA     (4'd0),
        .DUTYDA   (4'd0),
        .FDLY     (4'd0),
        .CLKOUT   (clk),
        .LOCK     (locked),
        .CLKOUTP  (),
        .CLKOUTD  (),
        .CLKOUTD3 ()
    );

    // =============================================================== board
    wire [7:0] d_in, d_out;
    wire       d_oe;
    wire [1:0] col;

    tia_board #(
        .OSC_MULT     (OSC_MULT),
        .AUDIO_STEREO (AUDIO_STEREO)
    ) u_board (
        .clk    (clk),
        .locked (locked),
        .a      ({F_A5, F_A4, F_A3, F_A2, F_A1, F_A0}),
        .cs_n   (F_CS_N),
        .rw     (F_RW),
        .d_in   (d_in),
        .d_out  (d_out),
        .d_oe   (d_oe),
        .phi0   (F_PHI0),
        .rdy    (F_RDY),
        .trig   ({F_I5, F_I4}),
        .csync  (F_CSYNC),
        .blk    (F_BLK),
        .lum    ({F_LUM2, F_LUM1, F_LUM0}),
        .col    (col),
        .aud0   (F_AU0),
        .aud1   (F_AU1)
    );

    // ============================================================ data bus
    IOBUF u_d0 (.IO (F_D0), .I (d_out[0]), .O (d_in[0]), .OEN (~d_oe));
    IOBUF u_d1 (.IO (F_D1), .I (d_out[1]), .O (d_in[1]), .OEN (~d_oe));
    IOBUF u_d2 (.IO (F_D2), .I (d_out[2]), .O (d_in[2]), .OEN (~d_oe));
    IOBUF u_d3 (.IO (F_D3), .I (d_out[3]), .O (d_in[3]), .OEN (~d_oe));
    IOBUF u_d4 (.IO (F_D4), .I (d_out[4]), .O (d_in[4]), .OEN (~d_oe));
    IOBUF u_d5 (.IO (F_D5), .I (d_out[5]), .O (d_in[5]), .OEN (~d_oe));
    IOBUF u_d6 (.IO (F_D6), .I (d_out[6]), .O (d_in[6]), .OEN (~d_oe));
    IOBUF u_d7 (.IO (F_D7), .I (d_out[7]), .O (d_in[7]), .OEN (~d_oe));

    // ============================================================== chroma
    // Both halves of every clock go out, doubling the phase resolution to
    // 2 * OSC_MULT steps per colour cycle.
    ODDR u_col (.D0 (col[0]), .D1 (col[1]), .TX (1'b0), .CLK (clk), .Q0 (F_COL), .Q1 ());

endmodule
