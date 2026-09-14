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
//    single-size ones, and their first pixel is as wide as the rest. In
//    steady state their scan counter steps with the object's two-phase lines
//    -- both of them for 2x, H@1 alone for 4x -- and the extra colour clock
//    is what keeps the first stretched pixel from being cut short.
//
// And from the netlist:
//
//  - The die's scan counter is clocked by MOTCK, and for stretched players a
//    gate holds it back. The gate is the object's two-phase state -- blocking
//    in neither phase for 2x, outside H@2 for 4x -- caught by a pair of
//    latches on MOTCK, so a MOTCK edge steps the counter only if the object
//    was unblocked at the MOTCK before it. Through HBLANK, where MOTCK stops,
//    the pair keeps what it had.
//
//  - A RESPn strobe holds the object's two-phase clock in H@1 (tia_objcnt.v),
//    which opens a double-size player's gate and closes a quad-size one's.
//    Reset a stretched copy while it is being drawn and some of its pixels
//    come out short -- one with Sim2600's wiring of CLK2, three with the
//    console's, where the hold covers two MOTCKs.

module tia_player (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       p1,            // this object's H@1
    input  wire       p2,            // this object's H@2
    input  wire       pa,            // the end of this object's H@1
    input  wire       motck,         // MOTCK alone, without HMOVE's pulses
    input  wire       ce_any,        // either colour clock edge
    input  wire       phase_a,       // this object's H@1, or held there by a reset
    input  wire       phase_b,       // this object's H@2

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

    // The decode goes through a latch that follows it for all of H@1 and
    // closes as H@1 ends, and acts on the following H@2: the 4 CLK delay
    // common to every movable object. Players then take one more colour clock
    // to latch the START at the scan counter, and stretched players one more
    // again.
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
            if (pa) start_l  <= start_dec;
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
        else if (pa && start_dec && !dec_main)
            fstob <= 1'b1;
    end

    // The size gate. The size is taken two half clocks late, which puts a
    // NUSIZ write on the same grid as the object's two-phase clock here.
    reg [2:0] size_1, size_2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            size_1 <= 3'd0;
            size_2 <= 3'd0;
        end else if (ce_any) begin
            size_1 <= nusiz;
            size_2 <= size_1;
        end
    end

    wire block = (size_2 == 3'b111) ? ~phase_b :
                 (size_2 == 3'b101) ? ~(phase_a | phase_b) : 1'b0;

    reg gate;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      gate <= 1'b0;
        else if (motck)  gate <= block;
    end

    wire scan_ce = ce & ~gate;

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
