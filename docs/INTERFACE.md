# SAGE-16 fabric — integration interface

This is the contract for driving the **`sage16_4x4_mac`** fabric (the top you integrate
against). It tells you every port, how to run one matrix-multiply, how to read the result,
and how to read the **fault syndrome** (the signal a host-free sequencer uses to trigger
repair). Reproduce the handshake below and the fabric does the rest.

> Lock this contract before editing shared RTL. The sequencer/controller side only needs
> to *drive these inputs* and *read these outputs* — it never edits the PE/fabric internals.

---

## 1. Module + parameters

```verilog
sage16_4x4_mac #(
    .ROWS(4), .COLS(4),      // 4x4 = 16 PEs
    .DATA_W(16),             // operand width
    .ACC_W(32),              // accumulator / output width
    .CFG_W(10),              // config word width
    .PIPELINE(1),            // registered multiplier (keep =1 for FPGA/timing)
    .SRAM_AW(8), .SRAM_DW(32)// 256x32 SRAM per PE
) u_fab ( ... );
```

PE index convention: **`IDX = row*4 + col`**, row/col ∈ 0..3. Output `IDX` ⇔ result C[row][col].

---

## 2. Port reference

### Clock / reset
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | in | 1 | clock |
| `rst_n` | in | 1 | async active-low reset |

### Configuration (what op each PE runs)
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `cfg_data` | in | 10 | config word = `{op[3:0], sel_a[2:0], sel_b[2:0]}` |
| `cfg_broadcast` | in | 1 | load `cfg_data` into **all 16 PEs** this cycle |
| `cfg_load` | in | 1 | load `cfg_data` into **one** PE (selected below) |
| `cfg_pe_row` / `cfg_pe_col` | in | 2 / 2 | which PE, when using `cfg_load` |

`op` for matmul/conv = **`4'd9` (OP_MACB**, unsigned MAC). `sel_a/sel_b = 0` for streaming.
So matmul config word = `{4'd9, 3'd0, 3'd0}`.

