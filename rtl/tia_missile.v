// tia_missile.v -- a missile object.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Missiles use exactly the same counter decodes as the players, and the same
// NUSIZ copy flags, but without the extra colour clock players spend latching
// their START. Width comes from NUSIZ D5..D4 exactly as the ball's does (see
// tia_ball.v): the first one or two colour clocks of the START count, the
// START count, or the START count and a copy of it one count later.
//
// RESMP locks the missile to the middle of its player: while the bit is set
// the missile is not drawn, and its counter is held reset whenever the
// player's main copy reaches scan position 1. The lock itself is in tia.v.

module tia_missile (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       p2,
    input  wire       pa,            // the end of H@1, when START decodes are latched
    input  wire [1:0] ph,            // counter divider: 3 for the colour clock after H@2

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

    reg start_l;                     // the decode, as H@1 ends
    reg first, second;               // the START count, and the count after it
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_l <= 1'b0;
            first   <= 1'b0;
            second  <= 1'b0;
        end else begin
            if (pa) start_l <= start_dec;
            if (p2) begin
                first  <= start_l;
                second <= first;
            end
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

    assign pixel = active & enam & ~resmp;

endmodule
