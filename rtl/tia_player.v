// tia_player.v -- a player object: start decodes, scan counter, graphics.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The position counter (tia_objcnt) says when a copy starts; this block turns
// that into eight pixels of GRPn. From the notes:
//
//  - The graphics scan counter is a plain 3-bit binary ripple counter and is
//    never reset. Once started it always counts 0 to 7, and because it only
//    advances while HBLANK is off, a player that starts near the right edge
//    finishes drawing at the start of the next line. That is sprite wrapping.
//
//  - Player graphics take one extra colour clock to appear compared with any
//    other object, which is why the leftmost RESP0 position is pixel 1.
//
// And from the traces:
//
//  - Double- and quad-size players start ANOTHER colour clock later than
//    single-size ones, and their first pixel is as wide as the rest. Their
//    scan counter is clocked from the object's two-phase lines -- both of
//    them for 2x, H@1 alone for 4x -- and the extra colour clock is what puts
//    the start on H@1, so the first stretched pixel is not cut short.

module tia_player (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       p1,            // this object's H@1
    input  wire       p2,            // this object's H@2

    input  wire       dec_close,
    input  wire       dec_med,
    input  wire       dec_far,
    input  wire       dec_main,

    input  wire [2:0] nusiz,         // NUSIZn D2..D0
    input  wire       reflect,       // REFPn D3
    input  wire       vdel,          // VDELPn D0
    input  wire [7:0] grp_new,
    input  wire [7:0] grp_old,

    output wire       pixel,
    output wire [2:0] scan_pos,      // for RESMP
    output reg        fstob          // drawing a copy, not the main object
);

    wire copy_close = (nusiz == 3'b001) || (nusiz == 3'b011);
    wire copy_med   = (nusiz == 3'b011) || (nusiz == 3'b010) || (nusiz == 3'b110);
    wire copy_far   = (nusiz == 3'b100) || (nusiz == 3'b110);
    wire stretched  = (nusiz == 3'b101) || (nusiz == 3'b111);

    wire start_dec  = dec_main |
                      (dec_close & copy_close) |
                      (dec_med   & copy_med)   |
                      (dec_far   & copy_far);

    // The decode is clocked into a latch on H@1 and acts on the following
    // H@2: the 4 CLK delay common to every movable object. Players then take
    // one more colour clock to latch the START at the scan counter, and
    // stretched players one more again.
    //
    // start_q and start_q2 are levels one colour clock long; the scan counter
    // is started by a single-clock pulse at the far end of one of them. A
    // level would hold the counter at zero for two colour clocks and draw the
    // leftmost pixel twice.
    reg start_l, start_q, start_q2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_l  <= 1'b0;
            start_q  <= 1'b0;
            start_q2 <= 1'b0;
        end else begin
            if (p1) start_l  <= start_dec;
            if (ce) start_q  <= p2 & start_l;
            if (ce) start_q2 <= start_q;
        end
    end

    wire start_pulse = ce & (stretched ? start_q2 : start_q);

    // Which copy are we drawing? FSTOB is set by a close/medium/far start and
    // cleared when the counter wraps, so it marks "this is not the main copy".
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fstob <= 1'b0;
        else if (p2 && dec_main)
            fstob <= 1'b0;
        else if (p1 && start_dec && !dec_main)
            fstob <= 1'b1;
    end

    // Stretch: 4x lets one clock through every four, 2x one every two.
    wire scan_ce = (nusiz == 3'b111) ? p1 :
                   (nusiz == 3'b101) ? (p1 | p2) : ce;

    reg [2:0] scan;
    reg       scan_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan    <= 3'd0;
            scan_en <= 1'b0;
        end else if (start_pulse) begin
            scan    <= 3'd0;
            scan_en <= 1'b1;
        end else if (scan_ce && scan_en) begin
            scan <= scan + 3'd1;
            if (scan == 3'd7) scan_en <= 1'b0;
        end
    end

    wire [7:0] grp       = vdel ? grp_old : grp_new;
    wire [2:0] bit_index = reflect ? scan : ~scan;

    assign pixel    = scan_en & grp[bit_index];
    assign scan_pos = scan;

endmodule
