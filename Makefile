# ==============================================================================
# Makefile     TMEPT CPU — Tang Nano 9K build system
# ==============================================================================
#
# Targets
#   make all         Assemble default ROM then build bitstream (synth + pnr + fs)
#   make rom         Assemble src/main.asm → rom_init.hex
#   make synth       Synthesise with Yosys  → tmept.json
#   make pnr         Place & route          → tmept_pnr.json
#   make fs          Pack bitstream         → tmept.fs
#   make load        Flash bitstream to board via openFPGALoader
#   make sim         Run iverilog simulation
#   make clean       Remove all build artefacts
#
# Prerequisites (open-source toolchain)
#   yosys              https://github.com/YosysHQ/yosys
#   nextpnr-himbaechel https://github.com/YosysHQ/nextpnr  (with Gowin backend)
#   gowin_pack         https://github.com/YosysHQ/apicula
#   openFPGALoader     https://github.com/trabucayre/openFPGALoader
#   iverilog           https://github.com/steveicarus/iverilog  (for sim)
#   python3            for the assembler (tools/tmept_asm.py)
#
# Submodules
#   git submodule update --init --recursive
#   Expects: 6551-ACIA/  and  6522-VIA/  in the repo root.
#
# Override ROM source on the command line:
#   make rom src=src/myprogram.asm
# ==============================================================================

PROJ      = tmept
BOARD     = tangnano9k
DEVICE    = GW1NR-LV9QN88PC6/I5
FAMILY    = GW1N-9C
CST       = tangnano9k.cst

TOP       = top
TOPFILE   = rtl/top.v

# ── RTL sources ───────────────────────────────────────────────────────────────
# TMEPT CPU core
RTL_FILES  = rtl/top.v
RTL_FILES += rtl/clock_divider.v
RTL_FILES += rtl/reset.v
RTL_FILES += rtl/cpu.v
RTL_FILES += rtl/fetch.v
RTL_FILES += rtl/execute.v
RTL_FILES += rtl/decode.v
RTL_FILES += rtl/alu.v
RTL_FILES += rtl/alu_arith.v
RTL_FILES += rtl/alu_shift.v
RTL_FILES += rtl/alu_bitmanip.v
RTL_FILES += rtl/reg_file.v
RTL_FILES += rtl/rom.v
RTL_FILES += rtl/ram.v

# 6551 ACIA submodule
RTL_FILES += 6551-ACIA/rtl/acia.v
RTL_FILES += 6551-ACIA/rtl/acia_rx.v
RTL_FILES += 6551-ACIA/rtl/acia_tx.v
RTL_FILES += 6551-ACIA/rtl/acia_brgen.v

# 6522 VIA submodule
RTL_FILES += 6522-VIA/rtl/via.v

# Default ROM source
src     = src/main.asm
ASM     = python3 tools/tmept_asm.py
ROM_BIN = rom_init.hex

# Simulation testbench
TB = tb/cpu_tb.v

# ==============================================================================

.PHONY: all rom synth pnr fs load sim clean

all: rom $(PROJ).fs

# ── Submodule check ───────────────────────────────────────────────────────────
6551-ACIA/rtl/acia.v 6522-VIA/rtl/via.v:
	@echo "ERROR: Git submodules not initialised."
	@echo "Run: git submodule update --init --recursive"
	@exit 1

# ── ROM assembly ──────────────────────────────────────────────────────────────
rom: $(ROM_BIN)

$(ROM_BIN): $(src)
	$(ASM) $(src) -o $(ROM_BIN) -l $(patsubst %.asm,%.lst,$(src))

# ── Synthesis ─────────────────────────────────────────────────────────────────
$(PROJ).json: $(RTL_FILES) $(ROM_BIN)
	yosys -p "read_verilog $(RTL_FILES); \
	          synth_gowin -top $(TOP) -json $(PROJ).json"

synth: $(PROJ).json

# ── Place & Route ─────────────────────────────────────────────────────────────
$(PROJ)_pnr.json: $(PROJ).json
	nextpnr-himbaechel \
		--json      $(PROJ).json \
		--write     $(PROJ)_pnr.json \
		--device    $(DEVICE) \
		--vopt      family=$(FAMILY) \
		--vopt      cst=$(CST)

pnr: $(PROJ)_pnr.json

# ── Bitstream pack ────────────────────────────────────────────────────────────
$(PROJ).fs: $(PROJ)_pnr.json
	gowin_pack -d $(FAMILY) -o $(PROJ).fs $(PROJ)_pnr.json

fs: $(PROJ).fs

# ── Load onto board ───────────────────────────────────────────────────────────
load: $(PROJ).fs
	openFPGALoader -b $(BOARD) $(PROJ).fs

# ── Simulation ────────────────────────────────────────────────────────────────
sim:
	iverilog -g2012 -o sim.vvp $(TB) && vvp sim.vvp

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f $(PROJ).json $(PROJ)_pnr.json $(PROJ).fs sim.vvp
	rm -f $(ROM_BIN)
	rm -f src/*.lst
	rm -f *.vcd