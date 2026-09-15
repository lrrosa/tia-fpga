# tia-fpga -- build the bitstream with Gowin EDA's command-line shell.
#
# Copyright 2026 Leonardo Roman da Rosa
# SPDX-License-Identifier: CERN-OHL-S-2.0
#
# Gowin's place and route will not write into a directory whose path has a
# space in it. The build goes into impl/ under the current directory, and the
# sources are found from this script's own location, so run it from any
# directory without spaces and give it the script's full path:
#
#     cd C:\build\tia-fpga
#     gw_sh "F:\path with spaces\tia-fpga\fpga\build_gowin.tcl"
#
# From the repository root works as well, if that path has no spaces:
#
#     gw_sh fpga/build_gowin.tcl
#
# The bitstream lands in impl/pnr/tia_fpga.fs. Program it with Gowin's
# Programmer, or with openFPGALoader:
#
#     openFPGALoader -b tangnano9k -f impl/pnr/tia_fpga.fs
#
# Checked with Gowin EDA V1.9.11.03 Education: no setup or hold violations at
# the slow corner, 60.4 MHz Fmax against the 57.27 MHz clock. When the sources'
# own path has spaces in it, place and route prints two CM1010 "Unknown option
# '-'" warnings, from how its command line is built; the constraint files are
# still read whole, and from a path without spaces there are no warnings.

set root [file normalize [file join [file dirname [info script]] ..]]

set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5

foreach f [lsort [glob -directory [file join $root rtl] *.v]] {
    add_file -type verilog $f
}
add_file -type verilog [file join $root fpga tia_fpga_top.v]
add_file -type cst [file join $root fpga tia_fpga.cst]
add_file -type sdc [file join $root fpga tia_fpga.sdc]

set_option -top_module tia_fpga_top
set_option -output_base_name tia_fpga
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1

# The console's 6507 leaves reset 17 to 58 ms after power-up, depending on the
# board, and PHI0 has to be running before then. At Gowin's default 2.5 MHz
# the GW1NR-9 takes about 100 ms to load this bitstream from its flash; 250/8
# (31.25 MHz, the fastest the device allows in Autoboot) takes about 8.
set_option -loading_rate 250/8

run all
