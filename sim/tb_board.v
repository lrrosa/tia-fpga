// tb_board.v -- replay a Sim2600 trace into the board logic around the core.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// tb_trace.v checks the core. This checks what rtl/tia_board.v puts around it
// on the board: the colour clock counted out of the PLL clock, PHI2 rebuilt from
// PHI0 with the bus taken ahead of it, the data bus, the pulse-width sound
// pins and the chroma phases. The board has no PHI2 pin, so the trace's clk2
// column is not an input here: it is what the rebuilt CLK2 is checked against.
// Two boards run side by side, one for each AUDIO_STEREO setting.
//
//   +trace=FILE   trace to replay                          (required)
//   +warm=N       do not score the first N records         (default 2000)
//
// The trace must be recorded with the console's PHI2 wiring, as the traces
// under sim/traces/phi2 are -- see sim/README.md.

`timescale 1ns / 1ps

module tb_board;

    localparam MAXREC   = 1048576;
    localparam OSC_MULT = 16;
    localparam HALF     = OSC_MULT / 2;    // board clocks per trace record
    localparam SLOTS    = 2 * OSC_MULT;    // chroma slots per colour cycle
    localparam HUE_TURN = 14;

    // ------------------------------------------------------------ trace store
    reg        t_clk0  [0:MAXREC-1];
    reg        t_clk2  [0:MAXREC-1];
    reg        t_rw    [0:MAXREC-1];
    reg        t_cs0   [0:MAXREC-1];
    reg        t_cs3   [0:MAXREC-1];
    reg [5:0]  t_ab    [0:MAXREC-1];
    reg [7:0]  t_db    [0:MAXREC-1];
    reg [5:0]  t_inpt  [0:MAXREC-1];
    reg        t_ph0   [0:MAXREC-1];
    reg        t_rdy   [0:MAXREC-1];
    reg        t_sync  [0:MAXREC-1];
    reg [2:0]  t_lum   [0:MAXREC-1];
    reg [3:0]  t_col   [0:MAXREC-1];
    reg        t_blk   [0:MAXREC-1];
    reg [3:0]  t_au0   [0:MAXREC-1];
    reg [3:0]  t_au1   [0:MAXREC-1];
    reg [3:0]  t_dbdrv [0:MAXREC-1];

    integer nrec;

    // ------------------------------------------------------------------ DUTs
    reg        clk = 1'b0;
    reg        locked = 1'b0;
    reg  [5:0] a = 6'd0;
    reg        cs_n = 1'b1, rw = 1'b1;
    reg  [7:0] d_in = 8'd0;
    reg  [1:0] trig = 2'b11;

    wire [7:0] d_out, st_d_out;
    wire       d_oe, st_d_oe, phi0, st_phi0, rdy, st_rdy, csync, st_csync, blk, st_blk;
    wire [2:0] lum, st_lum;
    wire [1:0] col, st_col;
    wire       aud0, aud1, st_aud0, st_aud1;

    tia_board #(.OSC_MULT (OSC_MULT), .HUE_TURN (HUE_TURN), .AUDIO_STEREO (0)) dut (
        .clk (clk), .locked (locked), .a (a), .cs_n (cs_n), .rw (rw),
        .d_in (d_in), .d_out (d_out), .d_oe (d_oe), .phi0 (phi0), .rdy (rdy), .trig (trig),
        .csync (csync), .blk (blk), .lum (lum), .col (col), .aud0 (aud0), .aud1 (aud1));

    tia_board #(.OSC_MULT (OSC_MULT), .HUE_TURN (HUE_TURN), .AUDIO_STEREO (1)) dut_st (
        .clk (clk), .locked (locked), .a (a), .cs_n (cs_n), .rw (rw),
        .d_in (d_in), .d_out (st_d_out), .d_oe (st_d_oe), .phi0 (st_phi0), .rdy (st_rdy),
        .trig (trig), .csync (st_csync), .blk (st_blk), .lum (st_lum), .col (st_col),
        .aud0 (st_aud0), .aud1 (st_aud1));

    always #1 clk = ~clk;

    // ------------------------------------------------------------ statistics
    integer m_clk0, m_clk2, m_ph0, m_rdy, m_sync, m_blk, m_lum, m_dhi, m_dlo, n_reads;
    integer m_leak, m_phase, m_burst, n_edges, n_colour;
    integer m_mono, m_stereo, m_overlap, n_frames;
    integer warm, warm_after, k;
    reg [8*512-1:0] trace_path;

    // Board clocks since the core came out of reset, and whether scoring has
    // started.
    integer nclk = 0;
    reg     scoring = 1'b0;

    always @(posedge clk)
        if (dut.rst_n) nclk <= nclk + 1;

    function integer first_line_start;
        input integer from;
        integer j;
        begin
            first_line_start = from;
            for (j = from + 1; j < nrec; j = j + 1)
                if (t_blk[j] && !t_blk[j-1]) begin
                    first_line_start = j;
                    j = nrec;
                end
        end
    endfunction

    function integer expected_lag;
        input integer hue;
        begin
            expected_lag = ((2 * (hue - 1) * SLOTS + HUE_TURN) / (2 * HUE_TURN)) % SLOTS;
        end
    endfunction

    // ================================================================ chroma
    // The ODDR pair registered on one clock comes from the core's colour two
    // clocks earlier. Every falling edge of the waveform is measured against
    // the burst's: the offset, in slots, is the hue's delay.
    reg [3:0] hue_q1 = 4'd0, hue_q2 = 4'd0;
    reg       burst_q1 = 1'b0, burst_q2 = 1'b0;
    always @(posedge clk) begin
        hue_q1   <= dut.core_col;
        burst_q1 <= dut.core_cburst;
        hue_q2   <= hue_q1;
        burst_q2 <= burst_q1;
    end

    reg     c_prev = 1'b1;
    integer steady = 0;               // clocks the hue and burst state have held
    reg [4:0] last_state = 5'd0;
    integer burst_edge = -1;
    integer i, slot;
    reg     level;

    always @(negedge clk) if (scoring) begin
        if ({burst_q2, hue_q2} != last_state) steady = 0;
        else                                  steady = steady + 1;
        last_state = {burst_q2, hue_q2};
        if (!burst_q2 && hue_q2 != 4'd0) n_colour = n_colour + 1;

        if (!burst_q2 && hue_q2 == 4'd0 && col !== 2'b11)
            m_leak = m_leak + 1;

        for (i = 0; i < 2; i = i + 1) begin
            level = col[i];
            slot  = (2 * nclk + i) % SLOTS;
            if (c_prev === 1'b1 && level === 1'b0 && steady >= SLOTS) begin
                if (burst_q2) begin
                    if (burst_edge >= 0 && slot != burst_edge) m_burst = m_burst + 1;
                    burst_edge = slot;
                end else if (hue_q2 != 4'd0 && burst_edge >= 0) begin
                    n_edges = n_edges + 1;
                    if ((slot - burst_edge + SLOTS) % SLOTS != expected_lag(hue_q2))
                        m_phase = m_phase + 1;
                end
            end
            c_prev = level;
        end
    end

    // ================================================================= sound
    // The frame that starts on board clock 32m+1 carries the volumes of trace
    // record 4m-1: 32 clocks are four records.
    integer lo0, lo1, slo0, slo1, pos, fr;
    always @(negedge clk) if (scoring && nclk >= 33) begin
        pos = (nclk - 1) % 32;
        fr  = (nclk - 1) / 32;
        if (pos == 0) begin lo0 = 0; lo1 = 0; slo0 = 0; slo1 = 0; end
        lo0  = lo0  + (aud0    === 1'b0);
        lo1  = lo1  + (aud1    === 1'b0);
        slo0 = slo0 + (st_aud0 === 1'b0);
        slo1 = slo1 + (st_aud1 === 1'b0);
        if (st_aud0 === 1'b0 && st_aud1 === 1'b0) m_overlap = m_overlap + 1;
        if (pos == 31 && 4 * fr - 1 >= warm) begin
            n_frames = n_frames + 1;
            if (lo0 != t_au0[4*fr-1] + t_au1[4*fr-1] || lo1 != lo0)
                m_mono = m_mono + 1;
            if (slo0 != t_au0[4*fr-1] || slo1 != t_au1[4*fr-1])
                m_stereo = m_stereo + 1;
        end
    end

    // ================================================================= load
    integer fd, code;
    reg [8*512-1:0] line;
    reg [31:0] f0,  f1,  f2,  f3,  f4,  f5,  f6,  f7, f8;
    reg [31:0] f9, f10, f11, f12, f13, f14, f15, f16;

    task load_trace;
        begin
            fd = $fopen(trace_path, "r");
            if (fd == 0) begin
                $display("ERROR: cannot open trace %0s", trace_path);
                $finish;
            end
            nrec = 0;
            while (!$feof(fd) && nrec < MAXREC) begin
                code = $fgets(line, fd);
                if (code != 0) begin
                    code = $sscanf(line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                                   f0, f1, f2, f3, f4, f5, f6, f7, f8,
                                   f9, f10, f11, f12, f13, f14, f15, f16);
                    if (code == 17) begin
                        t_clk0[nrec]  = f0[0];
                        t_clk2[nrec]  = f1[0];
                        t_rw[nrec]    = f2[0];
                        t_cs0[nrec]   = f3[0];
                        t_cs3[nrec]   = f4[0];
                        t_ab[nrec]    = f5[5:0];
                        t_db[nrec]    = f6[7:0];
                        t_inpt[nrec]  = f7[5:0];
                        t_ph0[nrec]   = f8[0];
                        t_rdy[nrec]   = f9[0];
                        t_sync[nrec]  = f10[0];
                        t_lum[nrec]   = f11[2:0];
                        t_col[nrec]   = f12[3:0];
                        t_blk[nrec]   = f13[0];
                        t_au0[nrec]   = f14[3:0];
                        t_au1[nrec]   = f15[3:0];
                        t_dbdrv[nrec] = f16[3:0];
                        nrec = nrec + 1;
                    end
                end
            end
            $fclose(fd);
        end
    endtask

    // =============================================================== replay
    initial begin
        if (!$value$plusargs("trace=%s", trace_path)) begin
            $display("ERROR: pass +trace=FILE");
            $finish;
        end
        if (!$value$plusargs("warm=%d", warm_after)) warm_after = 2000;

        load_trace;
        $display("loaded %0d records from %0s", nrec, trace_path);
        warm = first_line_start(warm_after);

        m_clk0 = 0; m_clk2 = 0; m_ph0 = 0; m_rdy = 0; m_sync = 0; m_blk = 0; m_lum = 0;
        m_dhi = 0; m_dlo = 0; n_reads = 0;
        m_leak = 0; m_phase = 0; m_burst = 0; n_edges = 0; n_colour = 0;
        m_mono = 0; m_stereo = 0; m_overlap = 0; n_frames = 0;

        repeat (10) @(posedge clk);
        #0.2 locked = 1'b1;

        // Record k runs from board clock 8k after the reset lifts, which puts
        // the rebuilt colour clock's rising edges on the trace's.
        @(posedge dut.rst_n);
        for (k = 0; k < nrec; k = k + 1) begin
            #0.1;
            if (k == warm) scoring = 1'b1;
            if (k >= warm) begin
                if (dut.clk0      !== t_clk0[k]) m_clk0 = m_clk0 + 1;
                if (dut.clk2_core !== t_clk2[k]) m_clk2 = m_clk2 + 1;
            end

            #0.1;
            rw    = t_rw[k];
            cs_n  = t_cs0[k] | t_cs3[k];
            a     = t_ab[k];
            d_in  = t_db[k];
            trig  = t_inpt[k][5:4];

            repeat (HALF) @(posedge clk);
            #0.05;
            if (k >= warm) begin
                if (phi0  !== t_ph0[k])   m_ph0  = m_ph0  + 1;
                if (rdy   !== ~t_rdy[k])  m_rdy  = m_rdy  + 1;
                if (csync !== ~t_sync[k]) m_sync = m_sync + 1;
                if (blk   !== ~t_blk[k])  m_blk  = m_blk  + 1;
                if (lum   !== t_lum[k])   m_lum  = m_lum  + 1;

                // Where the die drives D7/D6, the board must drive the same,
                // and A5..A0 underneath.
                if (t_dbdrv[k] != 4'd0) begin
                    n_reads = n_reads + 1;
                    if (d_oe !== 1'b1 || d_out[7] !== t_dbdrv[k][3] || d_out[6] !== t_dbdrv[k][1])
                        m_dhi = m_dhi + 1;
                    if (d_out[5:0] !== t_ab[k])
                        m_dlo = m_dlo + 1;
                end
            end
        end

        $display("");
        $display("board check over records %0d .. %0d", warm, nrec - 1);
        $display("    clk0 rebuilt       %0d", m_clk0);
        $display("    clk2 rebuilt       %0d", m_clk2);
        $display("    phi0 pin           %0d", m_ph0);
        $display("    rdy pin            %0d", m_rdy);
        $display("    csync pin          %0d", m_sync);
        $display("    blk pin            %0d", m_blk);
        $display("    lum pins           %0d", m_lum);
        $display("    D7/D6 on reads     %0d   (of %0d records driven)", m_dhi, n_reads);
        $display("    D5..D0 on reads    %0d", m_dlo);
        $display("    chroma leaks       %0d", m_leak);
        $display("    chroma phase       %0d   (of %0d edges)   burst moved %0d", m_phase, n_edges, m_burst);
        $display("    sound mono         %0d   (of %0d frames)", m_mono, n_frames);
        $display("    sound stereo       %0d   overlaps %0d", m_stereo, m_overlap);

        if (m_clk0 == 0 && m_clk2 == 0 && m_ph0 == 0 && m_rdy == 0 && m_sync == 0 && m_blk == 0 &&
            m_lum == 0 && m_dhi == 0 && m_dlo == 0 && m_leak == 0 && m_phase == 0 &&
            m_burst == 0 && m_mono == 0 && m_stereo == 0 && m_overlap == 0 &&
            (n_colour == 0 || n_edges > 0))
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

endmodule
