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
// ORDER. Towers puts the first compare 15 CLK after the strobe and the first
// decrement at 17, and that order is not negotiable: if the counter is
// allowed to step down before its first compare -- which depends only on
// where in the two-phase cycle STA HMOVE happens to land -- an HMxx of -8
// never matches, and the object gets sixteen pulses instead of none. The
// sixteen-value trace shows exactly that until the first decrement waits for
// the first compare.
//
// TIMING, read off the netlist Sim2600 simulates. The motion counter, the
// comparators and the pulses run 12 half clocks -- a count and a half --
// behind the horizontal counter's own H@1 and H@2. An HMOVE at the start of a
// line stuffs its pulses 33, 41, ... 145 half clocks into it. Everything that
// decides a pulse happens on that later grid, and the HMxx registers are read
// as they stand at the time.
//
// That is what Cosmic Ark relies on. Write an HMxx value such that no
// remaining counter state satisfies the comparator, and the latch is never
// cleared: the counter stops at zero rather than wrapping, so the object keeps
// getting a pulse every 4 CLK until the next HMOVE -- the starfield. Whether a
// given write makes it depends on when the comparator looks. The die catches
// the compare in a latch on the motion clock and passes it on half a count
// later, so here the comparators see HMxx as it stood a few half clocks before
// the pulse. Cosmic Ark's HMM0 write lands 139 half clocks into the line with
// Sim2600's wiring of CLK2, in time to stop the missile; with the console's it
// lands at 142, too late, and the missile keeps moving.
//
// MERGED PULSES. A pulse counts while HBLANK is on, through the HMOVE latch's
// extension to LRHB as well, because only then is MOTCK stopped. The motion
// clock itself never stops, and each object's clock on the die is MOTCK OR
// (its latch AND the motion clock), so past HBLANK a pulse lands across a low
// half of MOTCK and fills it in. That gains no count -- an HMOVE in the
// visible line moves nothing -- but Sim2600 settles MOTCK's fall before the
// motion clock's rise, and in that instant the object's latches step: half a
// colour clock early, so the MOTCK edge that follows finds nothing to do. The
// pads latch objects on exactly that half clock and show the object one step
// ahead there. A missile's only pixel vanishes, or a wider one loses or gains
// a pixel, which is part of what Cosmic Ark's moving missile looks like.
// Whether a real chip glitches the same way turns on which of the two clocks
// wins; this core follows the simulated die.
//
// The HBLANK extension is not delayed. It follows the strobe, and is cleared
// when the horizontal counter wraps, so an HMOVE late in the line stuffs
// clocks without producing a comb.

module tia_hmove (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce_edge,       // either colour clock edge, one per half clock
    input  wire        p1,            // H@1 of the horizontal counter
    input  wire        p2,            // H@2 of the horizontal counter
    input  wire        shb,           // horizontal counter wrapped
    input  wire        hblank_next,   // HBLANK as it stands after this half clock

    input  wire        hmove,         // HMOVE strobe

    input  wire [3:0]  hmp0,          // HMxx as written, D7..D4
    input  wire [3:0]  hmp1,
    input  wire [3:0]  hmm0,
    input  wire [3:0]  hmm1,
    input  wire [3:0]  hmbl,

    output reg         hmove_latch,   // extend HBLANK to the LRHB decode
    output wire [4:0]  stuff,         // P0 P1 M0 M1 BL: pulses that count
    output wire [4:0]  merge          // pulses MOTCK absorbs, as the pads see them
);

    // ------------------------------------------------ the later motion grid
    localparam DELAY = 12;            // half clocks

    reg [DELAY-1:0] p1_sr, p2_sr, hmove_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_sr    <= {DELAY{1'b0}};
            p2_sr    <= {DELAY{1'b0}};
            hmove_sr <= {DELAY{1'b0}};
        end else if (ce_edge) begin
            p1_sr    <= { p1_sr[DELAY-2:0],    p1 };
            p2_sr    <= { p2_sr[DELAY-2:0],    p2 };
            hmove_sr <= { hmove_sr[DELAY-2:0], hmove };
        end
    end

    wire m_p1    = ce_edge & p1_sr[DELAY-1];
    wire m_p2    = ce_edge & p2_sr[DELAY-1];
    wire m_hmove = ce_edge & hmove_sr[DELAY-1];

    // ----------------------------------------------- counter and comparators
    reg [3:0] cnt;
    reg [4:0] more;                   // "this object still needs to move"
    reg       armed;                  // HMOVE strobed, first compare to come

    // The stored value with D7 inverted, then bit-inverted again for the
    // comparator: stop when cnt equals this.
    function [3:0] stop_at;
        input [3:0] hm;
        begin
            stop_at = { hm[3], ~hm[2:0] };
        end
    endfunction

    // HMxx as the comparators see it, two half clocks behind: a write counts
    // at a compare only if it came three or more half clocks before it.
    reg [39:0] hm_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        hm_sr <= 40'd0;
        else if (ce_edge)  hm_sr <= {hm_sr[19:0], hmp0, hmp1, hmm0, hmm1, hmbl};
    end
    wire [19:0] hm_seen = hm_sr[39:20];

    wire [4:0] hit = { (cnt == stop_at(hm_seen[19:16])),
                       (cnt == stop_at(hm_seen[15:12])),
                       (cnt == stop_at(hm_seen[11:8])),
                       (cnt == stop_at(hm_seen[7:4])),
                       (cnt == stop_at(hm_seen[3:0])) };

    // The compare is sampled before the pulse goes out, so an object whose
    // value is -8 (a count of zero) never receives one.
    wire [4:0] still = more & ~hit;

    // m_p1 falls on an H@2 of the horizontal counter, where HBLANK changes,
    // so HBLANK as it stands after this half clock decides the whole pulse:
    // stuffed while it is on, merged into MOTCK once it is off.
    assign stuff = {5{m_p1 &  hblank_next}} & still;
    wire [4:0] merge_now = {5{m_p1 & ~hblank_next}} & still;

    // The pads take a merged pulse four half clocks after this grid does.
    reg [19:0] merge_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        merge_sr <= 20'd0;
        else if (ce_edge)  merge_sr <= {merge_sr[14:0], merge_now};
    end
    assign merge = {5{ce_edge}} & merge_sr[19:15];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hmove_latch <= 1'b0;
            cnt         <= 4'd15;
            more        <= 5'd0;
            armed       <= 1'b0;
        end else begin
            // Only the HBLANK extension is cleared at the wrap. The "more
            // movement" latches are deliberately left alone.
            if (hmove)     hmove_latch <= 1'b1;
            else if (shb)  hmove_latch <= 1'b0;

            if (m_hmove) begin
                cnt   <= 4'd15;
                more  <= 5'b11111;
                armed <= 1'b1;
            end

            if (m_p1 && !m_hmove) begin
                more  <= still;
                armed <= 1'b0;
            end

            if (m_p2 && !m_hmove && !armed && cnt != 4'd0)
                cnt <= cnt - 4'd1;
        end
    end

endmodule
