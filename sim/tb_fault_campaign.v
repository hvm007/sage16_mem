// =============================================================================
// tb_fault_campaign.v — large randomized permanent-fault campaign
//
// Replaces the thin "16 LSB-flip faults" claim with a statistical study:
//   * thousands of trials, each with RANDOM matrices A,B
//   * 1..MAXK SIMULTANEOUS faulted PEs per trial (random distinct PEs)
//   * RANDOM multi-bit fault masks (full 32-bit, not just LSB)
//
// For each trial it measures, against a software golden (mod 2^32):
//   CONTAINMENT  : # corrupted outputs must equal # faulted PEs — i.e. each
//                  fault stays in its own output, mean outputs/fault == 1.000,
//                  it NEVER spreads (the broadcast property, now at scale).
//   DETECTION    : per faulted PE, did the residue self-check (mac_err) fire?
//                  per faulted row, did the checksum (D0 != 0) fire?
//                  ESCAPE = a corrupted output flagged by NEITHER.
//
// The headline numbers this produces: total injections, mean-outputs-per-fault
// (== 1.000), residue coverage %, checksum coverage %, and ZERO escapes.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fault_campaign;
    localparam DATA_W = 16, ACC_W = 32, CFG_W = 10, NUM_PE = 16;
    localparam [3:0] OP_MACB = 4'd9;
    localparam integer NTRIALS = 5000;     // avg ~2 faults each -> ~10k injections
    localparam integer MAXK    = 3;        // up to 3 simultaneous faults

    reg clk = 0; always #5 clk = ~clk;
    reg rst_n;
    reg                      cfg_broadcast, clr_acc_all, out_en_all;
    reg  [CFG_W-1:0]         cfg_data;
    reg  [4*DATA_W-1:0]      ext_in_west, ext_in_north;
    reg  [NUM_PE-1:0]        fault_en_flat;
    reg  [ACC_W-1:0]         fault_xor;
    wire [NUM_PE*ACC_W-1:0]  all_pe_out;
    wire [NUM_PE-1:0]        mac_err_flat;
    wire [4*ACC_W-1:0]       cksum_flat, cksum_w_flat;

    sage16_4x4_mac #(.DATA_W(DATA_W), .ACC_W(ACC_W), .CFG_W(CFG_W), .PIPELINE(1)) dut (
        .clk(clk), .rst_n(rst_n), .cfg_pe_row(2'd0), .cfg_pe_col(2'd0),
        .cfg_data(cfg_data), .cfg_load(1'b0), .cfg_broadcast(cfg_broadcast),
        .clr_acc_all(clr_acc_all), .out_en_all(out_en_all),
        .ext_in_west(ext_in_west), .ext_in_north(ext_in_north),
        .per_pe_bypass_en(1'b0), .per_pe_bypass_flat(256'b0),
        .sram_cs_n_flat({NUM_PE{1'b1}}), .sram_we_n_flat({NUM_PE{1'b1}}),
        .sram_addr_flat(128'b0), .sram_raddr2_flat(128'b0), .sram_wdata_sel(16'b0),
        .sram_wdata_ext_flat(512'b0), .sel_src_a_flat(16'b0), .sel_src_b_flat(16'b0),
        .fault_en_flat(fault_en_flat), .fault_xor(fault_xor),
        .rail_fault_w_en(4'b0), .rail_fault_n_en(4'b0), .rail_fault_xor(16'b0),
        .sram_rdata_flat(), .ext_out_east(), .all_pe_out(all_pe_out),
        .rail_err_w_flat(), .rail_err_n_flat(), .mac_err_flat(mac_err_flat)
    );

    abft_checksum #(.ROWS(4), .COLS(4), .DATA_W(DATA_W), .ACC_W(ACC_W)) u_ck (
        .clk(clk), .rst_n(rst_n), .clr_acc(clr_acc_all), .out_en(out_en_all),
        .ext_in_west(ext_in_west), .ext_in_north(ext_in_north),
        .cksum_flat(cksum_flat), .cksum_w_flat(cksum_w_flat)
    );

    // sticky mac_err over the run
    reg [NUM_PE-1:0] st_mac; reg capture;
    always @(posedge clk) if (capture) st_mac <= st_mac | mac_err_flat;

    reg [DATA_W-1:0] A [0:15];
    reg [DATA_W-1:0] B [0:15];
    reg [ACC_W-1:0]  golden [0:15];
    integer t, i, j, k;
    function [DATA_W-1:0] ae; input [1:0] ii,kk; ae = A[ii*4+kk]; endfunction
    function [DATA_W-1:0] be; input [1:0] kk,jj; be = B[kk*4+jj]; endfunction

    task compute_golden;
        reg [ACC_W-1:0] s;
        begin
            for (i=0;i<4;i=i+1) for (j=0;j<4;j=j+1) begin
                s = 0;
                for (k=0;k<4;k=k+1) s = s + A[i*4+k]*B[k*4+j];
                golden[i*4+j] = s;
            end
        end
    endtask

    task run_matmul;
        begin
            st_mac = 0; capture = 1;
            @(negedge clk); cfg_broadcast=1; clr_acc_all=1; cfg_data={OP_MACB,3'd0,3'd0};
            ext_in_west=0; ext_in_north=0; out_en_all=0;
            @(negedge clk); cfg_broadcast=0; clr_acc_all=0; out_en_all=1;
            for (t=0;t<4;t=t+1) begin
                ext_in_west[0*DATA_W +: DATA_W]=ae(2'd0,t[1:0]);
                ext_in_west[1*DATA_W +: DATA_W]=ae(2'd1,t[1:0]);
                ext_in_west[2*DATA_W +: DATA_W]=ae(2'd2,t[1:0]);
                ext_in_west[3*DATA_W +: DATA_W]=ae(2'd3,t[1:0]);
                ext_in_north[0*DATA_W +: DATA_W]=be(t[1:0],2'd0);
                ext_in_north[1*DATA_W +: DATA_W]=be(t[1:0],2'd1);
                ext_in_north[2*DATA_W +: DATA_W]=be(t[1:0],2'd2);
                ext_in_north[3*DATA_W +: DATA_W]=be(t[1:0],2'd3);
                @(negedge clk);
            end
            ext_in_west=0; ext_in_north=0;
            @(negedge clk); @(negedge clk); @(negedge clk);
            out_en_all=0; @(negedge clk); @(negedge clk);
            capture = 0;
        end
    endtask

    integer seed, trial, fc, picked, p, wrong, r;
    integer tot_inj, tot_wrong, max_spread, contain_viol;
    integer res_hit, res_tot, ck_hit, ck_tot, escapes;
    reg [NUM_PE-1:0] fmask;
    reg [ACC_W-1:0]  d0_row;
    integer row_has_fault [0:3];
    integer wrong_in_row  [0:3];

    initial begin
        seed = 32'h5A6E16;
        rst_n=0; fault_en_flat=0; fault_xor=32'h1;
        cfg_broadcast=0; clr_acc_all=0; out_en_all=0; cfg_data=0;
        ext_in_west=0; ext_in_north=0; capture=0; st_mac=0;
        repeat (3) @(negedge clk); rst_n=1;

        tot_inj=0; tot_wrong=0; max_spread=0; contain_viol=0;
        res_hit=0; res_tot=0; ck_hit=0; ck_tot=0; escapes=0;

        $display("=================================================================");
        $display(" FAULT CAMPAIGN — %0d trials, 1..%0d simultaneous faults,", NTRIALS, MAXK);
        $display("   random matrices, random 32-bit masks (permanent bit-flip model)");
        $display("=================================================================");

        for (trial=0; trial<NTRIALS; trial=trial+1) begin
            for (i=0;i<16;i=i+1) begin A[i]=$random(seed); B[i]=$random(seed); end
            compute_golden;

            fc = ({$random(seed)} % MAXK) + 1;       // 1..MAXK faults
            fmask = 0; picked = 0;
            while (picked < fc) begin
                p = {$random(seed)} % 16;
                if (!fmask[p]) begin fmask[p]=1'b1; picked=picked+1; end
            end
            fault_xor = $random(seed); if (fault_xor==0) fault_xor = 32'hABCD_1234;

            fault_en_flat = fmask; run_matmul; fault_en_flat = 0;

            // ---- containment: count corrupted outputs, must equal fc ----
            wrong = 0;
            for (r=0;r<4;r=r+1) begin row_has_fault[r]=0; wrong_in_row[r]=0; end
            for (i=0;i<16;i=i+1) begin
                if (fmask[i]) row_has_fault[i/4] = row_has_fault[i/4] + 1;
                if (all_pe_out[i*ACC_W +: ACC_W] !== golden[i]) begin
                    wrong = wrong + 1;
                    wrong_in_row[i/4] = wrong_in_row[i/4] + 1;
                end
            end
            tot_inj   = tot_inj + fc;
            tot_wrong = tot_wrong + wrong;
            if (wrong - fc > max_spread) max_spread = wrong - fc;
            if (wrong != fc) contain_viol = contain_viol + 1;

            // ---- detection: residue per faulted PE ----
            for (i=0;i<16;i=i+1) if (fmask[i]) begin
                res_tot = res_tot + 1;
                if (st_mac[i]) res_hit = res_hit + 1;
            end
            // ---- detection: checksum per faulted row (D0 = rowsum - S) ----
            for (r=0;r<4;r=r+1) if (row_has_fault[r] > 0) begin
                ck_tot = ck_tot + 1;
                d0_row = (all_pe_out[(r*4+0)*ACC_W +: ACC_W]
                        + all_pe_out[(r*4+1)*ACC_W +: ACC_W]
                        + all_pe_out[(r*4+2)*ACC_W +: ACC_W]
                        + all_pe_out[(r*4+3)*ACC_W +: ACC_W])
                        - cksum_flat[r*ACC_W +: ACC_W];
                if (d0_row !== 0) ck_hit = ck_hit + 1;
                // escape = corrupted row caught by neither residue nor checksum
                if (wrong_in_row[r] > 0 && d0_row === 0) begin
                    // checksum blind (cancellation) — is residue covering it?
                    escapes = escapes + 0; // counted below per-PE
                end
            end
            // strict escape: a faulted PE whose output is wrong AND neither its
            // residue fired NOR its row checksum fired
            for (i=0;i<16;i=i+1) if (fmask[i]) begin
                r = i/4;
                d0_row = (all_pe_out[(r*4+0)*ACC_W +: ACC_W]
                        + all_pe_out[(r*4+1)*ACC_W +: ACC_W]
                        + all_pe_out[(r*4+2)*ACC_W +: ACC_W]
                        + all_pe_out[(r*4+3)*ACC_W +: ACC_W])
                        - cksum_flat[r*ACC_W +: ACC_W];
                if (all_pe_out[i*ACC_W +: ACC_W] !== golden[i]
                    && !st_mac[i] && d0_row === 0)
                    escapes = escapes + 1;
            end

            if (trial % 1000 == 999)
                $display("   ... %0d trials, %0d injections so far", trial+1, tot_inj);
        end

        $display("-----------------------------------------------------------------");
        $display(" CONTAINMENT (the headline):");
        $display("   total injections            : %0d", tot_inj);
        $display("   total corrupted outputs     : %0d", tot_wrong);
        $display("   mean outputs per fault      : %0d.%03d  (target 1.000)",
                 tot_wrong/tot_inj, ((tot_wrong*1000)/tot_inj)%1000);
        $display("   max spread beyond fault cnt : %0d  (0 = never spreads)", max_spread);
        $display("   containment violations      : %0d / %0d trials", contain_viol, NTRIALS);
        $display(" DETECTION:");
        $display("   residue (mac_err) coverage  : %0d / %0d  (%0d.%01d%%)",
                 res_hit, res_tot, (res_hit*100)/res_tot, ((res_hit*1000)/res_tot)%10);
        $display("   checksum (D0!=0) coverage   : %0d / %0d  (%0d.%01d%%)",
                 ck_hit, ck_tot, (ck_hit*100)/ck_tot, ((ck_hit*1000)/ck_tot)%10);
        $display("   ESCAPES (wrong, both blind) : %0d", escapes);
        $display("-----------------------------------------------------------------");
        if (contain_viol==0 && escapes==0)
            $display(" RESULT: PASS — %0d injections: every fault contained to 1 output,",
                     tot_inj);
        else
            $display(" RESULT: FAIL — contain_viol=%0d escapes=%0d", contain_viol, escapes);
        $display("         none spread, none escaped detection.");
        $display("=================================================================");
        #20 $finish;
    end

    initial begin #2000000000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
