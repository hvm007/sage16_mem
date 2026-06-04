// =============================================================================
// sram_1rw_256x32.v  —  256-word x 32-bit single-port SRAM
//
// Three backends selected at compile time:
//   `define SIM_BEHAVIORAL  : pure-Verilog behavioural model (default for sim)
//   `define FPGA_BRAM       : single-port BRAM-inferring style (Xilinx Artix-7)
//   `define ASIC_CADENCE45  : Cadence 45nm memory-compiler macro instantiation
//
// Interface (synchronous, 1-cycle read latency):
//   clk      : positive-edge clock
//   cs_n     : chip-select, active low  (1 = no operation)
//   we_n     : write-enable, active low (0 = write, 1 = read)
//   addr     : 8-bit word address (0..255)
//   wdata    : 32-bit write data
//   rdata    : 32-bit registered read data — valid the cycle AFTER addr+cs_n=0
//
// Timing contract:
//   cycle N:    cs_n=0, we_n=1, addr=A         (issue read)
//   cycle N+1:  rdata = mem[A]                  (data available)
//
//   cycle N:    cs_n=0, we_n=0, addr=A, wdata=D (issue write)
//   cycle N+1:  mem[A] = D                      (data committed)
//
// Single-port restriction: cannot read AND write in same cycle. Controllers
// must schedule accordingly.
//
// FPGA inference notes (Xilinx):
//   Uses synchronous-read, write-first style. Vivado infers 1x BRAM18 when
//   targeting Artix-7. For Series-7 the dedicated read-data register on the
//   BRAM port absorbs the rdata reg.
//
// ASIC notes (Cadence 45nm):
//   Replace the `sky_macro_placeholder` instantiation with the actual macro
//   name your lab's memory compiler emits (e.g. NangateOpenMemory_256x32_1RW
//   or your CSI/Artisan compiler output). The placeholder module shipped
//   here is functionally equivalent so the design simulates either way.
// =============================================================================
`default_nettype none

module sram_1rw_256x32 #(
    parameter ADDR_W  = 8,
    parameter DATA_W  = 32,
    parameter DEPTH   = 256,
    parameter INIT_VAL = 32'h0          // power-on contents in sim only
)(
    input  wire              clk,
    input  wire              cs_n,
    input  wire              we_n,
    input  wire [ADDR_W-1:0] addr,
    input  wire [DATA_W-1:0] wdata,
    output wire [DATA_W-1:0] rdata
);

`ifdef ASIC_CADENCE45
    // ------------------------------------------------------------
    // ASIC backend: instantiate the lab's 45nm SRAM macro.
    // The wrapper name below is a placeholder — rename to whatever
    // your memory compiler emits (e.g. NLM45_256x32_1RW_BC).
    // ------------------------------------------------------------
    wire [DATA_W-1:0] rdata_macro;

    cadence45_sram_256x32_1rw u_macro (
        .CLK   (clk),
        .CEN   (cs_n),         // active-low chip enable
        .WEN   (we_n),         // active-low write enable
        .A     (addr),
        .D     (wdata),
        .Q     (rdata_macro)
    );
    assign rdata = rdata_macro;

`elsif FPGA_BRAM
    // ------------------------------------------------------------
    // FPGA backend: Vivado infers BRAM from this style.
    // Synchronous-read, write-first, single-port.
    // ------------------------------------------------------------
    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg  [DATA_W-1:0] rdata_r;

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = INIT_VAL;
        rdata_r = {DATA_W{1'b0}};
    end

    always @(posedge clk) begin
        if (!cs_n) begin
            if (!we_n) mem[addr] <= wdata;
            rdata_r <= mem[addr];
        end
    end
    assign rdata = rdata_r;

`else
    // ------------------------------------------------------------
    // SIM_BEHAVIORAL (default): plain array model.
    // 1-cycle synchronous read; write-first on same address.
    // ------------------------------------------------------------
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [DATA_W-1:0] rdata_r;

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = INIT_VAL;
        rdata_r = {DATA_W{1'b0}};
    end

    always @(posedge clk) begin
        if (!cs_n) begin
            if (!we_n) mem[addr] <= wdata;
            rdata_r <= (!we_n) ? wdata : mem[addr];  // write-first
        end
    end
    assign rdata = rdata_r;
`endif

endmodule

// =============================================================================
// Behavioural Cadence-45 macro stub — only compiled when ASIC_CADENCE45 set
// AND you don't link the real macro library. Lets the design simulate even
// when you don't have the real macro in your sim sources.
//
// Replace this stub by removing it from compilation when you link the actual
// macro library exported by your memory compiler / PDK.
// =============================================================================
`ifdef ASIC_CADENCE45
`ifdef MACRO_BEHAVIOURAL_STUB
module cadence45_sram_256x32_1rw (
    input  wire        CLK,
    input  wire        CEN,
    input  wire        WEN,
    input  wire [7:0]  A,
    input  wire [31:0] D,
    output wire [31:0] Q
);
    reg [31:0] mem [0:255];
    reg [31:0] q_r;
    integer i;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 32'h0;
    always @(posedge CLK) begin
        if (!CEN) begin
            if (!WEN) mem[A] <= D;
            q_r <= (!WEN) ? D : mem[A];
        end
    end
    assign Q = q_r;
endmodule
`endif
`endif

`default_nettype wire
