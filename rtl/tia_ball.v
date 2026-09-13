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
// "Immediately" means on the H@2 that clears the counter (see tia_objcnt.v),
// not at the strobe itself. On the die the clear pulse also runs on through a
// second latch stage into the ball's START logic; a START on the clearing H@2
// is what matches the test cartridges.
//
// Not yet right: four RESBL strobes nine colour clocks apart with an 8-pixel
// ball. The die draws one unbroken run; here there is a one-colour-clock gap
// between each copy. See sim/README.md.

module tia_ball (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       p1,
    input  wire       p2,

    input  wire       dec_main,      // count 39: wrap and start
    input  wire       clear_now,     // the H@2 clearing the counter: also a START

    input  wire [1:0] size,          // CTRLPF D5..D4
    input  wire       enabl_new,
    input  wire       enabl_old,
    input  wire       vdel,          // VDELBL D0

    output wire       pixel
);

    reg start_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_l <= 1'b0;
        else if (p1) start_l <= dec_main;
    end

    wire start = (p2 & start_l) | clear_now;
    wire active;

    tia_enclock u_width (
        .clk    (clk),
        .rst_n  (rst_n),
        .ce     (ce),
        .start  (start),
        .size   (size),
        .active (active)
    );

    assign pixel = active & (vdel ? enabl_old : enabl_new);

endmodule
