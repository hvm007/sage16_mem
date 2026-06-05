# sage16_mem

v2 of the SAGE-16 edge accelerator: a 4×4 (16-PE) broadcast/output-stationary
MAC fabric extended with **per-PE local SRAM** and a **built-in self-test (BIST)**
controller. Each processing element is paired with its own 256×32 (1 KB) single-port
SRAM; a March-style BIST verifies all 16 memories on-chip.

Builds on SAGE-16 v1 (shared MAC fabric: matmul / 3×3 conv / quaternion). v1 kernels
remain functional (SRAM ports tied off) — backward compatible.

## Layout
```
rtl/
  pe.v                  Processing element (adds external-SRAM operand port)
  sage16_4x4_mac.v      4×4 fabric: 16 PEs each paired with a 256×32 SRAM
  sram_1rw_256x32.v     256×32 1RW SRAM — sim / FPGA-BRAM / ASIC-macro backends (ifdef)
  sram_bist_ctrl.v      March-style BIST over all 16 SRAMs
  sage16_mem_top.v      Top: BIST + fabric + mode mux (BIST vs host)
  matmul/conv3x3/quat_sage16.v, sage16_top.v   v1 kernels (SRAM tied off)
sim/                    Icarus-Verilog testbenches
  tb_sram_unit.v        SRAM behavioral model (260 checks)
  tb_pe_sram.v          PE + SRAM datapath (write→read→MAC→writeback)
  tb_sram_bist.v        Full BIST over all 16 SRAMs (~2053 cycles)
  tb_matmul/conv/quat/reconfig*  v1 regression (backward-compat, 1168 checks)
flow/fpga/              Vivado synth TCL + Basys 3 (Artix-7) constraints
constraints/            basys3.xdc
```

## Quick sim (Icarus Verilog)
```bash
iverilog -o build/tb_sram_bist sim/tb_sram_bist.v rtl/sram_1rw_256x32.v \
         rtl/pe.v rtl/sage16_4x4_mac.v rtl/sram_bist_ctrl.v rtl/sage16_mem_top.v
vvp build/tb_sram_bist
```

## Status
Simulation-verified (sim backend). FPGA + ASIC flows scripted, not yet run.
