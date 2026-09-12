// tia_phase.v -- the two-phase clock generator that sits beside every
// polynomial counter in the TIA.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// From the TIA Hardware Notes: "Beside each counter there is a two-phase
// clock generator.  This takes the incoming 3.58 MHz colour clock (CLK) and
// divides by 4 using a couple of flip-flops.  Two AND gates are then used to
// generate two independent clock signals thusly:
//
//   __          __          __
//  _| |_________| |_________| |_________  PHASE-1 (H@1)
//         __          __          __
//  _______| |_________| |_________| |___  PHASE-2 (H@2)
//
// Each phase is one colour clock wide; H@2 trails H@1 by two colour clocks.
// The counter shifts on H@2; H@1 moves data through the supporting logic.
//
// `ce' is the colour-clock event this generator counts.  For the horizontal
// counter that is every rising CLK edge; for the object counters it is MOTCK,
// which only runs while HBLANK is off (plus HMOVE's stuffed pulses).
//
// `rst_phase' reloads the divider with RESET_PHASE. The object counters use
// the default 0, which puts them back at the H@1 rising edge -- that is what
// RESPn/RESMn/RESBL do, and it is the reason re-triggering at 18, 33, 66 or
// 162 cycles behaves oddly: the start decode gets cut short. The horizontal
// counter uses 3 instead, meaning "an H@2 just happened here", which is what
// RSYNC leaves behind.

module tia_phase #(
    parameter [1:0] RESET_PHASE = 2'd0
) (
    input  wire       clk,          // FPGA clock, oversamples the colour clock
    input  wire       rst_n,
    input  wire       ce,           // one pulse per colour clock of this domain
    input  wire       rst_phase,    // reload the divider with RESET_PHASE
    output wire       p1,           // H@1, one ce wide
    output wire       p2,           // H@2, one ce wide
    output wire [1:0] ph            // raw divider state, for the ball/missile
);                                  // width logic, which borrows these lines

    reg [1:0] div;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          div <= RESET_PHASE;
        else if (rst_phase)  div <= RESET_PHASE;
        else if (ce)         div <= div + 2'd1;
    end

    assign ph = div;
    assign p1 = ce & (div == 2'd0);
    assign p2 = ce & (div == 2'd2);

endmodule
