// tia_hcount.v -- the horizontal sync counter and everything it decodes.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// A 6-bit polynomial counter running at CLK/4. It steps through 57 states per
// scanline (57 * 4 = 228 colour clocks) and its decode matrix produces every
// horizontal timing signal the TIA has.
//
// The counter changes state on H@2, so H@2 marks the start of each count. A
// decode is clocked into its latch over the following H@1 - H@2 cycle, which
// is the "delayed 4 CLK" the notes keep mentioning: here that falls out of
// updating the latches on the same H@2 that advances the counter, one state
// after the decode went true.
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

    input  wire       rsync,          // RSYNC write, as CLK2 falls
    input  wire       ph0,            // the CPU clock this chip drives
    input  wire       hmove_latch,    // HMOVE seen this line: use LRHB not RHB

    output reg  [5:0] q,              // counter state, Towers' notation
    output wire       p1,             // H@1
    output wire       p2,             // H@2
    output reg        hsync,
    output reg        hblank,
    output reg        cburst,
    output wire       shb,            // pulse: start of HBLANK / line reset
    output wire       rdy_rel,        // three half clocks before shb: RDY's release opens
    output wire       rsync_pre,      // one colour clock before an RSYNC restart
    output wire       rhb,            // pulse: HBLANK released this H@2
    output wire       cntd,           // pulse: centre, second half of the PF
    output wire       cnt_early,      // one colour clock before cntd
    output wire       rhb_next,       // level: the coming H@2 releases HBLANK
    output wire       cnt_next,       // level: the coming H@2 is the centre
    output wire       aud_a,          // audio phase A, two pulses per line
    output wire       aud_b           // audio phase B, two pulses per line
);

    // The LFSR: shift right, bit 5 fed by XNOR of the two bits falling off.
    wire [5:0] q_next = { ~(q[1] ^ q[0]), q[5:1] };

    // RSYNC. Towers: "A full H@1-H@2 cycle after RSYNC is strobed, the HSync
    // counter is also reset to 000000 and HBlank is turned on. This one
    // requires more investigation."
    //
    // The netlist settles it. Like every write strobe, RSYNC's is high for
    // the three half clocks CLK2 is low after the write -- but it is also a
    // NOR with PH0, so only those of the three in which PH0 is low count.
    // HBLANK comes on seven half clocks after the last of them, and the
    // counter restarts with it. PH0 is reloaded there as at any line start,
    // which cuts its previous half short when the two disagree.
    //
    // Counted from the write instead, the delay depends on where PH0 stands,
    // and that is the same for every write a given CPU wiring makes -- so one
    // wiring alone cannot tell the two rules apart. The console's wiring and
    // Sim2600's put PH0 on opposite sides of the write; this rule matches the
    // traces of both.
    //
    // The restart is also a line start: HBLANK comes on, the HMOVE latch is
    // cleared and the CPU clock divider reloads, exactly as at SHB.
    reg [1:0] rs_win;      // half clocks of the strobe still to look at
    reg [2:0] rs_wait;     // counts down to the restart
    wire      ce_any   = ce_rise | ce_fall;
    wire      rsync_go = ce_any & (rs_wait == 3'd1);

    wire [1:0] ph;

    // The counter itself runs on the falling edge of the colour clock; MOTCK,
    // which drives every movable object, is the inverted clock and therefore
    // runs on the rising edge. After an RSYNC the divider is left as if an
    // H@2 had just happened, so the first count after the restart is a full
    // four colour clocks.
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
    wire sync_ce  = ce_rise & (ph == 2'd1);
    // Two half clocks before H@2.
    wire early_ce = ce_fall & (ph == 2'd1);

    assign shb       = (p2 & at_shb) | rsync_go;
    assign rdy_rel   = sync_ce & at_shb;
    assign rsync_pre = ce_any & (rs_wait == 3'd3);
    assign rhb       = p2 & (at_rhb | at_lrhb);
    assign cntd      = p2 & (q == `TIA_HC_CNT);
    // SCORE mode switches to the right-hand player colour here, one colour
    // clock before the playfield's second half begins.
    assign cnt_early = early_ce & (q == `TIA_HC_CNT);
    assign rhb_next  = at_rhb | at_lrhb;
    assign cnt_next  = (q == `TIA_HC_CNT);

    // The audio clocks: two ticks a line, two phases a tick, all on the sync
    // latch's phase. Read off the netlist, phase A closes at counts 1 and 19
    // and phase B at counts 9 and 37 -- phase B is where Sim2600's audio pads
    // change, 77 and 301 half clocks into the line. The two ticks are 112 and
    // 116 colour clocks apart rather than an even 114, which is what decodes
    // of a 57-state counter can give you.
    assign aud_a     = sync_ce & ((q == `TIA_HC_AUDA1) | (q == `TIA_HC_AUDA2));
    assign aud_b     = sync_ce & ((q == `TIA_HC_AUDB1) | (q == `TIA_HC_AUDB2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q         <= 6'b000000;
            hsync     <= 1'b0;
            hblank    <= 1'b1;
            cburst    <= 1'b0;
            rs_win    <= 2'd0;
            rs_wait   <= 3'd0;
        end else begin
            // At each half clock, ph0 still holds the one just ended.
            if (rsync) begin
                rs_win  <= 2'd3;
                rs_wait <= 3'd0;
            end else if (ce_any) begin
                if (rs_win != 2'd0)
                    rs_win <= rs_win - 2'd1;
                if (rs_win != 2'd0 && !ph0)
                    rs_wait <= 3'd6;
                else if (rs_wait != 3'd0)
                    rs_wait <= rs_wait - 3'd1;
            end

            if (rsync_go) begin
                q         <= 6'b000000;
                hblank    <= 1'b1;
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
            end

            // The colour burst runs from RHS to RCB -- Towers' "reset colour
            // burst" -- starting one half clock after the sync pulse ends. No
            // pin in a trace shows it, so it was placed from the probed die:
            // its colour pad toggles for exactly these 32 half clocks.
            if (early_ce) begin
                if (q == `TIA_HC_RHS)       cburst <= 1'b1;
                else if (q == `TIA_HC_RCB)  cburst <= 1'b0;
            end
        end
    end

endmodule
