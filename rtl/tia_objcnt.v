// tia_objcnt.v -- a player / missile / ball horizontal position counter.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The same 6-bit polynomial counter as the horizontal counter, but decoded
// for 40 counts (160 colour clocks, one per visible pixel).  All five movable
// objects use this; only the START decodes they act on differ.
//
// The counter is clocked by MOTCK, which only runs while HBLANK is off, plus
// whatever extra pulses HMOVE stuffs in.  That is why an object keeps its
// sub-count phase across the blanking interval and why HMOVE moves things.
//
// A RESxx strobe resets both the counter and its two-phase clock, but not at
// once: Towers breaks the delay from a RESP0 to the first player pixel into
// "resetting the counter takes 4 CLK, decoding the 'start drawing' signal
// takes 4 CLK, latching the 'start' takes a further 1 CLK giving a total 9 CLK
// delay". The last two live in tia_player; the first four are here, and
// leaving them out puts every object eight half clocks to the left of where
// the die draws it.
//
// The delay is counted on the free-running colour clock, not on MOTCK, so a
// RESxx during HBLANK still takes effect -- the counter is reset but does not
// start counting again until the picture resumes.
//
// Resetting the phase mid-decode is what delays or swallows a START signal
// when the object is re-triggered 18, 33, 66 or 162 CLK after the previous
// reset.

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
    output wire [1:0] ph,            // divider state, for the width logic
    output wire       dec_close,     // count 3
    output wire       dec_med,       // count 7
    output wire       dec_far,       // count 15
    output wire       dec_main       // count 39, also wraps the counter
);

    wire [5:0] q_next = { ~(q[1] ^ q[0]), q[5:1] };

    // Four colour clocks from the strobe to the counter actually clearing.
    reg [2:0] rs_wait;
    wire      reset_go = (rs_wait == 3'd1) & ce_free;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          rs_wait <= 3'd0;
        else if (reset)                      rs_wait <= 3'd4;
        else if (rs_wait != 3'd0 && ce_free) rs_wait <= rs_wait - 3'd1;
    end

    tia_phase u_phase (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .rst_phase (reset_go),
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
        else if (reset_go)
            q <= 6'b000000;
        else if (p2) begin
            if (dec_main || q == `TIA_LFSR_ERR)
                q <= 6'b000000;
            else
                q <= q_next;
        end
    end

endmodule
