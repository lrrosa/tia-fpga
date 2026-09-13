// tb_debug.v -- replay a window of a Sim2600 trace and print the core's guts
// next to the die's pins. For bring-up, not as a regression test.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
//   +trace=FILE  +align=N  +from=N  +to=N  +writes
//
// Pulses inside the core are one system clock wide, so anything sampled once
// per record would miss them entirely. Register writes and clock enables are
// therefore watched by their own always block rather than read at the end of
// a record -- getting that wrong once already cost an afternoon.

`timescale 1ns / 1ps

module tb_debug;

    localparam MAXREC     = 1048576;
    localparam OVERSAMPLE = 4;

    reg        t_clk0 [0:MAXREC-1];
    reg        t_clk2 [0:MAXREC-1];
    reg        t_rw   [0:MAXREC-1];
    reg        t_cs0  [0:MAXREC-1];
    reg        t_cs3  [0:MAXREC-1];
    reg [5:0]  t_ab   [0:MAXREC-1];
    reg [7:0]  t_db   [0:MAXREC-1];
    reg [5:0]  t_inpt [0:MAXREC-1];
    reg        t_ph0  [0:MAXREC-1];
    reg        t_rdy  [0:MAXREC-1];
    reg        t_sync [0:MAXREC-1];
    reg [2:0]  t_lum  [0:MAXREC-1];
    reg [3:0]  t_col  [0:MAXREC-1];
    reg        t_blk  [0:MAXREC-1];
    reg [3:0]  t_au0  [0:MAXREC-1];
    reg [3:0]  t_au1  [0:MAXREC-1];
    reg [3:0]  t_dbdrv[0:MAXREC-1];

    integer nrec;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        clk0 = 1'b0, clk2 = 1'b0;
    reg  [5:0] ab = 6'd0;
    reg  [7:0] db_in = 8'd0;
    reg        cs0_n = 1'b1, cs3_n = 1'b1, rw = 1'b1;
    reg  [5:0] inpt = 6'h3F;

    wire       ph0, rdy_low, sync_low, blank, cburst, db_oe;
    wire [7:0] db_out;
    wire [2:0] lum;
    wire [3:0] col, au0, au1;

    tia dut (
        .clk(clk), .rst_n(rst_n), .clk0(clk0), .clk2(clk2), .ph0(ph0),
        .ab(ab), .db_in(db_in), .db_out(db_out), .db_oe(db_oe),
        .cs0_n(cs0_n), .cs1(1'b1), .cs2_n(1'b0), .cs3_n(cs3_n), .rw(rw),
        .rdy_low(rdy_low), .inpt(inpt), .sync_low(sync_low), .lum(lum),
        .col(col), .blank(blank), .cburst(cburst), .au0(au0), .au1(au1));

    always #1 clk = ~clk;

    integer n_rise = 0, n_fall = 0, nwr = 0, show_writes = 0, k = 0;

    always @(posedge clk) begin
        if (dut.ce_rise) n_rise = n_rise + 1;
        if (dut.ce_fall) n_fall = n_fall + 1;
        if (dut.wr) begin
            nwr = nwr + 1;
            if (show_writes)
                $display("  WRITE rec %0d  ab=%h db=%h", k, ab, db_in);
        end
    end

    integer fd, code, from, to, align;
    reg [8*512-1:0] trace_path;   // Windows paths get long
    reg [8*512-1:0] line;
    reg [31:0] f0,f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13,f14,f15,f16;

    initial begin
        if (!$value$plusargs("trace=%s", trace_path)) $finish;
        if (!$value$plusargs("align=%d", align)) align = 0;
        if (!$value$plusargs("from=%d", from))   from = 0;
        if (!$value$plusargs("to=%d", to))       to = 200;
        show_writes = $test$plusargs("writes");

        fd = $fopen(trace_path, "r");
        if (fd == 0) begin $display("no trace"); $finish; end
        nrec = 0;
        while (!$feof(fd) && nrec < MAXREC) begin
            code = $fgets(line, fd);
            if (code != 0) begin
                code = $sscanf(line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                               f0,f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13,f14,f15,f16);
                if (code == 17) begin
                    t_clk0[nrec]=f0[0];  t_clk2[nrec]=f1[0];  t_rw[nrec]=f2[0];
                    t_cs0[nrec]=f3[0];   t_cs3[nrec]=f4[0];   t_ab[nrec]=f5[5:0];
                    t_db[nrec]=f6[7:0];  t_inpt[nrec]=f7[5:0]; t_ph0[nrec]=f8[0];
                    t_rdy[nrec]=f9[0];   t_sync[nrec]=f10[0]; t_lum[nrec]=f11[2:0];
                    t_col[nrec]=f12[3:0];t_blk[nrec]=f13[0];  t_au0[nrec]=f14[3:0];
                    t_au1[nrec]=f15[3:0];t_dbdrv[nrec]=f16[3:0];
                    nrec = nrec + 1;
                end
            end
        end
        $fclose(fd);
        $display("loaded %0d records", nrec);

        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        #0.2;
        rst_n = 1'b1;

        $display("rec    hq     hbl| p0cnt  scan en grp0 colup0 px0| p1cnt  scan en grp1 colup1 px1| lum r/d col r/d");
        for (k = align; k < nrec; k = k + 1) begin
            clk0 = t_clk0[k]; clk2 = t_clk2[k]; rw = t_rw[k];
            cs0_n = t_cs0[k]; cs3_n = t_cs3[k]; ab = t_ab[k];
            db_in = t_db[k];  inpt = t_inpt[k];
            repeat (OVERSAMPLE) @(posedge clk);
            #0.2;

            if (k >= from && k < to)
                $display("%0d %b %b | %b %b %b %h %h %b | %b %b %b %h %h %b | %h/%h %h/%h",
                         k, dut.u_hcount.q, dut.u_hcount.hblank,
                         dut.u_p0_cnt.q, dut.u_p0.scan, dut.u_p0.scan_en,
                         dut.grp0_new, dut.colup0, dut.px_p0,
                         dut.u_p1_cnt.q, dut.u_p1.scan, dut.u_p1.scan_en,
                         dut.grp1_new, dut.colup1, dut.px_p1,
                         lum, t_lum[k], col, t_col[k]);
        end
        $display("writes seen: %0d   ce_rise %0d  ce_fall %0d", nwr, n_rise, n_fall);
        $finish;
    end

endmodule
