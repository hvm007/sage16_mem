@echo off
:: =============================================================================
:: flow/fpga/synth_all_fpga.bat  —  run Vivado on each top, OOC at 200 MHz
:: Run from repo root: flow\fpga\synth_all_fpga.bat
:: =============================================================================
setlocal

set TOPS=sage16_mem_top sage16_4x4_mac sram_1rw_256x32 sram_bist_ctrl
set PERIOD=5.000

for %%T in (%TOPS%) do (
    echo.
    echo ===== synth %%T  =====
    vivado -mode batch -nojournal -nolog -source flow\fpga\synth_fpga.tcl ^
           -tclargs %%T %PERIOD% ooc
    if errorlevel 1 (
        echo ERROR on %%T
        exit /b 1
    )
)

echo.
echo All tops synthesised. Reports under reports/^<top^>/
endlocal
