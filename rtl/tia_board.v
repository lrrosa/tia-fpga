// tia_board.v -- the TIA core as it sits on the rev A board.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Everything between the core and the board's pins that is not tied to one
// FPGA vendor: the core's two clocks, the bus, and the three outputs the die
// makes analogue -- chroma and the two sound channels. fpga/tia_fpga_top.v
// wraps this in the Gowin PLL and I/O primitives; sim/tb_board.v drives it
// directly.
//
// CLOCKS. A PLL multiplies the console's colour clock by OSC_MULT to make
// `clk`, so the colour clock the core wants is just a counter: nothing samples
// F_OSC, nothing can go metastable, and the chroma phases come from the same
// counter. Its phase against F_OSC is whatever the PLL settles on, which does
// not matter -- the television locks to the burst this board sends, not to
// the crystal.
//
// Rev A has no pin for PHI2 -- it went to chroma -- so it is rebuilt from
// PHI0, which the board makes itself. On the console PHI2 is the 6507's copy
// of PHI0, a few tens of nanoseconds late; see the PHI2 section for how the
// two uses of it are timed.
//
// PADS. The die drives SYNC, the three luminance lines, colour and both sound
// channels through pull-down transistors only, and the console supplies the
// pull-ups. Every video and sound output here is therefore a pad level: 1 for
// released, 0 for pulled low.
//
// SOUND. Each channel's pad is a four-transistor current DAC, which a logic
// pin cannot be, so volume comes back as pulse width: a channel at 0..15 is
// pulled low for that many clocks out of every 32. On an unmodified console
// the two sound pads are joined by a trace, so with AUDIO_STEREO = 0 both pins
// carry one and the same waveform -- a single pulse as long as both channels
// together -- and can never drive against each other. AUDIO_STEREO = 1 is for
// consoles modified for stereo: each pin gets its own channel, channel 0 in
// the first half of the frame and channel 1 in the second, so the two still
// add up correctly wherever they meet through open-drain buffers.
//
// CHROMA. The die's colour pad carries the colour clock itself, delayed by an
// analogue chain that the pot on pin 10 trims. The burst and hue 1 share one
// phase, each hue after that is one step later, and the pot is set so that
// hue 15 comes back round to the shade of hue 1 -- fourteen steps to a turn,
// HUE_TURN here. The delay becomes a count of half clocks through an ODDR,
// 2 * OSC_MULT slots per colour cycle, rounded to the nearest. With no colour
// to show -- hue 0, or blanking outside the burst -- the pad is released, as
// the probed die does. The die sends no burst on lines VBLANK blanks; the core
// already takes that out of `cburst`.

