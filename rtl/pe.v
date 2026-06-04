// =============================================================================
// pe.v  — Processing Element  (sage16_mem v2: external SRAM port)
//
// Compared to srip_v2 (which kept a 4-word flop register file inside the PE),
// this version exposes a SRAM port and lets the fabric pair each PE with an
// external 256x32 1RW SRAM macro. This matches ASIC reality (SRAM macros
// are hard blocks floor-planned separately from standard-cell logic) and
// scales the per-PE memory from 4 to 256 words.
//
// Timing contract for SRAM-sourced operands:
//   cycle N   : controller asserts cs_n=0, we_n=1, addr=A on the paired SRAM
//   cycle N+1 : sram_rdata is valid (registered output of SRAM)
//   cycle N+1 : sel_src_a/b=1 routes sram_rdata into the multiplier
//   cycle N+1 : MAC executes; cycle N+2 acc latches
//
// SRAM write source: always the PE's accumulator output `out`. The controller
// drives we_n=0 in the cycle AFTER the MAC that produced `out` (gives one
// extra cycle for the value to settle on the wdata bus).
//
// Truncation contract: SRAM slots are 32b; multiplier operands are 16b. When
// reading SRAM back as an operand, the lower DATA_W bits are used. Callers
// must ensure stored values fit in 16b if they will be reused as operands.
// =============================================================================
`default_nettype none

module pe #(
    parameter DATA_W   = 16,
    parameter ACC_W    = 32,
    parameter CFG_W    = 10,
    parameter PIPELINE = 1
)(
    input  wire                  clk, rst_n,
    input  wire                  cfg_load,
    input  wire [CFG_W-1:0]      cfg_in,
    input  wire                  out_en,
    input  wire                  clr_acc,
    input  wire [DATA_W-1:0]     in_north, in_south, in_east, in_west,
    input  wire [ACC_W-1:0]      in_self,
    input  wire [DATA_W-1:0]     in_bypass,
    input  wire [DATA_W-1:0]     in_b_col,
    // --- external SRAM operand source ---
    input  wire [ACC_W-1:0]      sram_rdata,    // from paired SRAM (1-cycle delayed)
    input  wire                  sel_src_a,     // 0 = in_bypass, 1 = sram_rdata[DATA_W-1:0]
    input  wire                  sel_src_b,     // 0 = in_b_col,  1 = sram_rdata[DATA_W-1:0]
    // --- outputs ---
    output wire [DATA_W-1:0]     out_mesh,
    output reg  [ACC_W-1:0]      out
);
    localparam OP_ADD   =4'd0,  OP_SUB  =4'd1,  OP_MUL  =4'd2, OP_AND =4'd3,
               OP_OR    =4'd4,  OP_XOR  =4'd5,  OP_PASS =4'd6, OP_MUX =4'd7,
               OP_MAC   =4'd8,
               OP_MACB  =4'd9,
               OP_MACB_S=4'd10;

    localparam SEL_N=3'd0, SEL_S=3'd1, SEL_E=3'd2, SEL_W=3'd3, SEL_SELF=3'd4;

    // ------------- config register -------------
    reg [CFG_W-1:0] cfg_reg;
    wire [3:0] op    = cfg_reg[9:6];
    wire [2:0] sel_a = cfg_reg[5:3];
    wire [2:0] sel_b = cfg_reg[2:0];

    always @(posedge clk or negedge rst_n)
        if (!rst_n)        cfg_reg <= 0;
        else if (cfg_load) cfg_reg <= cfg_in;

    // ------------- mesh-operand mux -------------
    function [DATA_W-1:0] mux_in;
        input [2:0] s;
        input [DATA_W-1:0] n, so, e, w, sf;
        case (s)
            SEL_N:    mux_in = n;
            SEL_S:    mux_in = so;
            SEL_E:    mux_in = e;
            SEL_W:    mux_in = w;
            SEL_SELF: mux_in = sf;
            default:  mux_in = 0;
        endcase
    endfunction

    wire [DATA_W-1:0] opa = mux_in(sel_a, in_north, in_south, in_east, in_west,
                                   in_self[DATA_W-1:0]);
    wire [DATA_W-1:0] opb = mux_in(sel_b, in_north, in_south, in_east, in_west,
                                   in_self[DATA_W-1:0]);

    // ------------- operand source mux (external SRAM vs broadcast) -------------
    wire [DATA_W-1:0] mul_a_src = sel_src_a ? sram_rdata[DATA_W-1:0] : in_bypass;
    wire [DATA_W-1:0] mul_b_src = sel_src_b ? sram_rdata[DATA_W-1:0] : in_b_col;

    // ------------- unified signed/unsigned multiplier -------------
    wire       use_macb    = (op == OP_MACB) | (op == OP_MACB_S);
    wire       signed_mode = (op == OP_MACB_S);

    wire [DATA_W-1:0] mul_a_raw = use_macb ? mul_a_src : opa;
    wire [DATA_W-1:0] mul_b_raw = use_macb ? mul_b_src : opb;

    wire sext_a = signed_mode & mul_a_raw[DATA_W-1];
    wire sext_b = signed_mode & mul_b_raw[DATA_W-1];
    wire signed [DATA_W:0] mul_a_ext = {sext_a, mul_a_raw};
    wire signed [DATA_W:0] mul_b_ext = {sext_b, mul_b_raw};

    (* use_dsp = "yes" *) reg signed [DATA_W:0] mul_a_q, mul_b_q;
    always @(posedge clk) begin
        mul_a_q <= mul_a_ext;
        mul_b_q <= mul_b_ext;
    end

    wire signed [DATA_W:0] mul_a_eff = PIPELINE ? mul_a_q : mul_a_ext;
    wire signed [DATA_W:0] mul_b_eff = PIPELINE ? mul_b_q : mul_b_ext;

    wire signed [2*DATA_W+1:0] mul_prod_d = mul_a_eff * mul_b_eff;

    (* use_dsp = "yes" *) reg signed [2*DATA_W+1:0] mul_prod_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mul_prod_q <= 0;
        else        mul_prod_q <= mul_prod_d;

    wire signed [2*DATA_W+1:0] mul_prod_eff = PIPELINE ? mul_prod_q : mul_prod_d;
    wire [ACC_W-1:0] mul_prod_unsigned = mul_prod_eff[ACC_W-1:0];

    // ------------- ALU -------------
    reg [ACC_W-1:0] alu_out;
    localparam EXT_W = ACC_W - DATA_W;

    always @(*) begin
        case (op)
            OP_ADD:    alu_out = { {EXT_W{1'b0}}, (opa + opb) };
            OP_SUB:    alu_out = { {EXT_W{1'b0}}, (opa - opb) };
            OP_MUL:    alu_out = mul_prod_unsigned;
            OP_AND:    alu_out = { {EXT_W{1'b0}}, (opa & opb) };
            OP_OR:     alu_out = { {EXT_W{1'b0}}, (opa | opb) };
            OP_XOR:    alu_out = { {EXT_W{1'b0}}, (opa ^ opb) };
            OP_PASS:   alu_out = { {EXT_W{1'b0}}, opa };
            OP_MUX:    alu_out = { {EXT_W{1'b0}}, (opa[0] ? opb : opa) };
            OP_MAC:    alu_out = mul_prod_unsigned + in_self;
            OP_MACB:   alu_out = mul_prod_unsigned + in_self;
            OP_MACB_S: alu_out = $signed(mul_prod_eff) + $signed(in_self);
            default:   alu_out = 0;
        endcase
    end

    // ------------- accumulator register -------------
    always @(posedge clk or negedge rst_n)
        if (!rst_n)       out <= 0;
        else if (clr_acc) out <= 0;
        else if (out_en)  out <= alu_out;

    assign out_mesh = out[DATA_W-1:0];
endmodule

`default_nettype wire
