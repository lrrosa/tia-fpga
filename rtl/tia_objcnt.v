// tia_objcnt.v -- a player / missile / ball horizontal position counter.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The same 6-bit polynomial counter as the horizontal counter, but decoded
// for 40 counts (160 colour clocks, one per visible pixel). All five movable
// objects use this; only the START decodes they act on differ.
//
// The counter is clocked by MOTCK, which only runs while HBLANK is off, plus
// whatever extra pulses HMOVE stuffs in. That is why an object keeps its
// sub-count phase across the blanking interval and why HMOVE moves things.
//
// RESETS. A RESxx strobe resets the counter and its two-phase clock, but
// neither at once and not together. Fitted against traces of RESP0 landing on
// all four sub-count phases, in every NUSIZ mode, and during copies that were
// already on their way to the screen:
//
//  - the two-phase clock is put back to H@1 on the first colour clock after
//    the strobe;
//  - the counter itself clears on the fourth. That is Towers' "resetting the
//    counter takes 4 CLK", taken literally: leave it out and every object
//    sits eight half clocks left of where the die draws it, and a sweep of the
//    delay from 4 to 11 colour clocks has 4 best by a wide margin.
//
// Realigning the phase early matters for a START that was already decoded when
// the strobe arrived: it is clocked out on the new phase, which is how the die
// can draw the copy that was in flight a colour clock EARLIER than it would
// have appeared, rather than losing it. Towers describes the effect -- "the
// Start signal will either be lost or delayed up to 3 CLK depending on exact
// timing" -- without the mechanism.
//
// Known not to be right yet: a reset during HBLANK, when MOTCK is stopped and
// only the free-running colour clock advances the delays above. A double-size
// player reset there lands a few half clocks left of the die. See
// sim/README.md.

`include "tia_defs.vh"

module tia_objcnt (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       ce_free,       // colour clock, runs through HBLANK too
    input  wire       reset,         // RESP0/RESP1/RESM0/RESM1/RESBL strobe

    output reg  [5:0] q,
    output wire       p1,
    output wire       p2,
    output wire [1:0] ph,            // divider state
    output wire       dec_close,     // count 3
    output wire       dec_med,       // count 7
    output wire       dec_far,       // count 15
    output wire       dec_main,      // count 39, also wraps the counter
    output wire       reset_now      // the colour clock a strobe clears the counter
);

    wire [5:0] q_next = { ~(q[1] ^ q[0]), q[5:1] };

    reg [2:0] clear_wait;            // colour clocks until the counter clears
    reg       phase_wait;            // one colour clock until the phase resets

    wire clear_go = (clear_wait == 3'd1) & ce_free;
    wire phase_go = phase_wait & ce_free;

    assign reset_now = clear_go;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_wait <= 3'd0;
            phase_wait <= 1'b0;
        end else if (reset) begin
            clear_wait <= 3'd4;
            phase_wait <= 1'b1;
        end else if (ce_free) begin
            if (clear_wait != 3'd0) clear_wait <= clear_wait - 3'd1;
            phase_wait <= 1'b0;
        end
    end

    tia_phase #(.RESET_PHASE(2'd0)) u_phase (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .rst_phase (phase_go),
        .p1        (p1),
        .p2        (p2),
        .ph        (ph)
    );

    assign dec_close = (q == `TIA_OC_CLOSE);
    assign dec_med   = (q == `TIA_OC_MED);
    assign dec_far   = (q == `TIA_OC_FAR);
    assign dec_main  = (q == `TIA_OC_MAIN);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            q <= 6'b000000;
        else if (clear_go)
            q <= 6'b000000;
        else if (p2) begin
            if (dec_main || q == `TIA_LFSR_ERR)
                q <= 6'b000000;
            else
                q <= q_next;
        end
    end

endmodule
