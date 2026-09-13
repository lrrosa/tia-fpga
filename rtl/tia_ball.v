// tia_ball.v -- the ball object.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The ball has a whole polynomial counter to itself and, aside from width, no
// special effects -- except for one detail Towers singles out: unlike every
// other object, RESBL does generate a START. The ball can therefore be
// retriggered as many times as you like across a scanline and it starts
// drawing each time, which is why it gets used for cutting holes in things
// and for background detail.
//
// On the die the ball's START is its counter's clear pulse -- one count long,
// from the H@2 that clears the counter to the next, whether the clear came
// from RESBL or from the wrap after count 39 -- and a second latch stage holds
// a copy of it for the count after. Width picks from the two, which is the
// "AND -> OR -> AND -> OR -> out arrangement" Towers describes:
//
//   CTRLPF D5 D4 = 00  the first colour clock of the START count  -> 1 pixel
//                  01  its first two colour clocks                -> 2 pixels
//                  10  the START count                            -> 4 pixels
//                  11  the START count and the count after it     -> 8 pixels
//
// Strobe RESBL again while the second count is running and the two chain into
// one unbroken run, which is what the die draws. A width counter reloaded on
// every START, which is otherwise indistinguishable, leaves a gap there.

module tia_ball (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       p2,
    input  wire [1:0] ph,            // counter divider: 3 for the colour clock after H@2
    input  wire       clear_now,     // the H@2 that clears the counter

    input  wire [1:0] size,          // CTRLPF D5..D4
    input  wire       enabl_new,
    input  wire       enabl_old,
    input  wire       vdel,          // VDELBL D0

    output wire       pixel
);

    reg first, second;               // the START count, and the count after it
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first  <= 1'b0;
            second <= 1'b0;
        end else if (p2) begin
            first  <= clear_now;
            second <= first;
        end
    end

    reg active;
    always @(*) begin
        case (size)
        2'b00:   active = first & (ph == 2'd3);
        2'b01:   active = first & ((ph == 2'd3) | (ph == 2'd0));
        2'b10:   active = first;
        default: active = first | second;
        endcase
    end

    assign pixel = active & (vdel ? enabl_old : enabl_new);

endmodule
