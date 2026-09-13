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
// RESETS, as read off the netlist Sim2600 simulates (sim/probe_die.py and
// sim/netlist.py) rather than fitted:
//
//  - The two-phase clock is a ring of four half-clock stages stepped by
//    MOTCK; H@1 and H@2 are decodes of it, a colour clock wide and two
//    apart. The counter's stages load on H@1 and step on H@2, and the START
//    decodes go through a latch that follows them for all of H@1 and closes
//    as it ends -- `pa` here.
//
//  - A RESxx strobe holds the ring in H@1 for as long as it is high, and sets
//    a latch that the ring releases on the next H@2. That H@2 starts a pulse
//    one count long that forces every stage of the counter to zero, so the
//    counter clears on the first H@2 after the strobe and counts on from
//    there. Nothing else is reset.
//
//  - Because the ring is held in H@1, a START that was already decoded when
//    the strobe arrived is caught and clocked out on the new phase: the die
//    draws that copy rather than losing it. Towers saw the effect ("the Start
//    signal will either be lost or delayed") but not the mechanism.
//
//  - While HBLANK stops MOTCK the ring cannot step, so a reset in HBLANK sits
//    in H@1 until the first colour clock of the visible line, and the counter
//    clears on the second.
//
// ON THIS CORE'S CLOCK GRID the object clock enable lands a couple of half
// clocks after the die's ring steps, so the strobe reaches the ring one
// colour clock after the bus write: the colour clock that coincides with the
// write still counts, the next one is the one the strobe swallows. A strobe
// taken at the write itself, or two colour clocks after it, misplaces objects
// on every test cartridge.

`include "tia_defs.vh"

module tia_objcnt (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       ce_free,       // colour clock, runs through HBLANK too
    input  wire       reset,         // RESP0/RESP1/RESM0/RESM1/RESBL strobe, or the RESMP lock

    output reg  [5:0] q,
    output wire       p1,            // H@1 begins
    output wire       p2,            // H@2: the counter steps
    output wire       pa,            // H@1 ends: START decodes are latched here
    output wire [1:0] ph,            // divider state
    output wire       dec_close,     // count 3
    output wire       dec_med,       // count 7
    output wire       dec_far,       // count 15
    output wire       dec_main,      // count 39, also wraps the counter
    output wire       clear_now      // the H@2 that clears the counter
);

    wire [5:0] q_next = { ~(q[1] ^ q[0]), q[5:1] };

    // The strobe, kept until a colour clock takes it, then one colour clock
    // later as it reaches the ring. A level (the RESMP lock) passes straight
    // through, delayed the same.
    reg strobe, held;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            strobe <= 1'b0;
            held   <= 1'b0;
        end else begin
            if (reset)         strobe <= 1'b1;
            else if (ce_free)  strobe <= 1'b0;
            if (ce_free)       held   <= strobe;
        end
    end

    // The ring, as a divider: 0 is the clock that starts H@1, 1 the one that
    // ends it, 2 the one that starts H@2. Held, it waits at 1.
    reg  [1:0] div;
    wire       ce_ring = ce & ~held;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        div <= 2'd0;
        else if (held)     div <= 2'd1;
        else if (ce_ring)  div <= div + 2'd1;
    end

    assign ph = div;
    assign p1 = ce_ring & (div == 2'd0);
    assign pa = ce_ring & (div == 2'd1);
    assign p2 = ce_ring & (div == 2'd2);

    assign dec_close = (q == `TIA_OC_CLOSE);
    assign dec_med   = (q == `TIA_OC_MED);
    assign dec_far   = (q == `TIA_OC_FAR);
    assign dec_main  = (q == `TIA_OC_MAIN);

    // The reset latch, released by the ring's next H@2, and the clear pulse:
    // decided as H@1 ends, acted on at H@2. The wrap after count 39 and the
    // illegal all-ones state go through the same path.
    reg pending, clear_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            clear_l <= 1'b0;
        end else begin
            if (held)     pending <= 1'b1;
            else if (p2)  pending <= 1'b0;
            if (pa)       clear_l <= pending | dec_main | (q == `TIA_LFSR_ERR);
        end
    end

    assign clear_now = p2 & clear_l;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   q <= 6'b000000;
        else if (p2)  q <= clear_l ? 6'b000000 : q_next;
    end

endmodule
