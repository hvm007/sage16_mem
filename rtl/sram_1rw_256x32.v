// =============================================================================
// sram_1rw_256x32.v  —  256-word x 32-bit DUAL-PORT SRAM  (1RW + 1R)
//
// UPGRADED from single-port (1RW) to dual-port so a write and a read can happen
// in the SAME cycle, doubling effective R/W throughput.
//
//   PORT A (read/write)  : clk, cs_n, we_n, addr,  wdata, rdata
//                          - used by BIST + result write-back + verify reads.
//                          - identical semantics to the old single-port version
//                            (so existing controllers are unchanged).
//   PORT B (read only)    : clk, raddr2, rdata2
//                          - dedicated read port for PE operand fetches.
//                          - always reads mem[raddr2]; rdata2 valid next cycle.
//
// Concurrency: PORT A may write mem[addr] while PORT B reads mem[raddr2] in the
// same cycle. If addr == raddr2 during an A-write, PORT B returns the OLD value
// (read-first / read-old) — the standard, safe true-dual-port behaviour.
//
// (Filename keeps the old name to avoid churn; it is now a 1RW+1R macro.)
//
// Backends (compile-time):
//   `define SIM_BEHAVIORAL : pure-Verilog model (default for sim)
//   `define FPGA_BRAM      : true-dual-port BRAM-inferring style (Artix-7)
//   `define ASIC_CADENCE45 : 45nm 1RW1R memory-compiler macro instantiation
// =============================================================================
`default_nettype none

module sram_1rw_256x32 #(
    parameter ADDR_W  = 8,
    parameter DATA_W  = 32,
    parameter DEPTH   = 256,
    parameter INIT_VAL = 32'h0
)(
    input  wire              clk,
    // ---- Port A: read/write ----
    input  wire              cs_n,
    input  wire              we_n,
    input  wire [ADDR_W-1:0] addr,
    input  wire [DATA_W-1:0] wdata,
    output wire [DATA_W-1:0] rdata,
    // ---- Port B: read-only ----
    input  wire [ADDR_W-1:0] raddr2,
    output wire [DATA_W-1:0] rdata2
);

`ifdef ASIC_CADENCE45
    // ------------------------------------------------------------
    // ASIC backend: lab's 45nm 1RW1R macro. Rename to your compiler's
    // emitted wrapper. Behavioural stub below lets it simulate.
    // ------------------------------------------------------------
    cadence45_sram_256x32_1rw1r u_macro (
        .CLK (clk),
        .CENA(cs_n), .WENA(we_n), .AA(addr), .DA(wdata), .QA(rdata),
        .AB (raddr2), .QB(rdata2)
    );

`elsif FPGA_BRAM
    // ------------------------------------------------------------
    // FPGA backend: true-dual-port BRAM. Port A R/W, Port B read.
    // ------------------------------------------------------------
    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [DATA_W-1:0] rdata_r, rdata2_r;
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = INIT_VAL;
        rdata_r = 0; rdata2_r = 0;
    end
    always @(posedge clk) begin            // Port A
        if (!cs_n) begin
            if (!we_n) mem[addr] <= wdata;
            rdata_r <= mem[addr];
        end
    end
    always @(posedge clk) begin            // Port B (read)
        rdata2_r <= mem[raddr2];
    end
    assign rdata  = rdata_r;
    assign rdata2 = rdata2_r;

`else
    // ------------------------------------------------------------
    // SIM_BEHAVIORAL (default).
    // Port A: write-first on its own port (returns wdata on write).
    // Port B: read-old w.r.t. a same-cycle Port-A write (nonblocking
    //         ordering: B samples mem before A's write commits).
    // ------------------------------------------------------------
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [DATA_W-1:0] rdata_r, rdata2_r;
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = INIT_VAL;
        rdata_r = 0; rdata2_r = 0;
    end
    always @(posedge clk) begin            // Port A: read/write
        if (!cs_n) begin
            if (!we_n) mem[addr] <= wdata;
            rdata_r <= (!we_n) ? wdata : mem[addr];   // write-first on port A
        end
    end
    always @(posedge clk) begin            // Port B: read-only (read-old)
        rdata2_r <= mem[raddr2];
    end
    assign rdata  = rdata_r;
    assign rdata2 = rdata2_r;
`endif

endmodule

// ------------------------------------------------------------
// Behavioural Cadence-45 1RW1R macro stub (only when ASIC + stub define set).
// Replace by linking the real macro library from your memory compiler.
// ------------------------------------------------------------
`ifdef ASIC_CADENCE45
`ifdef MACRO_BEHAVIOURAL_STUB
module cadence45_sram_256x32_1rw1r (
    input  wire        CLK,
    input  wire        CENA, WENA,
    input  wire [7:0]  AA,
    input  wire [31:0] DA,
    output wire [31:0] QA,
    input  wire [7:0]  AB,
    output wire [31:0] QB
);
    reg [31:0] mem [0:255];
    reg [31:0] qa_r, qb_r;
    integer i; initial for (i=0;i<256;i=i+1) mem[i]=32'h0;
    always @(posedge CLK) begin
        if (!CENA) begin
            if (!WENA) mem[AA] <= DA;
            qa_r <= (!WENA) ? DA : mem[AA];
        end
        qb_r <= mem[AB];
    end
    assign QA = qa_r;
    assign QB = qb_r;
endmodule
`endif
`endif

`default_nettype wire
