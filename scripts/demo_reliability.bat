@echo off
REM =============================================================================
REM demo_reliability.bat — the full fault-tolerance story, one command.
REM Run from the sage16_mem repo root:   scripts\demo_reliability.bat
REM Needs Icarus Verilog (iverilog + vvp) on PATH.
REM
REM Order tells the story:
REM   1. THE PROBLEM   - a systolic array spreads one PE fault down a column
REM   2. OUR PROPERTY  - our broadcast fabric contains it to ONE output
REM   3. THE REPAIR    - so fixing it costs ONE recompute (9 cycles), 16/16
REM   4. THE DETECTION - residue self-check catches the fault the cycle it happens
REM   5. THE SYNDROME  - flag pattern alone says WHAT broke and WHERE (26/26)
REM =============================================================================
setlocal
if not exist build mkdir build

echo.
echo ###############################################################################
echo #  STEP 1 / 5 - BASELINE (the problem): systolic array, fault ONE PE         #
echo #  watch: one fault corrupts up to a FULL COLUMN of outputs (line error)     #
echo ###############################################################################
iverilog -o build/demo_sys sim/tb_systolic_containment.v rtl/systolic_4x4_mac.v || goto :err
vvp build/demo_sys

echo.
echo ###############################################################################
echo #  STEP 2 / 5 - OURS (the property): broadcast fabric, fault ONE PE          #
echo #  watch: every fault stays in exactly ONE output - containment is           #
echo #  structural (no PE-to-PE forwarding), not added hardware                   #
echo ###############################################################################
iverilog -o build/demo_fc sim/tb_fault_containment.v rtl/pe.v rtl/sage16_4x4_mac.v rtl/sram_1rw_256x32.v rtl/mod3_reduce.v || goto :err
vvp build/demo_fc

echo.
echo ###############################################################################
echo #  STEP 3 / 5 - REPAIR (the payoff): recompute the 1 bad output on a spare   #
echo #  watch: 16/16 faults fully repaired, 9 cycles each (one inner product).    #
echo #  a systolic array would have to redo the whole corrupted column            #
echo ###############################################################################
iverilog -o build/demo_sr sim/tb_self_repair.v rtl/pe.v rtl/sage16_4x4_mac.v rtl/sram_1rw_256x32.v rtl/mod3_reduce.v || goto :err
vvp build/demo_sr

echo.
echo ###############################################################################
echo #  STEP 4 / 5 - DETECTION (runtime): mod-3 residue self-check per PE         #
echo #  watch: the fault is flagged THE CYCLE it happens - no golden model,       #
echo #  no waiting for the output. then: coverage numbers (100%% single-bit)      #
echo ###############################################################################
iverilog -o build/demo_rc sim/tb_residue_check.v rtl/pe_residue_checker.v || goto :err
vvp build/demo_rc
iverilog -o build/demo_rcov sim/tb_residue_coverage.v || goto :err
vvp build/demo_rcov

echo.
echo ###############################################################################
echo #  STEP 5 / 5 - SYNDROME (industrial): end-to-end protection, 26 fault cases #
echo #  watch: the flag PATTERN alone classifies and locates every fault -        #
echo #  single mac_err = that PE; rail_err along a row/col = that rail.           #
echo #  includes wraparound stress (end-around carry correction) and proof        #
echo #  that rail faults never cross-trip the compute check                       #
echo ###############################################################################
iverilog -o build/demo_syn sim/tb_syndrome.v rtl/pe.v rtl/sage16_4x4_mac.v rtl/sram_1rw_256x32.v rtl/mod3_reduce.v || goto :err
vvp build/demo_syn

echo.
echo ===============================================================================
echo  DEMO COMPLETE - the five results above are the paper's evidence chain:
echo    dataflow contains the fault -^> containment makes repair 1/N cost -^>
echo    residue code detects in-cycle -^> syndrome names the broken part free.
echo ===============================================================================
goto :eof

:err
echo COMPILE FAILED - is iverilog on PATH?
exit /b 1
