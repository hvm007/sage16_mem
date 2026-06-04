## =============================================================================
## constraints/basys3.xdc  —  Digilent Basys 3 (Artix-7 XC7A35T-1CPG236C)
##
## Minimal pin/clock mapping for sage16_mem_top BIST-only bring-up.
## Compute-mode passthrough pins are NOT exposed on board pins by default
## (too many for Basys 3 directly) — those go through a UART/MMIO shell
## once that's wired.  This XDC is enough for the "blink + BIST works" demo:
##   - clk     <- W5 (100 MHz on-board oscillator)
##   - rst_n   <- BTNC (U18) inverted (active-low in design, active-high BTN)
##   - mode    <- SW0 (V17)         (0 = BIST, 1 = compute placeholder)
##   - bist_start <- BTNL (W19)
##   - bist_busy  -> LED0 (U16)
##   - bist_done  -> LED1 (E19)
##   - bist_pass  -> LED2 (U19)
##   - pe_pass_mask[3:0] -> LED3..LED6 (V19, W18, U15, U14)  (low 4 bits visible)
## =============================================================================

## --- Clock ---
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## --- Reset (BTNC, active-high on board; design wants active-low) ---
## Use an inverter or just connect BTNU here and invert externally.
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports rst_n]

## --- Mode select (SW0) ---
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports mode]

## --- BIST start (BTNL) ---
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports bist_start]

## --- LEDs (BIST status + low 4 bits of pass mask) ---
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports bist_busy]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports bist_done]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports bist_pass]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {pe_pass_mask[0]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {pe_pass_mask[1]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {pe_pass_mask[2]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {pe_pass_mask[3]}]

## All other ports on sage16_mem_top (compute-mode pins) are not assigned —
## Vivado will drop them in board mode if `unused` is set, or you can write
## a thin wrapper (sage16_mem_top_basys3.v) that ties them off.
