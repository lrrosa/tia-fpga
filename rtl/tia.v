// tia.v -- Television Interface Adaptor, top level.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// A replacement for the Atari 2600's C010444 / C010444D.
//
// CLOCKING. The real chip is clocked directly by the 3.58 MHz colour clock on
// pin 11 and uses both of its edges: the horizontal counter runs off CLK,
// while MOTCK -- the clock for every movable object -- is an inverted CLK.
// An FPGA design that used both edges would be awkward to time, so this core
// takes a faster system clock and treats the colour clock as a signal to be
// oversampled. Everything that happens on a colour clock edge in the original
// happens here on the first system clock after that edge, as a clock enable.
//
// That costs one system clock of latency against the die and buys a single
// clock domain, single edge, no gated clocks. On the rev A board `clk` comes
// from the Tang Nano's oscillator through a PLL and `clk0` from the console's
// own 3.579545 MHz crystal by way of U4, so the core stays locked to the
// machine it is plugged into rather than free-running.
//
// PADS. Only D7 and D6 are ever driven by the chip; the other six data lines
// are inputs, which is why reads of the collision and input registers leave
// the low six bits at whatever the bus was last holding. The luminance,
// colour, sync and blank outputs are given here as their drive-low controls
// so they line up one for one with the wires Sim2600 exposes -- see
// sim/README.md.