### Compute control
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clr_acc_all` | in | 1 | zero every PE's accumulator (start a fresh result) |
| `out_en_all` | in | 1 | step the MACs (latch a result this cycle) |

### Operand inputs — the broadcast rails (matmul/conv path)
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `ext_in_west` | in | 4×16 | A operands, one per **row** (`[r*16 +: 16]` feeds row r) |
| `ext_in_north` | in | 4×16 | B operands, one per **column** (`[c*16 +: 16]` feeds col c) |
| `per_pe_bypass_en`, `per_pe_bypass_flat` | in | 1, 16×16 | optional per-PE A override; tie 0 / 0 for normal matmul |

### Operand inputs — from per-PE SRAM (host-free path, optional)
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `sel_src_a_flat` / `sel_src_b_flat` | in | 16 / 16 | per PE: 0 = take operand from rail, 1 = from SRAM |
| `sram_cs_n_flat` | in | 16 | SRAM chip-select per PE (active-low) |
| `sram_we_n_flat` | in | 16 | SRAM write-enable per PE (active-low) |
| `sram_addr_flat` | in | 16×8 | SRAM port-A address per PE (write / verify) |
| `sram_raddr2_flat` | in | 16×8 | SRAM port-B address per PE (operand read) |
| `sram_wdata_sel` | in | 16 | 0 = write the PE accumulator back; 1 = write `sram_wdata_ext` |
| `sram_wdata_ext_flat` | in | 16×32 | external write data per PE |
| `sram_rdata_flat` | out | 16×32 | SRAM port-A read data per PE (observe / verify) |

> For a pure rail-fed matmul you can tie **all** SRAM inputs off (`cs_n=1`, `sel_src=0`,
> addresses 0). Use SRAM only when you want operands to live on-chip (the host-free mode).

### Fault injection — **experiments only, tie to 0 in the real system**
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `fault_en_flat` | in | 16 | force a permanent PE fault (per PE) |
| `fault_xor` | in | 32 | bits XOR'd into the faulted PE's result |
| `rail_fault_w_en` / `rail_fault_n_en` | in | 4 / 4 | force a rail (wire) fault |
| `rail_fault_xor` | in | 16 | bits XOR'd onto the faulted rail |

### Outputs — results
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `all_pe_out` | out | 16×32 | every PE's output. `all_pe_out[(r*4+c)*32 +: 32]` = C[r][c] |
| `ext_out_east` | out | 4×32 | the rightmost column's outputs (mesh edge) |

### Outputs — the fault SYNDROME (the repair trigger)
| Port | Dir | Width | Meaning |
|---|---|---|---|
| `mac_err_flat` | out | 16 | **compute** fault: bit `IDX` set ⇒ PE `IDX`'s arithmetic is wrong |
| `rail_err_w_flat` | out | 16 | **transport** fault on a west (A) rail (fires at every tap it feeds) |
| `rail_err_n_flat` | out | 16 | **transport** fault on a north (B) rail |

---

## 3. How to run one 4×4 matrix-multiply (the handshake)

```
 cycle:   C0        C1        T0    T1    T2    T3    D0  D1  D2
 cfg_bcast ‾‾|___________________________________________________
 cfg_data  =MACB|----------------------------------------(don't care)
 clr_acc   ‾‾|___________________________________________________
 out_en    ___|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|______
 west[r]   ...| A[r][0] A[r][1] A[r][2] A[r][3]| 0  ...
 north[c]  ...| B[0][c] B[1][c] B[2][c] B[3][c]| 0  ...
                                              ^results valid after D2 (3 drain cy)
```

Step by step:
1. **C0 (config):** `cfg_broadcast=1`, `cfg_data={4'd9,3'd0,3'd0}` (MACB), `clr_acc_all=1`, `out_en_all=0`. Loads the op into all PEs and zeros accumulators.
2. **C1 (go):** `cfg_broadcast=0`, `clr_acc_all=0`, `out_en_all=1`.
3. **T0..T3 (4 taps):** each cycle drive the rails: `west[r] = A[r][t]`, `north[c] = B[t][c]`.
4. **D0..D2 (drain):** rails = 0, keep `out_en_all=1` for 3 cycles (the `PIPELINE=1` multiply latency).
5. Drop `out_en_all=0`. **`all_pe_out` now holds C** (read `[(r*4+c)*32 +: 32]`).

Throughput: one 4×4 matmul ≈ **9 cycles** (1 cfg + 1 go + 4 taps + 3 drain). Conv and
quaternion modes use the same handshake with a different `op` and tap schedule — see
`sim/tb_conv.v` and `sim/tb_quat.v` for exact sequences.

---

## 4. Reading the syndrome (the host-free repair trigger)

The flags are **registered (one cycle later than the result)**, so capture them **sticky**
(OR them across the whole run window) — exactly like `sim/tb_syndrome.v` does. Then decode:

| What you observe | What it means | What the sequencer should do |
|---|---|---|
| no flags | healthy | continue |
| `mac_err_flat` set at exactly one bit `k` | PE `k`'s compute is faulty | recompute output `k` on a spare PE (≈9 cy), or correct via erasure-ABFT |
| `rail_err_w_flat` set across a whole **row** | that row's A-rail (wire) is faulty | remap that row's work to a healthy rail |
| `rail_err_n_flat` set down a whole **column** | that column's B-rail is faulty | remap that column's work |

Key property you can rely on: **compute and transport faults are disjoint** — a rail fault
never trips `mac_err` (the PE computed correctly on bad data), so the flag *type* already
classifies the fault and the flag *pattern/index* locates it. No diagnosis logic needed.

The erasure-ABFT correction path (`abft_checksum.v` + `abft_locate.v`) consumes the same
`mac_err` index to fix a faulted output with one subtraction — wire those in if the
sequencer wants correction instead of recompute-on-spare.

---

## 5. Minimal tie-offs (rail-fed matmul, no SRAM, no fault injection)

```verilog
.per_pe_bypass_en(1'b0), .per_pe_bypass_flat(256'b0),
.sram_cs_n_flat(16'hFFFF), .sram_we_n_flat(16'hFFFF),
.sram_addr_flat(128'b0), .sram_raddr2_flat(128'b0),
.sram_wdata_sel(16'b0), .sram_wdata_ext_flat(512'b0),
.sel_src_a_flat(16'b0), .sel_src_b_flat(16'b0),
.fault_en_flat(16'b0), .fault_xor(32'b0),
.rail_fault_w_en(4'b0), .rail_fault_n_en(4'b0), .rail_fault_xor(16'b0),
```

---

## 6. Verify any change you make

```
iverilog -o build/x sim/tb_matmul.v rtl/*.v && vvp build/x   # functional (304 checks)
iverilog -o build/s sim/tb_syndrome.v rtl/pe.v rtl/sage16_4x4_mac.v \
         rtl/sram_1rw_256x32.v rtl/mod3_reduce.v && vvp build/s   # syndrome (26/26)
```
All testbenches in `sim/` should stay green. `scripts/demo_reliability.bat` runs the full
reliability evidence chain in one go.
