// tia_enclock.v -- the ball / missile width "enclockifier".
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Towers describes the original as "an AND -> OR -> AND -> OR -> out
// arrangement, with a hanger-on AND gate", combining clock lines of different
// widths borrowed from the object's two-phase generator:
//
//   D5 D4 = 00  one phase line, active 1 in 4 CLK        -> 1 pixel
//   D5 D4 = 01  a line active 2 in 4 CLK                 -> 2 pixels
//   D5 D4 = 10  the START signal itself, 4 CLK wide      -> 4 pixels
//   D5 D4 = 11  START plus a delayed copy of START       -> 8 pixels
//
// Counting colour clocks from the START gives the same waveform and is a
// great deal easier to read. A new START while one is in flight reloads the
// counter, which is what makes RESBL retriggerable across a scanline.

module tia_enclock (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       start,         // one ce wide
    input  wire [1:0] size,          // D5 D4 of NUSIZ (missile) or CTRLPF (ball)
    output wire       active
);

    reg [3:0] count;

    wire [3:0] width = (size == 2'b00) ? 4'd1 :
                       (size == 2'b01) ? 4'd2 :
                       (size == 2'b10) ? 4'd4 : 4'd8;

    assign active = (count != 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= 4'd0;
        else if (start)
            count <= width;
        else if (ce && count != 4'd0)
            count <= count - 4'd1;
    end

endmodule
