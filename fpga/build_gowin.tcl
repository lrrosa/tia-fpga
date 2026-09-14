# tia-fpga -- build the rev A bitstream with Gowin EDA's command-line shell.
#
# Copyright 2026 Leonardo Roman da Rosa
# SPDX-License-Identifier: CERN-OHL-S-2.0
#
# From the repository root:
#
#     gw_sh fpga/build_gowin.tcl
#
# The bitstream lands in impl/pnr/tia_fpga.fs. Program it with Gowin's
# Programmer, or with openFPGALoader:
#
#     openFPGALoader -b tangnano9k -f impl/pnr/tia_fpga.fs
#
# Written from Gowin's gw_sh documentation but not yet run: there is no
# Gowin EDA on the machine this was written on. If synthesis cannot find
# tia_defs.vh, add rtl/ to the include path.

set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5

foreach f [lsort [glob rtl/*.v]] {
    add_file -type verilog $f
}
add_file -type verilog fpga/tia_fpga_top.v
add_file -type cst fpga/tia_fpga.cst
add_file -type sdc fpga/tia_fpga.sdc

set_option -top_module tia_fpga_top
set_option -output_base_name tia_fpga
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1

run all
