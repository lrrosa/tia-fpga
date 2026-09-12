// tia_hcount.v -- the horizontal sync counter and everything it decodes.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// A 6-bit polynomial counter running at CLK/4. It steps through 57 states per
// scanline (57 * 4 = 228 colour clocks) and its decode matrix produces every
// horizontal timing signal the TIA has.
//
// The counter changes state on the rising edge of H@2, so H@2 marks the start
// of each count. A decode is clocked into its latch over the following
// H@1 - H@2 cycle, which is the "delayed 4 CLK" the notes keep mentioning:
// here that falls out of updating the latches on the same H@2 that advances
// the counter, one state after the decode went true.
//
// WHICH EDGE OF CLK. Measured against Sim2600: the die's HBLANK latch changes
// on the FALLING edge of the colour clock, and its sync latch on the RISING
// edge, three half clocks earlier. Both are the same "delayed 4 CLK" in
// Towers' table, which is true to within a count but not to within a colour
// clock. So the counter here is clocked by ce_fall and the sync latch by
// ce_rise, one and a half colour clocks ahead of H@2.
//
// The numbers that pin this down, straight out of a trace: HBLANK rises on
// records where clk0 is low, the sync pulse rises on records where clk0 is
// high, and sync rise is always exactly 37 half clocks after HBLANK rise --
// 40 for five counter states, minus three.

`include "tia_defs.vh"

module tia_hcount (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ce_rise,        // colour clock rising edge
    input  wire       ce_fall,        // colour clock falling edge

    input  wire       rsync,          // RSYNC strobe
    input  wire       hmove_latch,    // HMOVE seen this line: use LRHB not RHB

    output reg  [5:0] q,              // counter state, Towers' notation
    output wire       p1,             // H@1
    output wire       p2,             // H@2
    output reg        hsync,
    output reg        hblank,
    output reg        cburst,
    output wire       shb,            // pulse: start of HBLANK / line reset
    output wire       shb_early,      // one colour clock before shb
    output wire       rhb,            // pulse: HBLANK released this H@2
    output wire       cntd,           // pulse: centre, second half of the PF
    output wire       aud_ck          // 2 pulses per line, 114 CLK apart
);

    // The LFSR: shift right, bit 5 fed by XNOR of the two bits falling off.
    wire [5:0] q_next = { ~(q[1] ^ q[0]), q[5:1] };

    // RSYNC. Towers: "A full H@1-H@2 cycle after RSYNC is strobed, the HSync
    // counter is also reset to 000000 and HBlank is turned on. This one
    // requires more investigation."
    //
    // Here is the investigation, from a trace of Donkey Kong's two RSYNCs: the
    // strobe lands at half clock N, and the counter restarts at the first
    // FALLING colour clock edge at or after N+8 -- four colour clocks later,
    // rounded up to the counter's own edge. Both RSYNCs in the trace stretch
    // their scanline from 456 to 514 half clocks, and both leave the counter
    // grid shifted by two colour clocks, which is what pins the rule down.
    //
    // The restart is also a line start: HBLANK comes on, the HMOVE latch is
    // cleared and the CPU clock divider reloads, exactly as at SHB.
    reg [3:0] rs_wait;
    reg       rs_armed;
    wire      ce_any   = ce_rise | ce_fall;
    wire      rsync_go = rs_armed & ce_fall;

    wire [1:0] ph;

    // The counter itself runs on the falling edge of the colour clock; MOTCK,
    // which drives every movable object, is the inverted clock and therefore
    // runs on the rising edge.
    tia_phase #(.RESET_PHASE(2'd3)) u_phase (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce_fall),
        .rst_phase (rsync_go),
        .p1        (p1),
        .p2        (p2),
        .ph        (ph)
    );

    wire at_shb  = (q == `TIA_HC_SHB);
    wire at_rhb  = (q == `TIA_HC_RHB)  & ~hmove_latch;
    wire at_lrhb = (q == `TIA_HC_LRHB) &  hmove_latch;

    // Three half clocks before H@2, on the opposite edge of the colour clock.
    wire sync_ce = ce_rise & (ph == 2'd1);
    // Two half clocks before H@2. WSYNC releases RDY here, which the die does
    // one colour clock before HBLANK starts rather than with it.
    wire early_ce = ce_fall & (ph == 2'd1);

    assign shb       = (p2 & at_shb) | rsync_go;
    assign shb_early = early_ce & at_shb;
    assign rhb       = p2 & (at_rhb | at_lrhb);
    assign cntd      = p2 & (q == `TIA_HC_CNT);
    assign aud_ck    = (p2 & at_shb) | (p1 & (q == `TIA_HC_AUD));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q        <= 6'b000000;
            hsync    <= 1'b0;
            hblank   <= 1'b1;
            cburst   <= 1'b0;
            rs_wait  <= 4'd0;
            rs_armed <= 1'b0;
        end else begin
            if (rsync) begin
                rs_wait  <= 4'd8;
                rs_armed <= 1'b0;
            end else if (rs_wait != 4'd0 && ce_any) begin
                rs_wait <= rs_wait - 4'd1;
                if (rs_wait == 4'd1) rs_armed <= 1'b1;
            end else if (rsync_go) begin
                rs_armed <= 1'b0;
            end

            if (rsync_go) begin
                q      <= 6'b000000;
                hblank <= 1'b1;
            end else if (p2) begin
                if (at_shb || q == `TIA_LFSR_ERR)
                    q <= 6'b000000;
                else
                    q <= q_next;

                if (at_shb)                  hblank <= 1'b1;
                else if (at_rhb || at_lrhb)  hblank <= 1'b0;
            end

            if (sync_ce) begin
                if (q == `TIA_HC_SHS) hsync <= 1'b1;
                if (q == `TIA_HC_RHS) hsync <= 1'b0;

                if (q == `TIA_HC_RCB)                    cburst <= 1'b1;
                else if (q == `TIA_HC_RHB || q == `TIA_HC_LRHB) cburst <= 1'b0;
            end
        end
    end

endmodule
