// tia_audio.v -- one of the two sound channels.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Read off the 10444D netlist that Sim2600 simulates, and checked against the
// simulated die tick by tick through the channel's own latches -- the divider,
// the enable, both polynomial counters -- not only through its pads. The
// structure is the one Stella uses, after Christian Speckner's analysis: a
// 5-bit "noise" counter and a 4-bit "pulse" counter stepped together. Where
// the die disagrees with Stella it says so below.
//
// CLOCKS. The horizontal counter gives the audio circuit two ticks a line,
// and each tick two phases: phase A closes at counts 1 and 19, phase B at
// counts 9 and 37, both on the sync latch's edge.
//
// PHASE A compares the divider with AUDF and latches the result as the
// enable for the tick. On an enabled tick it also latches what the coming
// shift needs, from the counters as they stand and AUDC as it is right then:
// the noise feedback bit, whether the pulse counter holds, and the noise bit
// the pulse counter feeds back in AUDC 8-B.
//
// PHASE B, on an enabled tick, shifts the noise counter and, unless it holds,
// the pulse counter. The pads follow the pulse counter's low bit, so this is
// where the output changes.
//
// THE DIVIDER is a 5-bit binary counter compared with AUDF, not loaded from
// it, and cleared on an enabled tick. Lower AUDF below the count and the
// counter runs on to 31 and wraps before the channel ticks again.
//
// PULSE FEEDBACK has no lockup guards on the die. Stella steers the 4-bit
// polynomial away from %1010 and the divide-by-6 away from %0000 and %0001;
// the netlist has neither term, and the simulated die does go from %0000 to
// %1111 in AUDC C. The noise counter's escapes from all zeros are there.
//
// THE CHANNELS ARE NOT IDENTICAL. In channel 0 the enable latched at phase A
// gates phase A's own latches straight away. Channel 1 passes the enable
// through one more storage stage, loaded on phase B, so its phase-A latches
// follow the enable of the tick before -- which is how Stella models both
// channels. It only shows on the first tick after the divider lets the
// channel run again with AUDC changed in the meantime. ENABLE_LATCHED selects
// channel 1's wiring. Whether real chips share the asymmetry, or it came in
// with the netlist extraction, is an open question.

module tia_audio #(
    parameter ENABLE_LATCHED = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ph_a,          // audio phase A, counts 1 and 19
    input  wire       ph_b,          // audio phase B, counts 9 and 37

    input  wire [3:0] audc,
    input  wire [4:0] audf,
    input  wire [3:0] audv,

    output wire [3:0] out            // volume taps, zero when the output bit is low
);

    reg  [4:0] div;
    reg        en;                   // this tick's enable, for phase B
    reg  [4:0] noise;
    reg  [3:0] pulse;
    reg        hold, nfb, bit4;

    wire [1:0] lo = audc[1:0];
    wire [1:0] hi = audc[3:2];

    wire en_now  = (div == audf);
    wire en_gate = ENABLE_LATCHED ? en : en_now;

    // ------------------------------------------------------------- phase A
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div  <= 5'd0;
            en   <= 1'b0;
            hold <= 1'b0;
            nfb  <= 1'b1;
            bit4 <= 1'b1;
        end else if (ph_a) begin
            if (en_gate) begin
                bit4 <= noise[0];
                case (lo)
                2'b10:   hold <= (noise[4:1] != 4'b0001);
                2'b11:   hold <= ~noise[0];
                default: hold <= 1'b0;
                endcase
                if (lo == 2'b00)
                    nfb <= (pulse[0] ^ noise[0]) | ((noise == 5'd0) & (pulse == 4'hA)) | (hi == 2'b00);
                else
                    nfb <= (noise[2] ^ noise[0]) | (noise == 5'd0);
            end
            en  <= en_now;
            div <= (en_now || div == 5'd31) ? 5'd0 : div + 5'd1;
        end
    end

    // ------------------------------------------------------------- phase B
    reg pfb;
    always @(*) begin
        if (audc == 4'h0)
            pfb = 1'b0;
        else case (hi)
            2'b00:   pfb = pulse[1] ^ pulse[0];     // 4-bit polynomial
            2'b01:   pfb = ~pulse[3];               // divide by 2
            2'b10:   pfb = ~bit4;                   // clocked by the noise counter
            default: pfb = ~pulse[1];               // divide by 6
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise <= 5'h1F;
            pulse <= 4'h5;
        end else if (ph_b && en) begin
            noise <= { nfb, noise[4:1] };
            if (!hold)
                pulse <= { pfb, ~pulse[3:1] };
        end
    end

    // AUDC 0 and B leave the output bit high, so the pad sits at the AUDV
    // level: a DC offset, not silence. The die does exactly that.
    assign out = pulse[0] ? audv : 4'd0;

endmodule
