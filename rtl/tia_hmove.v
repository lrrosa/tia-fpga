// tia_hmove.v -- horizontal motion: the comb, the clock stuffing, and the
// reason Cosmic Ark has a starfield.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// HMOVE does two separate things. It sets a latch that delays the end of
// HBLANK by 8 colour clocks (the horizontal counter uses the LRHB decode
// instead of RHB), which shifts every movable object 8 pixels right and hides
// the first 8 playfield pixels -- the comb. And it stuffs up to 15 extra
// clock pulses into the object position counters, each worth one pixel left.
// Net motion is therefore the signed value the programmer wrote.
//
// The hardware is a 4-bit ripple counter starting at 15 and counting down one
// step every 4 CLK, wired in parallel to a comparator inside every HMxx
// latch. Towers: "When the comparator for a given object detects that none of
// the 4 bits match the bits in the counter state, it clears this latch (a
// clever exercise in reverse logic!)". So an object stops receiving pulses
// when every bit of the counter differs from its stored value, i.e. when
// counter == ~hm_count. D7 is wired backwards in the comparator, which is
// what turns the programmer's +7..-8 into a plain 0..15 count.
//
// Two consequences fall straight out of this and neither is a special case:
//
//  - Write an HMxx value during the HMOVE such that no remaining counter
//    state ever satisfies the comparator and the latch is never cleared. The
//    object then keeps getting a pulse every 4 CLK, through the visible part
//    of the line and on into following lines, until the next HMOVE. That is
//    the Cosmic Ark starfield.
//
//  - The HBLANK-extending latch is cleared when the horizontal counter wraps,
//    so an HMOVE late in the line stuffs clocks without producing a comb.

module tia_hmove (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        p1,            // H@1 of the horizontal counter
    input  wire        p2,            // H@2 of the horizontal counter
    input  wire        shb,           // horizontal counter wrapped

    input  wire        hmove,         // HMOVE strobe

    input  wire [3:0]  hmp0,          // HMxx as written, D7..D4
    input  wire [3:0]  hmp1,
    input  wire [3:0]  hmm0,
    input  wire [3:0]  hmm1,
    input  wire [3:0]  hmbl,

    output reg         hmove_latch,   // extend HBLANK to the LRHB decode
    output wire [4:0]  stuff          // P0 P1 M0 M1 BL, one colour clock wide
);

    reg [3:0] cnt;
    reg [4:0] more;                   // "this object still needs to move"

    // The stored value with D7 inverted, then bit-inverted again for the
    // comparator: stop when cnt equals this.
    function [3:0] stop_at;
        input [3:0] hm;
        begin
            stop_at = { hm[3], ~hm[2:0] };
        end
    endfunction

    wire [4:0] hit = { (cnt == stop_at(hmp0)),
                       (cnt == stop_at(hmp1)),
                       (cnt == stop_at(hmm0)),
                       (cnt == stop_at(hmm1)),
                       (cnt == stop_at(hmbl)) };

    // The compare is sampled before the pulse goes out, so an object whose
    // value is -8 (a count of zero) never receives one.
    wire [4:0] still = more & ~hit;

    assign stuff = {5{p1}} & still;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hmove_latch <= 1'b0;
            cnt         <= 4'd15;
            more        <= 5'd0;
        end else begin
            if (hmove) begin
                hmove_latch <= 1'b1;
                cnt         <= 4'd15;
                more        <= 5'b11111;
            end else if (shb) begin
                // Only the HBLANK extension is cleared here. The "more
                // movement" latches are deliberately left alone.
                hmove_latch <= 1'b0;
            end

            if (p1 && !hmove)
                more <= still;

            if (p2 && !hmove)
                cnt <= cnt - 4'd1;
        end
    end

endmodule
