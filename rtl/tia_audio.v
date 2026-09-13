// tia_audio.v -- one of the two sound channels.
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// STATUS: this is the least verified block in the core. Andrew Towers' notes
// stop short of the audio circuits ("The sound generator has a more complex
// design involving another polynomial counter or two - I haven't delved into
// the workings of this one yet"), so what follows is built from the published
// AUDC mode table rather than read off sheet 4 of the schematics. It produces
// the right waveform for each mode, but the phase relationships between the
// polynomial counters have not yet been checked against the die. Compare the
// AU0/AU1 pads against Sim2600 before trusting it.
//
// Structure: a divide-by-(AUDF+1) prescaler running at the ~31 kHz audio
// clock, a 4-bit and a 5-bit polynomial counter, a 9-bit counter formed by
// chaining them, a divide-by-3 for the /6 family, and an output flip-flop for
// the pure tone modes. The output bit gates the 4-bit volume into the pad's
// weighted resistor network.
//
//   AUDC  output
//   0,B   constant (silence)
//   1     4-bit poly
//   2     div31 clocking the 4-bit poly
//   3     5-bit poly clocking the 4-bit poly
//   4,5   divide by 2
//   6,A   div31
//   7,F   5-bit poly
//   8     9-bit poly (white noise)
//   9     5-bit poly
//   C,D   divide by 6
//   E     div93

module tia_audio (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       aud_ck,        // two pulses per scanline, 114 CLK apart

    input  wire [3:0] audc,
    input  wire [4:0] audf,
    input  wire [3:0] audv,

    output wire [3:0] out            // volume taps, zero when the tone is low
);

    // ---------------------------------------------------------- prescaler
    reg [4:0] fcnt;
    wire      f_en = aud_ck & (fcnt == audf);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       fcnt <= 5'd0;
        else if (aud_ck)  fcnt <= f_en ? 5'd0 : fcnt + 5'd1;
    end

    // The /6 family runs the whole chain three times slower.
    reg [1:0] d3;
    wire      d3_en = f_en & (d3 == 2'd2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     d3 <= 2'd0;
        else if (f_en)  d3 <= (d3 == 2'd2) ? 2'd0 : d3 + 2'd1;
    end

    wire div6_mode = (audc[3:2] == 2'b11);
    wire tick      = div6_mode ? d3_en : f_en;

    // ------------------------------------------------- polynomial counters
    // XNOR feedback, shifting right, in the same style as every other counter
    // in the chip.
    reg [4:0] p5;
    reg [3:0] p4;
    reg [8:0] p9;

    wire p5_fb = ~(p5[0] ^ p5[2]);
    wire p4_fb = ~(p4[0] ^ p4[1]);
    wire p9_fb = ~(p9[0] ^ p9[4]);

    // What clocks the 4-bit counter, for the modes that chain them.
    wire use_div31 = (audc[1:0] == 2'b10);
    wire use_p5    = (audc[1:0] == 2'b11);

    wire p4_en = use_div31 ? (tick & p5[0]) :
                 use_p5    ? (tick & p5[0]) : tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p5 <= 5'h1F;
            p4 <= 4'hF;
            p9 <= 9'h1FF;
        end else begin
            if (tick)  p5 <= { p5_fb, p5[4:1] };
            if (p4_en) p4 <= { p4_fb, p4[3:1] };
            if (tick)  p9 <= { p9_fb, p9[8:1] };
        end
    end

    // ------------------------------------------------------ output select
    reg toneff;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    toneff <= 1'b0;
        else if (tick) toneff <= ~toneff;
    end

    reg tone;
    always @(*) begin
        case (audc)
            4'h0, 4'hB: tone = 1'b1;             // constant, no sound
            4'h1:       tone = p4[0];
            4'h2:       tone = p4[0];
            4'h3:       tone = p4[0];
            4'h4, 4'h5: tone = toneff;
            4'h6, 4'hA: tone = p5[0];
            4'h7:       tone = p5[0];
            4'h8:       tone = p9[0];
            4'h9:       tone = p5[0];
            4'hC, 4'hD: tone = toneff;
            4'hE:       tone = p5[0];
            4'hF:       tone = p5[0];
            default:    tone = 1'b1;
        endcase
    end

    // AUDC 0 and B hold the output bit high, so the pad sits at the AUDV
    // level: a DC offset, not silence. The die does exactly that.
    assign out = tone ? audv : 4'd0;

endmodule
