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
    // --- fault injection (permanent PE-fault model; 0 = healthy) ---
    input  wire                  fault_en,      // 1 = this PE is faulty
    input  wire [ACC_W-1:0]      fault_xor,     // bits XOR'd into the result when fault_en
    // --- outputs ---
    output wire [DATA_W-1:0]     out_mesh,
    output reg  [ACC_W-1:0]      out,
    // --- runtime self-check: residue (mod-3) verification of the MAC ---
    // Fires the cycle after a corrupted accumulate. Independent re-derivation
    // from the OPERANDS, so it covers multiplier, adder and accumulator faults.
    output wire                  mac_err
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
    // Permanent-fault model: when fault_en, the PE's stored result is corrupted
    // by fault_xor every cycle it updates — models a broken MAC/accumulator.
    wire [ACC_W-1:0] alu_out_fi = fault_en ? (alu_out ^ fault_xor) : alu_out;

    always @(posedge clk or negedge rst_n)
        if (!rst_n)       out <= 0;
        else if (clr_acc) out <= 0;
        else if (out_en)  out <= alu_out_fi;

    assign out_mesh = out[DATA_W-1:0];

    // ------------- runtime residue self-check (mod-3, end-to-end) -------------
    // Predicts the residue of the next accumulator value from the OPERANDS:
    //     mod3(out_next) == mod3(mod3(a)*mod3(b) + mod3(out) - carry_out)
    // and compares against the residue of what the accumulator actually
    // latched, one cycle later. The residue pipeline mirrors the multiplier
    // pipeline stage-for-stage so the comparison is always aligned.
    //
    // End-around carry: the accumulate is mod 2^ACC_W and 2^32 == 1 (mod 3),
    // so a wraparound subtracts 1 from the true residue; we add 2 (== -1) to
    // the prediction when the 33-bit add carries out. Without this, a healthy
    // PE accumulating large values would false-alarm.
    //
    // Scope: enabled for OP_MACB (unsigned MAC, the matmul/conv workhorse).
    // Signed residue prediction (OP_MACB_S) is standard but not wired yet.

    wire [1:0] res_a_d, res_b_d, res_self, res_out;
    mod3_reduce #(.W(DATA_W)) u_m3_a   (.x(mul_a_raw), .r(res_a_d));
    mod3_reduce #(.W(DATA_W)) u_m3_b   (.x(mul_b_raw), .r(res_b_d));
    mod3_reduce #(.W(ACC_W))  u_m3_self(.x(in_self),   .r(res_self));
    mod3_reduce #(.W(ACC_W))  u_m3_out (.x(out),       .r(res_out));

    // stage 1: operand residues (aligns with mul_a_q/mul_b_q)
    reg [1:0] res_a_q, res_b_q;
    always @(posedge clk) begin
        res_a_q <= res_a_d;
        res_b_q <= res_b_d;
    end
    wire [1:0] res_a_eff = PIPELINE ? res_a_q : res_a_d;
    wire [1:0] res_b_eff = PIPELINE ? res_b_q : res_b_d;

    // stage 2: product residue (aligns with mul_prod_q)
    wire [3:0] res_prod_raw = res_a_eff * res_b_eff;       // in {0,1,2,4}
    wire [1:0] res_prod_d   = (res_prod_raw == 4'd4) ? 2'd1 :   // 4 == 1 mod 3
                              (res_prod_raw == 4'd3) ? 2'd0 :
                                                       res_prod_raw[1:0];
    reg [1:0] res_prod_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) res_prod_q <= 0;
        else        res_prod_q <= res_prod_d;
    wire [1:0] res_prod_eff = PIPELINE ? res_prod_q : res_prod_d;

    // stage 3: predicted accumulator residue, with end-around carry correction
    wire [ACC_W:0] acc_sum33 = {1'b0, mul_prod_unsigned} + {1'b0, in_self};
    wire [3:0] res_pred_raw  = {2'b00, res_prod_eff} + {2'b00, res_self}
                             + (acc_sum33[ACC_W] ? 4'd2 : 4'd0);   // -1 == +2 mod 3
    mod3_reduce #(.W(4)) u_m3_pred (.x(res_pred_raw), .r(res_pred_d_w));
    wire [1:0] res_pred_d_w;

    reg  [1:0] res_pred_q;
    reg        chk_vld_q;
    wire       chk_arm = out_en & ~clr_acc & (op == OP_MACB);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            res_pred_q <= 0;
            chk_vld_q  <= 1'b0;
        end else begin
            res_pred_q <= res_pred_d_w;
            chk_vld_q  <= chk_arm;
        end

    // stage 4: register the accumulator's residue so the long mod-3-of-32-bit
    // path becomes reg-to-reg (out -> mod3 -> res_out_q), and delay the
    // prediction one more cycle to stay aligned. Detection is then one cycle
    // later — harmless for a checker (the syndrome is captured sticky). This
    // removes the residue check from the per-cycle critical path with no Fmax
    // penalty. PIPELINE=1 uses the registered compare; PIPELINE=0 (combinational
    // multiplier path) keeps the original single-cycle compare.
    reg [1:0] res_out_q, res_pred_q2;
    reg       chk_vld_q2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin res_out_q <= 0; res_pred_q2 <= 0; chk_vld_q2 <= 0; end
        else begin
            res_out_q   <= res_out;
            res_pred_q2 <= res_pred_q;
            chk_vld_q2  <= chk_vld_q;
        end

    assign mac_err = PIPELINE ? (chk_vld_q2 & (res_out_q != res_pred_q2))
                              : (chk_vld_q  & (res_out   != res_pred_q));
endmodule

`default_nettype wire