`include "tia_defs.vh"

module tia (
    input  wire       clk,           // system clock, oversamples the colour clock
    input  wire       rst_n,

    // ------------------------------------------------------------ clock pins
    input  wire       clk0,          // pin 11, 3.579545 MHz colour clock
    input  wire       clk2,          // pin 26, phase 2 from the 6507
    output wire       ph0,           // pin 27, phase 0 to the 6507

    // -------------------------------------------------------------- bus pins
    input  wire [5:0] ab,            // A0..A5
    input  wire [7:0] db_in,
    output wire [7:0] db_out,        // only bits 7 and 6 are meaningful
    output wire       db_oe,
    input  wire       cs0_n,
    input  wire       cs1,
    input  wire       cs2_n,
    input  wire       cs3_n,
    input  wire       rw,            // 1 = the 6507 is reading
    output wire       rdy_low,       // 1 = pull the 6507's RDY to ground

    // ------------------------------------------------------------ input pins
    input  wire [5:0] inpt,          // I0..I5

    // ------------------------------------------------------- video and audio
    output wire       sync_low,      // 1 = pull the SYNC pad low
    output wire [2:0] lum,           // luminance, 1 = pad driven high
    output wire [3:0] col,           // colour index selecting the chroma phase
    output wire       blank,         // 1 = blanked (HBLANK or VBLANK)
    output wire       cburst,        // colour burst window
    output wire [3:0] au0,           // weighted taps of the AUD0 pad
    output wire [3:0] au1
);

    // ===================================================== colour clock edges
    reg clk0_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clk0_d <= 1'b0;
        else        clk0_d <= clk0;
    end

    wire ce_rise =  clk0 & ~clk0_d;
    wire ce_fall = ~clk0 &  clk0_d;

    // ======================================================== phase 0 to CPU
    // The colour clock divided by three, counted on BOTH edges: the die's PH0
    // is high for three half colour clocks and low for three, a clean 50 per
    // cent duty cycle that a divider clocked on one edge alone cannot make.
    //
    // Towers mentions "some auto-synchronisation between the two-phase clock
    // and the div-by-3 counter for the CPU clock" without pinning it down.
    // The traces do: PH0 rises on exactly the half clock where HBLANK starts,
    // every line without exception. So the horizontal counter reloads the
    // divider, and the CPU phase cannot drift against the picture.
    reg [2:0] div6;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                   div6 <= 3'd3;
        else if (shb)                 div6 <= 3'd3;
        else if (ce_rise || ce_fall)  div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
    end
    assign ph0 = (div6 >= 3'd3);

    // ============================================================= bus cycle
    wire cs = ~cs0_n & cs1 & ~cs2_n & ~cs3_n;

    reg clk2_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clk2_d <= 1'b0;
        else        clk2_d <= clk2;
    end
    wire clk2_fall = ~clk2 &  clk2_d;

    // The 6507 holds address and data valid through phase 2; the TIA takes
    // them on its falling edge.
    wire wr = cs & ~rw & clk2_fall;

    // ====================================================== write registers
    reg        vsync_r, vblank_r;
    reg  [2:0] nusiz0, nusiz1;
    reg  [1:0] msize0, msize1;
    reg  [7:0] colup0, colup1, colupf, colubk;
    reg  [7:0] ctrlpf;
    reg        refp0, refp1;
    reg  [7:0] pf0, pf1, pf2;
    reg  [3:0] audc0, audc1;
    reg  [4:0] audf0, audf1;
    reg  [3:0] audv0, audv1;
    reg  [7:0] grp0_new, grp0_old, grp1_new, grp1_old;
    reg        enam0, enam1;
    reg        enabl_new, enabl_old;
    reg  [3:0] hmp0, hmp1, hmm0, hmm1, hmbl;
    reg        vdelp0, vdelp1, vdelbl;
    reg        resmp0, resmp1;
    reg        inpt_latch;            // VBLANK D6
    reg        inpt_dump;             // VBLANK D1

    // Strobes, one system clock wide.
    wire wsync_s  = wr & (ab == `TIA_WSYNC);
    wire rsync_s  = wr & (ab == `TIA_RSYNC);
    wire resp0_s  = wr & (ab == `TIA_RESP0);
    wire resp1_s  = wr & (ab == `TIA_RESP1);
    wire resm0_s  = wr & (ab == `TIA_RESM0);
    wire resm1_s  = wr & (ab == `TIA_RESM1);
    wire resbl_s  = wr & (ab == `TIA_RESBL);
    wire hmove_s  = wr & (ab == `TIA_HMOVE);
    wire hmclr_s  = wr & (ab == `TIA_HMCLR);
    wire cxclr_s  = wr & (ab == `TIA_CXCLR);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_r <= 1'b0;  vblank_r <= 1'b0;
            nusiz0  <= 3'd0;  nusiz1   <= 3'd0;
            msize0  <= 2'd0;  msize1   <= 2'd0;
            colup0  <= 8'd0;  colup1   <= 8'd0;
            colupf  <= 8'd0;  colubk   <= 8'd0;
            ctrlpf  <= 8'd0;
            refp0   <= 1'b0;  refp1    <= 1'b0;
            pf0     <= 8'd0;  pf1      <= 8'd0;  pf2 <= 8'd0;
            audc0   <= 4'd0;  audc1    <= 4'd0;
            audf0   <= 5'd0;  audf1    <= 5'd0;
            audv0   <= 4'd0;  audv1    <= 4'd0;
            grp0_new <= 8'd0; grp0_old <= 8'd0;
            grp1_new <= 8'd0; grp1_old <= 8'd0;
            enam0   <= 1'b0;  enam1    <= 1'b0;
            enabl_new <= 1'b0; enabl_old <= 1'b0;
            hmp0    <= 4'd0;  hmp1     <= 4'd0;
            hmm0    <= 4'd0;  hmm1     <= 4'd0;  hmbl <= 4'd0;
            vdelp0  <= 1'b0;  vdelp1   <= 1'b0;  vdelbl <= 1'b0;
            resmp0  <= 1'b0;  resmp1   <= 1'b0;
            inpt_latch <= 1'b0; inpt_dump <= 1'b0;
        end else begin
            if (hmclr_s) begin
                hmp0 <= 4'd0; hmp1 <= 4'd0;
                hmm0 <= 4'd0; hmm1 <= 4'd0; hmbl <= 4'd0;
            end

            if (wr) begin
                case (ab)
                `TIA_VSYNC:  vsync_r  <= db_in[1];
                `TIA_VBLANK: begin
                                vblank_r   <= db_in[1];
                                inpt_latch <= db_in[6];
                                inpt_dump  <= db_in[7];
                             end
                `TIA_NUSIZ0: begin nusiz0 <= db_in[2:0]; msize0 <= db_in[5:4]; end
                `TIA_NUSIZ1: begin nusiz1 <= db_in[2:0]; msize1 <= db_in[5:4]; end
                `TIA_COLUP0: colup0 <= db_in;
                `TIA_COLUP1: colup1 <= db_in;
                `TIA_COLUPF: colupf <= db_in;
                `TIA_COLUBK: colubk <= db_in;
                `TIA_CTRLPF: ctrlpf <= db_in;
                `TIA_REFP0:  refp0  <= db_in[3];
                `TIA_REFP1:  refp1  <= db_in[3];
                `TIA_PF0:    pf0    <= db_in;
                `TIA_PF1:    pf1    <= db_in;
                `TIA_PF2:    pf2    <= db_in;
                `TIA_AUDC0:  audc0  <= db_in[3:0];
                `TIA_AUDC1:  audc1  <= db_in[3:0];
                `TIA_AUDF0:  audf0  <= db_in[4:0];
                `TIA_AUDF1:  audf1  <= db_in[4:0];
                `TIA_AUDV0:  audv0  <= db_in[3:0];
                `TIA_AUDV1:  audv1  <= db_in[3:0];
                // The vertical delay registers are a shift chain: writing one
                // player's graphics latches the other player's, and the ball.
                `TIA_GRP0:   begin grp0_new <= db_in; grp1_old <= grp1_new; end
                `TIA_GRP1:   begin grp1_new <= db_in; grp0_old <= grp0_new;
                                   enabl_old <= enabl_new; end
                `TIA_ENAM0:  enam0 <= db_in[1];
                `TIA_ENAM1:  enam1 <= db_in[1];
                `TIA_ENABL:  enabl_new <= db_in[1];
                `TIA_HMP0:   hmp0 <= db_in[7:4];
                `TIA_HMP1:   hmp1 <= db_in[7:4];
                `TIA_HMM0:   hmm0 <= db_in[7:4];
                `TIA_HMM1:   hmm1 <= db_in[7:4];
                `TIA_HMBL:   hmbl <= db_in[7:4];
                `TIA_VDELP0: vdelp0 <= db_in[0];
                `TIA_VDELP1: vdelp1 <= db_in[0];
                `TIA_VDELBL: vdelbl <= db_in[0];
                `TIA_RESMP0: resmp0 <= db_in[1];
                `TIA_RESMP1: resmp1 <= db_in[1];
                default: ;
                endcase
            end
        end
    end

    // ================================================== horizontal counter
    wire        hblank, hsync;
    wire        hc_p1, hc_p2, shb, shb_early, rhb, cntd, aud_ck;
    wire        hmove_latch;
    wire [5:0]  hc_q;

    tia_hcount u_hcount (
        .clk         (clk),
        .rst_n       (rst_n),
        .ce_rise     (ce_rise),
        .ce_fall     (ce_fall),
        .rsync       (rsync_s),
        .hmove_latch (hmove_latch),
        .q           (hc_q),
        .p1          (hc_p1),
        .p2          (hc_p2),
        .hsync       (hsync),
        .hblank      (hblank),
        .cburst      (cburst),
        .shb         (shb),
        .shb_early   (shb_early),
        .rhb         (rhb),
        .cntd        (cntd),
        .aud_ck      (aud_ck)
    );

    // WSYNC holds the 6507 until the counter wraps into the next line.
    reg rdy_low_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          rdy_low_r <= 1'b0;
        else if (shb_early)  rdy_low_r <= 1'b0;
        else if (wsync_s)    rdy_low_r <= 1'b1;
    end
    assign rdy_low = rdy_low_r;

    // ========================================================== motion clock
    // MOTCK only runs while the picture is live. During HBLANK the object
    // counters keep whatever quarter-count they had, which is where sprite
    // wrap-around comes from, and it is also what lets HMOVE stuff extra
    // pulses down the same lines without fighting anything.
    wire       motck = ce_rise & ~hblank;
    wire [4:0] stuff;

    tia_hmove u_hmove (
        .clk         (clk),
        .rst_n       (rst_n),
        .p1          (hc_p1),
        .p2          (hc_p2),
        .shb         (shb),
        .hmove       (hmove_s),
        .hmp0        (hmp0),
        .hmp1        (hmp1),
        .hmm0        (hmm0),
        .hmm1        (hmm1),
        .hmbl        (hmbl),
        .hmove_latch (hmove_latch),
        .stuff       (stuff)
    );

    wire ce_p0 = motck | stuff[4];
    wire ce_p1 = motck | stuff[3];
    wire ce_m0 = motck | stuff[2];
    wire ce_m1 = motck | stuff[1];
    wire ce_bl = motck | stuff[0];

    // ============================================================== objects
    wire p0_p1, p0_p2, p1_p1, p1_p2;
    wire m0_p1, m0_p2, m1_p1, m1_p2, bl_p1, bl_p2;
    wire p0_close, p0_med, p0_far, p0_main;
    wire p1_close, p1_med, p1_far, p1_main;
    wire m0_close, m0_med, m0_far, m0_main;
    wire m1_close, m1_med, m1_far, m1_main;
    wire bl_main;
    wire [2:0] p0_scan, p1_scan;
    wire p0_fstob, p1_fstob;

    // RESMP parks a missile in the middle of its player's main copy.
    wire m0_lock = resmp0 & (p0_scan == 3'b100) & ~p0_fstob;
    wire m1_lock = resmp1 & (p1_scan == 3'b100) & ~p1_fstob;

    tia_objcnt u_p0_cnt (
        .clk (clk), .rst_n (rst_n), .ce (ce_p0), .ce_free (ce_rise), .reset (resp0_s),
        .q (), .p1 (p0_p1), .p2 (p0_p2), .ph (),
        .dec_close (p0_close), .dec_med (p0_med),
        .dec_far (p0_far), .dec_main (p0_main));

    tia_objcnt u_p1_cnt (
        .clk (clk), .rst_n (rst_n), .ce (ce_p1), .ce_free (ce_rise), .reset (resp1_s),
        .q (), .p1 (p1_p1), .p2 (p1_p2), .ph (),
        .dec_close (p1_close), .dec_med (p1_med),
        .dec_far (p1_far), .dec_main (p1_main));

    tia_objcnt u_m0_cnt (
        .clk (clk), .rst_n (rst_n), .ce (ce_m0), .ce_free (ce_rise), .reset (resm0_s | m0_lock),
        .q (), .p1 (m0_p1), .p2 (m0_p2), .ph (),
        .dec_close (m0_close), .dec_med (m0_med),
        .dec_far (m0_far), .dec_main (m0_main));

    tia_objcnt u_m1_cnt (
        .clk (clk), .rst_n (rst_n), .ce (ce_m1), .ce_free (ce_rise), .reset (resm1_s | m1_lock),
        .q (), .p1 (m1_p1), .p2 (m1_p2), .ph (),
        .dec_close (m1_close), .dec_med (m1_med),
        .dec_far (m1_far), .dec_main (m1_main));

    tia_objcnt u_bl_cnt (
        .clk (clk), .rst_n (rst_n), .ce (ce_bl), .ce_free (ce_rise), .reset (resbl_s),
        .q (), .p1 (bl_p1), .p2 (bl_p2), .ph (),
        .dec_close (), .dec_med (), .dec_far (), .dec_main (bl_main));

    wire px_p0, px_p1, px_m0, px_m1, px_bl, px_pf;
    wire pf_right_half;

    tia_player u_p0 (
        .clk (clk), .rst_n (rst_n), .ce (ce_p0), .p1 (p0_p1), .p2 (p0_p2),
        .dec_close (p0_close), .dec_med (p0_med),
        .dec_far (p0_far), .dec_main (p0_main),
        .nusiz (nusiz0), .reflect (refp0), .vdel (vdelp0),
        .grp_new (grp0_new), .grp_old (grp0_old),
        .pixel (px_p0), .scan_pos (p0_scan), .fstob (p0_fstob));

    tia_player u_p1 (
        .clk (clk), .rst_n (rst_n), .ce (ce_p1), .p1 (p1_p1), .p2 (p1_p2),
        .dec_close (p1_close), .dec_med (p1_med),
        .dec_far (p1_far), .dec_main (p1_main),
        .nusiz (nusiz1), .reflect (refp1), .vdel (vdelp1),
        .grp_new (grp1_new), .grp_old (grp1_old),
        .pixel (px_p1), .scan_pos (p1_scan), .fstob (p1_fstob));

    tia_missile u_m0 (
        .clk (clk), .rst_n (rst_n), .ce (ce_m0), .p1 (m0_p1), .p2 (m0_p2),
        .dec_close (m0_close), .dec_med (m0_med),
        .dec_far (m0_far), .dec_main (m0_main),
        .nusiz (nusiz0), .size (msize0), .enam (enam0), .resmp (resmp0),
        .pixel (px_m0));

    tia_missile u_m1 (
        .clk (clk), .rst_n (rst_n), .ce (ce_m1), .p1 (m1_p1), .p2 (m1_p2),
        .dec_close (m1_close), .dec_med (m1_med),
        .dec_far (m1_far), .dec_main (m1_main),
        .nusiz (nusiz1), .size (msize1), .enam (enam1), .resmp (resmp1),
        .pixel (px_m1));

    tia_ball u_bl (
        .clk (clk), .rst_n (rst_n), .ce (ce_bl), .p1 (bl_p1), .p2 (bl_p2),
        .dec_main (bl_main), .resbl (resbl_s), .size (ctrlpf[5:4]),
        .enabl_new (enabl_new), .enabl_old (enabl_old), .vdel (vdelbl),
        .pixel (px_bl));

    tia_playfield u_pf (
        .clk (clk), .rst_n (rst_n), .p2 (hc_p2),
        .rhb (rhb), .cntd (cntd), .hblank (hblank),
        .pf0 (pf0), .pf1 (pf1), .pf2 (pf2), .reflect (ctrlpf[0]),
        .pixel (px_pf), .right_half (pf_right_half));

    // ============================================================ collisions
    wire [14:0] cx;

    tia_collide u_cx (
        .clk (clk), .rst_n (rst_n), .enable (ce_rise & ~hblank), .cxclr (cxclr_s),
        .p0 (px_p0), .p1 (px_p1), .m0 (px_m0), .m1 (px_m1),
        .bl (px_bl), .pf (px_pf), .cx (cx));

    localparam CX_M0P1 = 0,  CX_M0P0 = 1,  CX_M1P0 = 2,  CX_M1P1 = 3,
               CX_P0PF = 4,  CX_P0BL = 5,  CX_P1PF = 6,  CX_P1BL = 7,
               CX_M0PF = 8,  CX_M0BL = 9,  CX_M1PF = 10, CX_M1BL = 11,
               CX_BLPF = 12, CX_P0P1 = 13, CX_M0M1 = 14;

    // ================================================================ audio
    tia_audio u_au0 (
        .clk (clk), .rst_n (rst_n), .aud_ck (aud_ck),
        .audc (audc0), .audf (audf0), .audv (audv0), .out (au0));

    tia_audio u_au1 (
        .clk (clk), .rst_n (rst_n), .aud_ck (aud_ck),
        .audc (audc1), .audf (audf1), .audv (audv1), .out (au1));

    // ========================================================= colour output
    wire blanked = hblank | vblank_r;
    assign blank = blanked;

    wire       score = ctrlpf[1];
    wire       pfp   = ctrlpf[2];
    wire       pf_bl = px_pf | px_bl;
    wire [7:0] pf_colour = score ? (pf_right_half ? colup1 : colup0) : colupf;

    reg [7:0] colour;
    always @(*) begin
        if (blanked)
            colour = 8'h00;
        else if (pfp) begin
            if      (pf_bl)          colour = pf_colour;
            else if (px_p0 | px_m0)  colour = colup0;
            else if (px_p1 | px_m1)  colour = colup1;
            else                     colour = colubk;
        end else begin
            if      (px_p0 | px_m0)  colour = colup0;
            else if (px_p1 | px_m1)  colour = colup1;
            else if (pf_bl)          colour = pf_colour;
            else                     colour = colubk;
        end
    end

    // The pads are latched on the falling colour clock edge, the same edge the
    // horizontal counter runs on. Without this the whole picture sits half a
    // colour clock to the left of where the die puts it, and every object edge
    // lands on the wrong phase.
    reg [7:0] colour_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        colour_q <= 8'h00;
        else if (ce_fall)  colour_q <= colour;
    end

    assign col = colour_q[7:4];
    assign lum = colour_q[3:1];

    // Composite sync: VSYNC inverts the horizontal sync pulse train, which is
    // what produces the serrations during vertical retrace.
    assign sync_low = hsync ^ vsync_r;

    // ================================================================= reads
    reg [1:0] rdata;
    always @(*) begin
        case (ab[3:0])
        `TIA_CXM0P:  rdata = { cx[CX_M0P1], cx[CX_M0P0] };
        `TIA_CXM1P:  rdata = { cx[CX_M1P0], cx[CX_M1P1] };
        `TIA_CXP0FB: rdata = { cx[CX_P0PF], cx[CX_P0BL] };
        `TIA_CXP1FB: rdata = { cx[CX_P1PF], cx[CX_P1BL] };
        `TIA_CXM0FB: rdata = { cx[CX_M0PF], cx[CX_M0BL] };
        `TIA_CXM1FB: rdata = { cx[CX_M1PF], cx[CX_M1BL] };
        `TIA_CXBLPF: rdata = { cx[CX_BLPF], 1'b0 };
        `TIA_CXPPMM: rdata = { cx[CX_P0P1], cx[CX_M0M1] };
        `TIA_INPT0:  rdata = { inpt[0], 1'b0 };
        `TIA_INPT1:  rdata = { inpt[1], 1'b0 };
        `TIA_INPT2:  rdata = { inpt[2], 1'b0 };
        `TIA_INPT3:  rdata = { inpt[3], 1'b0 };
        `TIA_INPT4:  rdata = { inpt[4], 1'b0 };
        `TIA_INPT5:  rdata = { inpt[5], 1'b0 };
        default:     rdata = 2'b00;
        endcase
    end

    // The die only holds the bus during phase 2, and only for the fourteen
    // addresses that decode to a readable register: traced reads show
    // DB6/DB7 driven for exactly the three half clocks where CLK2 is high and
    // released either side of them.
    wire readable = (ab[3:0] != 4'hE) && (ab[3:0] != 4'hF);

    assign db_out = { rdata, 6'b000000 };
    assign db_oe  = cs & rw & clk2 & readable;

endmodule
