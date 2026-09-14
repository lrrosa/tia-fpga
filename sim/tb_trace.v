// tb_trace.v -- replay a Sim2600 pin trace into the RTL and compare.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The trace holds one record per TIA half clock: what the console put on the
// chip's pins and what the die drove back. This testbench feeds the recorded
// stimulus to the core and checks the recorded response, so every mismatch is
// a real difference from the silicon rather than a disagreement about what
// the 6507 ought to have been doing.
//
// ALIGNMENT. The trace starts wherever the recording started, which is
// somewhere in the middle of a scanline, while the core comes out of reset at
// the top of one. Rather than guess, the testbench replays the trace at every
// offset within a scanline and keeps the one with the fewest sync errors. The
// offset it settles on is a property of the harness, not a fudge factor in the
// RTL -- if no offset gives clean horizontal timing, that is a real finding.
//
//   +trace=FILE     trace to replay                          (required)
//   +align=N        force this alignment instead of searching
//   +first=N        print details of the first N mismatches   (default 20)
//   +warm=N         do not score the first N records         (default 2000)
//   +quiet          summary only
//   +dump=FILE      write the core's lum/col/sync/blank for every scored record
//
// WARM-UP. A trace that starts at power-on begins in the middle of the 6507's
// reset sequence, with the die in whatever state it powered up in. The core
// still has to replay every record from the start -- that is how its register
// file gets loaded -- but scoring only begins once both are past the reset and
// at a line boundary.

