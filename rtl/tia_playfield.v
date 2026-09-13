// tia_playfield.v -- the 20-bit playfield and its position in the line.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The playfield is the one graphics object that is not movable: its position
// comes straight from the horizontal counter's two-phase clock, so HMOVE has
// no effect on it. That is the whole reason the HMOVE comb is visible -- the
// extended HBLANK hides the first eight playfield pixels while everything
// else slides right.
//
// Bit order is the famous mess: PF0 is drawn from bit 4 up to bit 7, PF1 from
// bit 7 down to bit 0, PF2 from bit 0 up to bit 7. It looks arbitrary until
// you remember the register is a shift chain on the die.
//
// WHEN A WRITE SHOWS. Each playfield bit is read out of PF0-PF2 on H@1 and
// put on the screen on the following H@2. So a mid-line write does not change
// the bit being drawn: it appears at the next bit boundary if it lands before
// that boundary's H@1, and at the one after if it lands later. Traced writes
// into PF1 at 5 and 7 half clocks before a boundary show at that boundary;
// writes 1 and 3 half clocks before one wait for the next.

module tia_playfield (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       p1,            // H@1 of the horizontal counter
    input  wire       p2,            // H@2 of the horizontal counter
    input  wire       rhb,           // pulse: HBLANK released, restart the playfield
    input  wire       cntd,          // pulse: centre, start the second half
    input  wire       rhb_next,      // level: the coming H@2 releases HBLANK
    input  wire       cnt_next,      // level: the coming H@2 is the centre
    input  wire       hblank,

    input  wire [7:0] pf0,
    input  wire [7:0] pf1,
    input  wire [7:0] pf2,
    input  wire       reflect,       // CTRLPF D0

    output wire       pixel,
    output reg        right_half
);

    // Index 0 is the leftmost playfield bit of a half-line.
    wire [19:0] pfv = { pf2[7], pf2[6], pf2[5], pf2[4], pf2[3], pf2[2], pf2[1], pf2[0],
                        pf1[0], pf1[1], pf1[2], pf1[3], pf1[4], pf1[5], pf1[6], pf1[7],
                        pf0[7], pf0[6], pf0[5], pf0[4] };

    reg [4:0] idx;
    reg       down;                  // counting backwards through a reflection

    // The bit the coming H@2 will put on the screen.
    wire [4:0] idx_next = rhb_next ? 5'd0 :
                          cnt_next ? (reflect ? 5'd19 : 5'd0) :
                          hblank   ? idx :
                          down     ? idx - 5'd1 : idx + 5'd1;
    wire [4:0] idx_read = (idx_next > 5'd19) ? 5'd0 : idx_next;

    reg bit_read, bit_shown;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_read  <= 1'b0;
            bit_shown <= 1'b0;
        end else begin
            if (p1) bit_read  <= pfv[idx_read];
            if (p2) bit_shown <= bit_read;
        end
    end

    assign pixel = bit_shown & ~hblank;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx        <= 5'd0;
            down       <= 1'b0;
            right_half <= 1'b0;
        end else if (rhb) begin
            idx        <= 5'd0;
            down       <= 1'b0;
            right_half <= 1'b0;
        end else if (cntd) begin
            idx        <= reflect ? 5'd19 : 5'd0;
            down       <= reflect;
            right_half <= 1'b1;
        end else if (p2 && !hblank) begin
            if (down) idx <= idx - 5'd1;
            else      idx <= idx + 5'd1;
        end
    end

endmodule
