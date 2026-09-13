// tia_missile.v -- a missile object.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Missiles use exactly the same counter decodes as the players, and the same
// NUSIZ copy flags, but without the extra colour clock players spend latching
// their START. Width comes from NUSIZ D5..D4 through the enclockifier.
//
// RESMP locks the missile to the middle of its player: while the bit is set
// the missile is not drawn, and its counter is held reset whenever the
// player's scan counter reaches %100 during the main copy.

module tia_missile (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce,            // MOTCK or an HMOVE stuffed pulse
    input  wire       p1,
    input  wire       p2,
    input  wire       pa,            // the end of H@1, when START decodes are latched

    input  wire       dec_close,
    input  wire       dec_med,
    input  wire       dec_far,
    input  wire       dec_main,

    input  wire [2:0] nusiz,         // NUSIZn D2..D0, copy selection
    input  wire [1:0] size,          // NUSIZn D5..D4, width
    input  wire       enam,          // ENAMn D1
    input  wire       resmp,         // RESMPn D1

    output wire       pixel
);

    wire copy_close = (nusiz == 3'b001) || (nusiz == 3'b011);
    wire copy_med   = (nusiz == 3'b011) || (nusiz == 3'b010) || (nusiz == 3'b110);
    wire copy_far   = (nusiz == 3'b100) || (nusiz == 3'b110);

    wire start_dec  = dec_main |
                      (dec_close & copy_close) |
                      (dec_med   & copy_med)   |
                      (dec_far   & copy_far);

    reg start_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_l <= 1'b0;
        else if (pa) start_l <= start_dec;
    end

    wire start = p2 & start_l;
    wire active;

    tia_enclock u_width (
        .clk    (clk),
        .rst_n  (rst_n),
        .ce     (ce),
        .start  (start),
        .size   (size),
        .active (active)
    );

    assign pixel = active & enam & ~resmp;

endmodule