`timescale 1ns / 1ps

module tb_trace;

    localparam MAXREC     = 1048576;
    localparam OVERSAMPLE = 4;      // system clocks per recorded half clock
    localparam ALIGN_MAX  = 456;    // one scanline of half clocks
    localparam ALIGN_WIN  = 1368;   // records to score during the search

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

    // ------------------------------------------------------------------- DUT
    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        clk0 = 1'b0;
    reg        clk2 = 1'b0;
    reg  [5:0] ab = 6'd0;
    reg  [7:0] db_in = 8'd0;
    reg        cs0_n = 1'b1;
    reg        cs3_n = 1'b1;
    reg        rw = 1'b1;
    reg  [5:0] inpt = 6'h3F;

    wire       ph0, rdy_low, sync_low, blank, cburst, db_oe;
    wire [7:0] db_out;
    wire [2:0] lum;
    wire [3:0] col, au0, au1;

    tia dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .clk0     (clk0),
        .clk2     (clk2),
        .ph0      (ph0),
        .ab       (ab),
        .db_in    (db_in),
        .db_out   (db_out),
        .db_oe    (db_oe),
        .cs0_n    (cs0_n),
        .cs1      (1'b1),
        .cs2_n    (1'b0),
        .cs3_n    (cs3_n),
        .rw       (rw),
        .rdy_low  (rdy_low),
        .inpt     (inpt),
        .sync_low (sync_low),
        .lum      (lum),
        .col      (col),
        .blank    (blank),
        .cburst   (cburst),
        .au0      (au0),
        .au1      (au1)
    );

    always #1 clk = ~clk;

    // What the core's data bus drivers would look like on the die's four
    // drive-control wires: {DB7_drvHi, DB7_drvLo, DB6_drvHi, DB6_drvLo}.
    wire [3:0] dbdrv_rtl = db_oe ? { db_out[7], ~db_out[7], db_out[6], ~db_out[6] }
                                 : 4'b0000;

    // ------------------------------------------------------------ statistics
    integer m_ph0, m_rdy, m_sync, m_lum, m_col, m_blk, m_blkinv;
    integer m_au0, m_au1, m_dbdrv, compared;

    // --------------------------------------------------------------- replay
    integer align, shown, first_n, best_align, best_score, score;
    integer quiet, forced_align, stop, warm_after;
    integer phi2_votes, k;
    reg     phi2_wiring = 1'b0;
    integer f_ph0, f_rdy, f_sync, f_lum, f_col, f_blk, f_dbdrv;
    reg [8*512-1:0] trace_path;   // Windows paths get long
    reg          detail;
    reg          dumping = 1'b0;
    integer      dump_fd = 0;
    reg [8*512-1:0] dump_path;

    // The core needs one line boundary to lock its counters to the trace, so
    // nothing before the first HBLANK edge in the window is counted. That is
    // warm-up, not a tolerance: after it, every record is checked.
    function integer first_line_start;
        input integer from;
        integer k;
        begin
            first_line_start = from;
            for (k = from + 1; k < nrec; k = k + 1)
                if (t_blk[k] && !t_blk[k-1]) begin
                    first_line_start = k;
                    k = nrec;
                end
        end
    endfunction

    task note;
        input integer rec;
        inout integer slot;
        begin
            if (slot < 0) slot = rec;
        end
    endtask

    task replay;
        input integer start;
        input integer last;
        integer k;
        integer warm;
        begin
            warm = first_line_start(start > warm_after ? start : warm_after);
            f_ph0 = -1; f_rdy = -1; f_sync = -1; f_lum = -1;
            f_col = -1; f_blk = -1; f_dbdrv = -1;
            m_ph0 = 0; m_rdy = 0; m_sync = 0; m_lum = 0; m_col = 0;
            m_blk = 0; m_blkinv = 0; m_au0 = 0; m_au1 = 0; m_dbdrv = 0;
            compared = 0; shown = 0;

            rst_n = 1'b0;
            repeat (8) @(posedge clk);
            #0.2;
            rst_n = 1'b1;

            for (k = start; k < last; k = k + 1) begin
                clk0  = t_clk0[k];
                clk2  = t_clk2[k];
                // With the console's wiring PHI2 falls before the 6507 moves
                // the bus, and the die's bus latch closes on the old cycle; a
                // record only shows the bus after the move. Hold it while CLK2
                // is low, as the latch does.
                if (!phi2_wiring || t_clk2[k]) begin
                    rw    = t_rw[k];
                    cs0_n = t_cs0[k];
                    cs3_n = t_cs3[k];
                    ab    = t_ab[k];
                    db_in = t_db[k];
                end
                inpt  = t_inpt[k];

                repeat (OVERSAMPLE) @(posedge clk);
                #0.2;

                if (k >= warm) begin
                compared = compared + 1;
                if (dumping && dump_fd != 0)
                    $fwrite(dump_fd, "%0d %h %h %b %b %b %h %b\n", k, lum, col, sync_low, blank, rdy_low, dbdrv_rtl, cburst);

                if (ph0       !== t_ph0[k])  begin m_ph0  = m_ph0  + 1; note(k, f_ph0);  end
                if (rdy_low   !== t_rdy[k])  begin m_rdy  = m_rdy  + 1; note(k, f_rdy);  end
                if (sync_low  !== t_sync[k]) begin m_sync = m_sync + 1; note(k, f_sync); end
                if (lum       !== t_lum[k])  begin m_lum  = m_lum  + 1; note(k, f_lum);  end
                if (col       !== t_col[k])  begin m_col  = m_col  + 1; note(k, f_col);  end
                if (blank     !== t_blk[k])  begin m_blk  = m_blk  + 1; note(k, f_blk);  end
                if (blank     === t_blk[k])   m_blkinv = m_blkinv + 1;
                if (au0       !== t_au0[k])   m_au0   = m_au0   + 1;
                if (au1       !== t_au1[k])   m_au1   = m_au1   + 1;
                if (dbdrv_rtl !== t_dbdrv[k]) begin m_dbdrv = m_dbdrv + 1; note(k, f_dbdrv); end

                if (detail && shown < first_n &&
                    (lum !== t_lum[k] || col !== t_col[k] ||
                     sync_low !== t_sync[k])) begin
                    $display("  rec %0d  sync %b/%b  blank %b/%b  lum %h/%h  col %h/%h   (rtl/die)",
                             k, sync_low, t_sync[k], blank, t_blk[k],
                             lum, t_lum[k], col, t_col[k]);
                    shown = shown + 1;
                end
                end
            end
        end
    endtask

    // ----------------------------------------------------------------- load
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

    initial begin
        if (!$value$plusargs("trace=%s", trace_path)) begin
            $display("ERROR: pass +trace=FILE");
            $finish;
        end
        if (!$value$plusargs("first=%d", first_n)) first_n = 20;
        if (!$value$plusargs("warm=%d", warm_after)) warm_after = 2000;
        quiet = $test$plusargs("quiet");
        if ($value$plusargs("dump=%s", dump_path))
            dump_fd = $fopen(dump_path, "w");

        load_trace;
        $display("loaded %0d records from %0s", nrec, trace_path);

        // Which way the trace was wired: on the console CLK2 is PHI2, one
        // record behind PH0; upstream Sim2600 feeds it CLK1OUT, its inverse.
        phi2_votes = 0;
        for (k = 1; k < nrec && k < 4000; k = k + 1)
            if (t_clk2[k] === t_ph0[k-1]) phi2_votes = phi2_votes + 1;
        phi2_wiring = (2 * phi2_votes > (nrec < 4000 ? nrec : 4000));
        $display("clock wiring: %0s", phi2_wiring ? "PHI2 on CLK2, as on the console"
                                                  : "CLK1OUT on CLK2, as upstream Sim2600");

        detail = 1'b0;

        if ($value$plusargs("align=%d", forced_align)) begin
            best_align = forced_align;
        end else begin
            // Score each alignment on the sync pulse alone: it is a pure
            // decode of the horizontal counter, so it pins the phase without
            // any help from the graphics path.
            stop = warm_after + ALIGN_WIN;
            if (stop > nrec) stop = nrec;
            best_align = 0;
            best_score = 1000000000;
            for (align = 0; align < ALIGN_MAX; align = align + 1) begin
                replay(align, stop);
                score = m_sync;
                if (score < best_score) begin
                    best_score = score;
                    best_align = align;
                end
            end
            $display("alignment search: best offset %0d half clocks (%0d sync errors over %0d records)",
                     best_align, best_score, stop - best_align);
        end

        detail = ~quiet;
        dumping = 1'b1;
        $display("");
        $display("replaying records %0d .. %0d", best_align, nrec - 1);
        replay(best_align, nrec);
        $display("");
        $display("mismatches out of %0d records", compared);
        $display("    ph0       %0d", m_ph0);
        $display("    rdy_low   %0d", m_rdy);
        $display("    sync_low  %0d", m_sync);
        $display("    blank     %0d   (matches: %0d)", m_blk, m_blkinv);
        $display("    lum       %0d", m_lum);
        $display("    col       %0d", m_col);
        $display("    au0       %0d", m_au0);
        $display("    au1       %0d", m_au1);
        $display("    dbdrv     %0d", m_dbdrv);
        $display("first mismatch record: ph0 %0d  rdy %0d  sync %0d  blank %0d  lum %0d  col %0d  dbdrv %0d",
                 f_ph0, f_rdy, f_sync, f_blk, f_lum, f_col, f_dbdrv);

        if (m_sync == 0 && m_lum == 0 && m_col == 0 &&
            m_ph0 == 0 && m_rdy == 0 && m_dbdrv == 0)
            $display("PASS");
        else
            $display("FAIL");

        if (dump_fd != 0) $fclose(dump_fd);
        $finish;
    end

endmodule