module tia_board #(
    parameter OSC_MULT     = 16,   // system clocks per colour clock: the PLL's ratio
    parameter PHI2_DELAY   = 2,    // clocks from PHI0 to the rebuilt PHI2, 1 or more
    parameter HUE_TURN     = 14,   // hue steps in one full turn of chroma phase
    parameter AUDIO_STEREO = 0     // 0: both sound pins carry the mix; 1: a channel each
) (
    input  wire       clk,         // OSC_MULT times the console's colour clock
    input  wire       locked,      // PLL lock; nothing runs without it

    // ---------------------------------------------- 6507 side, via U2/U3/U4
    input  wire [5:0] a,           // F_A0..F_A5
    input  wire       cs0_n,       // F_CS0_N, from A12
    input  wire       cs3_n,       // F_CS3_N, from A7
    input  wire       rw,          // F_RW, 1 = the 6507 is reading
    input  wire [7:0] d_in,        // F_D0..F_D7 as received
    output wire [7:0] d_out,
    output wire       d_oe,        // 1 = drive F_D0..F_D7
    output reg        phi0,        // F_PHI0, out through U1
    output reg        rdy,         // F_RDY, out through U1; 0 holds the 6507
    input  wire [1:0] trig,        // F_I4, F_I5

    // ----------------------- video and sound pads: 1 = released, 0 = pulled low
    output reg        csync,       // F_CSYNC
    output reg  [2:0] lum,         // F_LUM0..F_LUM2
    output reg  [1:0] col,         // F_COL in the first and second half of each clock
    output reg        aud0,        // F_AU0
    output reg        aud1         // F_AU1
);

    localparam PW = 6;             // colour clock counter width, OSC_MULT up to 32

    // ================================================================ reset
    // Out of reset a millisecond after the PLL locks, and straight back in if
    // the lock goes -- when the console is switched off, say.
    reg  [1:0] lock_s;
    reg [15:0] settle;
    reg        rst_n;
    always @(posedge clk or negedge locked) begin
        if (!locked) begin
            lock_s <= 2'b00;
            settle <= 16'd0;
            rst_n  <= 1'b0;
        end else begin
            lock_s <= {lock_s[0], 1'b1};
            if (lock_s[1] && !rst_n) begin
                settle <= settle + 16'd1;
                if (&settle) rst_n <= 1'b1;
            end
        end
    end

    // ========================================================= colour clock
    // clk0 comes straight from a flip-flop, set from the counter's next value
    // so that it still reads osc_ph < OSC_MULT / 2 on every clock. All of the
    // core's clock enables start from it, and a compare in front of that
    // fanout was the longest path in the design.
    reg  [PW-1:0] osc_ph;
    reg           clk0;
    wire [PW-1:0] osc_next = (osc_ph == OSC_MULT - 1) ? {PW{1'b0}} : osc_ph + 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            osc_ph <= {PW{1'b0}};
            clk0   <= 1'b1;
        end else begin
            osc_ph <= osc_next;
            clk0   <= (osc_next < OSC_MULT / 2);
        end
    end

    // ============================================================ bus inputs
    // Everything from the 6507 is resampled twice before the core sees it.
    // The core only acts on the bus as PHI2 falls, when it has been still for
    // hundreds of nanoseconds, so two clocks of latency cost nothing.
    reg [18:0] bus_1, bus_s;
    always @(posedge clk) begin
        bus_1 <= {trig, rw, cs3_n, cs0_n, d_in, a};
        bus_s <= bus_1;
    end
    wire [5:0] a_s    = bus_s[5:0];
    wire [1:0] trig_s = bus_s[18:17];

    // ================================================================= PHI2
    // PHI2 is needed at two different moments.
    //
    // The bus is taken while the 6507 is still in phase 2. bus_core follows
    // the pins until PHI2_DELAY clocks after PHI0 falls, then holds: on the
    // console PHI2 falls tens of nanoseconds after PHI0 and the 6507 keeps
    // address and write data valid a little longer, so this is the last
    // moment the bus is certain to be good.
    //
    // The core's CLK2 then moves on the first colour clock edge after PHI0
    // does. That is where the die sees PHI2 change: the die only acts on
    // colour clock edges, so a PHI2 edge 40 ns after one of them, as on the
    // console, reads the same as one just before the next, as in Sim2600 --
    // and the core was matched against the second. Its RESxx latch really
    // does tell the two apart, so the core must not see PHI2 early.
    wire               core_ph0;
    reg [PHI2_DELAY:0] ph0_dly;
    always @(posedge clk) ph0_dly <= {ph0_dly[PHI2_DELAY-1:0], core_ph0};
    wire phi2_early = ph0_dly[PHI2_DELAY-1];

    reg [16:0] bus_core;
    always @(posedge clk)
        if (phi2_early) bus_core <= bus_s[16:0];

    wire osc_edge = (osc_ph == OSC_MULT - 1) | (osc_ph == OSC_MULT / 2 - 1);
    reg  clk2_core;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        clk2_core <= 1'b0;
        else if (osc_edge) clk2_core <= core_ph0;
    end

    // ================================================================= core
    wire       core_rdy_low, core_sync_low, core_cburst;
    wire [2:0] core_lum;
    wire [3:0] core_col, core_au0, core_au1;
    wire [7:0] core_db;

    // No paddle circuit fits on rev A. The four paddle inputs read as they do
    // with nothing plugged in: the timing capacitor never charges.
    tia u_tia (
        .clk      (clk),
        .rst_n    (rst_n),
        .clk0     (clk0),
        .clk2     (clk2_core),
        .ph0      (core_ph0),
        .ab       (bus_core[5:0]),
        .db_in    (bus_core[13:6]),
        .db_out   (core_db),
        .db_oe    (),
        .cs0_n    (bus_core[14]),
        .cs1      (1'b1),
        .cs2_n    (1'b0),
        .cs3_n    (bus_core[15]),
        .rw       (bus_core[16]),
        .rdy_low  (core_rdy_low),
        .inpt     ({trig_s, 4'b0000}),
        .sync_low (core_sync_low),
        .lum      (core_lum),
        .col      (core_col),
        .blank    (),
        .cburst   (core_cburst),
        .au0      (core_au0),
        .au1      (core_au1)
    );

    // ============================================================= data bus
    // U2 takes its direction straight from R/W, so the FPGA drives its side
    // whenever the 6507 reads -- combinationally from the pin, so the two
    // never drive against each other for longer than a gate delay -- and U2's
    // /OE decides whether any of it reaches the console.
    //
    // The die only ever drives D7 and D6. On the console the other six keep
    // whatever the bus last carried, which for the zero-page reads games make
    // is the operand, the address's low byte. U2 drives all eight lines, so
    // this puts that value back: A5..A0 on D5..D0.
    assign d_oe  = rw;
    assign d_out = {core_db[7:6], a_s};

    // ================================================== clock and video pins
    always @(posedge clk) begin
        phi0  <= core_ph0;
        rdy   <= ~core_rdy_low;
        csync <= ~core_sync_low;
        lum   <= core_lum;
    end

    // =============================================================== chroma
    localparam [PW+1:0] SLOTS = 2 * OSC_MULT;

    // How many slots each hue lags the burst, to the nearest slot.
    function [PW:0] hue_lag;
        input [3:0] hue;
        begin
            if (hue == 4'd0)
                hue_lag = 0;
            else
                hue_lag = ((2 * (hue - 1) * SLOTS + HUE_TURN) / (2 * HUE_TURN)) % SLOTS;
        end
    endfunction

    reg        chroma_on;
    reg [PW:0] lag;
    always @(posedge clk) begin
        chroma_on <= core_cburst | (core_col != 4'd0);
        lag       <= core_cburst ? {(PW+1){1'b0}} : hue_lag(core_col);
    end

    // Where each half of this clock falls in the delayed colour cycle.
    wire [PW+1:0] s0 = {osc_ph, 1'b0} + SLOTS - lag;
    wire [PW+1:0] s1 = s0 + 1'b1;
    wire [PW+1:0] r0 = (s0 >= SLOTS) ? s0 - SLOTS : s0;
    wire [PW+1:0] r1 = (s1 >= SLOTS) ? s1 - SLOTS : s1;

    always @(posedge clk) begin
        col[0] <= ~chroma_on | (r0 < OSC_MULT);
        col[1] <= ~chroma_on | (r1 < OSC_MULT);
    end

    // ================================================================ sound
    reg [4:0] frame;
    reg [3:0] v0, v1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame <= 5'd0;
            v0    <= 4'd0;
            v1    <= 4'd0;
        end else begin
            frame <= frame + 5'd1;
            if (frame == 5'd31) begin
                v0 <= core_au0;
                v1 <= core_au1;
            end
        end
    end

    wire [4:0] mix = v0 + v1;

    always @(posedge clk) begin
        if (AUDIO_STEREO != 0) begin
            aud0 <= ~(~frame[4] & (frame[3:0] < v0));
            aud1 <= ~( frame[4] & (frame[3:0] < v1));
        end else begin
            aud0 <= ~(frame < mix);
            aud1 <= ~(frame < mix);
        end
    end

endmodule
