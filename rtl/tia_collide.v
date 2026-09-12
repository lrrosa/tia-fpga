// tia_collide.v -- the fifteen collision latches.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Every pair of the six objects that can overlap has a latch, set on any
// colour clock where both are being drawn in the visible part of the line and
// cleared only by CXCLR. Sixteen combinations minus BL-BL leaves fifteen;
// the sixteenth read bit (CXBLPF D6) is unused and reads back as zero.

module tia_collide (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,        // visible part of the line
    input  wire        cxclr,

    input  wire        p0,
    input  wire        p1,
    input  wire        m0,
    input  wire        m1,
    input  wire        bl,
    input  wire        pf,

    output reg  [14:0] cx
);

    // Bit order chosen to make the read multiplexer in tia.v obvious.
    localparam M0P1 = 0,  M0P0 = 1,
               M1P0 = 2,  M1P1 = 3,
               P0PF = 4,  P0BL = 5,
               P1PF = 6,  P1BL = 7,
               M0PF = 8,  M0BL = 9,
               M1PF = 10, M1BL = 11,
               BLPF = 12, P0P1 = 13,
               M0M1 = 14;

    wire [14:0] hit;

    assign hit[M0P1] = m0 & p1;
    assign hit[M0P0] = m0 & p0;
    assign hit[M1P0] = m1 & p0;
    assign hit[M1P1] = m1 & p1;
    assign hit[P0PF] = p0 & pf;
    assign hit[P0BL] = p0 & bl;
    assign hit[P1PF] = p1 & pf;
    assign hit[P1BL] = p1 & bl;
    assign hit[M0PF] = m0 & pf;
    assign hit[M0BL] = m0 & bl;
    assign hit[M1PF] = m1 & pf;
    assign hit[M1BL] = m1 & bl;
    assign hit[BLPF] = bl & pf;
    assign hit[P0P1] = p0 & p1;
    assign hit[M0M1] = m0 & m1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     cx <= 15'd0;
        else if (cxclr) cx <= 15'd0;
        else if (enable) cx <= cx | hit;
    end

endmodule
