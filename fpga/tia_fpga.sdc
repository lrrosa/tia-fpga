// tia-fpga -- timing constraints for Gowin EDA
//
// Copyright 2026 Leonardo Roman da Rosa
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Only the console's colour clock is constrained. The PLL's output -- 16
// times it, 57.27 MHz, by default -- is derived from it by the tool, and every
// flip-flop in the design runs on that one clock. The bus, video and sound
// pins are asynchronous to it by design: rtl/tia_board.v resamples what comes
// in and times what goes out in whole clocks, so they carry no I/O
// constraints.

create_clock -name osc -period 279.365 -waveform {0 139.683} [get_ports {F_OSC}]
