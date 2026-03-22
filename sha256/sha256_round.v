// =============================================================================
// File        : sha256_round.v
// Project     : SHA-256 Core for FPGA Bitcoin Miner
// Author      : Industry-Grade RTL Design
// Description : Single SHA-256 compression round (one of 64).
//               Purely combinational. Instantiated 64 times in the pipeline.
//               Inputs  : {a,b,c,d,e,f,g,h} + W[t] + K[t]
//               Outputs : {a',b',c',d',e',f',g',h'} (next state)
// Timing      : 0 flops — caller registers outputs as needed.
// =============================================================================

`include "sha256_functions.vh"

module sha256_round (
    // Current working variables
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    input  wire [31:0] c_in,
    input  wire [31:0] d_in,
    input  wire [31:0] e_in,
    input  wire [31:0] f_in,
    input  wire [31:0] g_in,
    input  wire [31:0] h_in,

    // Message schedule word for this round
    input  wire [31:0] w_in,

    // Round constant K[t]
    input  wire [31:0] k_in,

    // Next working variables
    output wire [31:0] a_out,
    output wire [31:0] b_out,
    output wire [31:0] c_out,
    output wire [31:0] d_out,
    output wire [31:0] e_out,
    output wire [31:0] f_out,
    output wire [31:0] g_out,
    output wire [31:0] h_out
);

    // -------------------------------------------------------------------------
    // T1 = h + Σ1(e) + Ch(e,f,g) + K[t] + W[t]
    // T2 = Σ0(a) + Maj(a,b,c)
    // -------------------------------------------------------------------------
    wire [31:0] t1, t2;

    assign t1 = h_in
              + `BSIG1(e_in)
              + `Ch(e_in, f_in, g_in)
              + k_in
              + w_in;

    assign t2 = `BSIG0(a_in)
              + `Maj(a_in, b_in, c_in);

    // -------------------------------------------------------------------------
    // Next-state assignments (FIPS 180-4 §6.2.2 Step 3)
    // -------------------------------------------------------------------------
    assign a_out = t1 + t2;
    assign b_out = a_in;
    assign c_out = b_in;
    assign d_out = c_in;
    assign e_out = d_in + t1;
    assign f_out = e_in;
    assign g_out = f_in;
    assign h_out = g_in;

endmodule
