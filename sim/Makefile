# Copyright 2026 Leonardo Roman da Rosa
# SPDX-License-Identifier: CERN-OHL-S-2.0
#
# A convenience wrapper. run.py does the same thing and needs no make, which
# matters on Windows where the FPGA toolchain lives but make usually does not.

IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := $(wildcard ../rtl/*.v)
TRACES   := $(wildcard traces/*.trace)
BUILD    := build

.PHONY: all test lint clean

all: test

$(BUILD)/tb_trace.vvp: tb_trace.v $(RTL)
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -I ../rtl -o $@ -s tb_trace $^

$(BUILD)/tb_debug.vvp: tb_debug.v $(RTL)
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -I ../rtl -o $@ -s tb_debug $^

test: $(BUILD)/tb_trace.vvp
	@for t in $(TRACES); do \
	  echo "=== $$t ==="; \
	  $(VVP) $< +trace=$$t +first=10 || exit 1; \
	done

debug: $(BUILD)/tb_debug.vvp
	$(VVP) $< +trace=$(TRACE) +align=$(ALIGN) +from=$(FROM) +to=$(TO)

lint:
	$(IVERILOG) -g2005 -Wall -I ../rtl -o /dev/null -s tia $(RTL)

clean:
	rm -rf $(BUILD)
