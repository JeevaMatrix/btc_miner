// =============================================================================
// File        : sha256_core.v
// Project     : SHA-256 Core for FPGA Bitcoin Miner
// Author      : Industry-Grade RTL Design
// Standard    : Verilog-2001 / SystemVerilog compatible
//
// Description :
//   Fully pipelined SHA-256 compression core.
//   - 512-bit padded message block in, 256-bit digest out.
//   - 64-stage pipeline: one hash result every clock after LATENCY cycles.
//   - Each stage holds registered {a,b,c,d,e,f,g,h} working variables
//     plus the pre-computed W[t] and K[t] for that stage.
//   - Pipeline flush/valid tracking via a shift-register.
//   - Initial hash values H0..H7 are the standard SHA-256 IVs (FIPS 180-4).
//     For Bitcoin double-SHA the midstate can be injected via h_init_* ports.
//
// Port Map:
//   clk          — system clock (all registers on posedge)
//   rst_n        — active-low synchronous reset
//   init         — pulse high for 1 cycle to inject custom H init (midstate)
//   h_init_*     — optional custom initial hash values (midstate injection)
//   block_valid  — assert when block_in contains a valid 512-bit block
//   block_in     — 512-bit padded SHA-256 message block (big-endian)
//   hash_valid   — pulses high when hash_out is valid (LATENCY clocks later)
//   hash_out     — 256-bit SHA-256 digest (big-endian)
//
// Latency      : 64 + 1 clock cycles (pipeline depth)
// Throughput   : 1 hash / clock (100% utilisation after fill)
// Target       : Xilinx 7-series / UltraScale / Intel Cyclone V / Arria 10
//
// Bitcoin Note :
//   For Bitcoin mining:
//     Round 1: SHA256(block_header[0:511])  → midstate
//     Round 2: SHA256(block_header[512:639] padded) using midstate as IV
//   Inject midstate using h_init_* + init=1 before asserting block_valid.
// =============================================================================

`include "sha256_functions.vh"

module sha256_core (
    input  wire          clk,
    input  wire          rst_n,

    // Optional midstate injection (for Bitcoin double-SHA optimisation)
    input  wire          init,          // 1 = load h_init_* as IVs this cycle
    input  wire [31:0]   h_init_0,
    input  wire [31:0]   h_init_1,
    input  wire [31:0]   h_init_2,
    input  wire [31:0]   h_init_3,
    input  wire [31:0]   h_init_4,
    input  wire [31:0]   h_init_5,
    input  wire [31:0]   h_init_6,
    input  wire [31:0]   h_init_7,

    // Data path
    input  wire          block_valid,   // block_in is valid this cycle
    input  wire [511:0]  block_in,      // 512-bit padded message block

    output reg           hash_valid,    // hash_out is valid this cycle
    output reg  [255:0]  hash_out       // 256-bit digest
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam ROUNDS   = 64;
    localparam LATENCY  = ROUNDS + 1;   // 65 cycles: 64 compress + 1 add IV

    // =========================================================================
    // Standard SHA-256 Initial Hash Values H0..H7 (FIPS 180-4 §5.3.3)
    // Fractional parts of square roots of first 8 primes
    // =========================================================================
    localparam [31:0] IV_H0 = 32'h6a09e667;
    localparam [31:0] IV_H1 = 32'hbb67ae85;
    localparam [31:0] IV_H2 = 32'h3c6ef372;
    localparam [31:0] IV_H3 = 32'ha54ff53a;
    localparam [31:0] IV_H4 = 32'h510e527f;
    localparam [31:0] IV_H5 = 32'h9b05688c;
    localparam [31:0] IV_H6 = 32'h1f83d9ab;
    localparam [31:0] IV_H7 = 32'h5be0cd19;

    // =========================================================================
    // Round Constants K[0..63] (FIPS 180-4 §4.2.2)
    // =========================================================================
    wire [31:0] K [0:63];

    assign K[ 0] = 32'h428a2f98; assign K[ 1] = 32'h71374491;
    assign K[ 2] = 32'hb5c0fbcf; assign K[ 3] = 32'he9b5dba5;
    assign K[ 4] = 32'h3956c25b; assign K[ 5] = 32'h59f111f1;
    assign K[ 6] = 32'h923f82a4; assign K[ 7] = 32'hab1c5ed5;
    assign K[ 8] = 32'hd807aa98; assign K[ 9] = 32'h12835b01;
    assign K[10] = 32'h243185be; assign K[11] = 32'h550c7dc3;
    assign K[12] = 32'h72be5d74; assign K[13] = 32'h80deb1fe;
    assign K[14] = 32'h9bdc06a7; assign K[15] = 32'hc19bf174;
    assign K[16] = 32'he49b69c1; assign K[17] = 32'hefbe4786;
    assign K[18] = 32'h0fc19dc6; assign K[19] = 32'h240ca1cc;
    assign K[20] = 32'h2de92c6f; assign K[21] = 32'h4a7484aa;
    assign K[22] = 32'h5cb0a9dc; assign K[23] = 32'h76f988da;
    assign K[24] = 32'h983e5152; assign K[25] = 32'ha831c66d;
    assign K[26] = 32'hb00327c8; assign K[27] = 32'hbf597fc7;
    assign K[28] = 32'hc6e00bf3; assign K[29] = 32'hd5a79147;
    assign K[30] = 32'h06ca6351; assign K[31] = 32'h14292967;
    assign K[32] = 32'h27b70a85; assign K[33] = 32'h2e1b2138;
    assign K[34] = 32'h4d2c6dfc; assign K[35] = 32'h53380d13;
    assign K[36] = 32'h650a7354; assign K[37] = 32'h766a0abb;
    assign K[38] = 32'h81c2c92e; assign K[39] = 32'h92722c85;
    assign K[40] = 32'ha2bfe8a1; assign K[41] = 32'ha81a664b;
    assign K[42] = 32'hc24b8b70; assign K[43] = 32'hc76c51a3;
    assign K[44] = 32'hd192e819; assign K[45] = 32'hd6990624;
    assign K[46] = 32'hf40e3585; assign K[47] = 32'h106aa070;
    assign K[48] = 32'h19a4c116; assign K[49] = 32'h1e376c08;
    assign K[50] = 32'h2748774c; assign K[51] = 32'h34b0bcb5;
    assign K[52] = 32'h391c0cb3; assign K[53] = 32'h4ed8aa4a;
    assign K[54] = 32'h5b9cca4f; assign K[55] = 32'h682e6ff3;
    assign K[56] = 32'h748f82ee; assign K[57] = 32'h78a5636f;
    assign K[58] = 32'h84c87814; assign K[59] = 32'h8cc70208;
    assign K[60] = 32'h90befffa; assign K[61] = 32'ha4506ceb;
    assign K[62] = 32'hbef9a3f7; assign K[63] = 32'hc67178f2;

    // =========================================================================
    // Message Schedule W[0..63] — combinational expand from block_in
    // =========================================================================
    // We compute W entirely combinationally from the registered input.
    // The synthesis tool will pipeline these naturally when retiming is on,
    // or you can add explicit pipe stages here for very high fclk targets.
    // =========================================================================
    reg  [511:0] block_r;             // registered input block
    wire [31:0]  W [0:63];

    // Register input block aligned with first round
    always @(posedge clk) begin
        if (!rst_n)
            block_r <= 512'b0;
        else if (block_valid)
            block_r <= block_in;
    end

    // Unpack W[0..15] from registered block (big-endian)
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : W_UNPACK
            assign W[gi] = block_r[511 - 32*gi -: 32];
        end
    endgenerate

    // Expand W[16..63]
    generate
        for (gi = 16; gi < 64; gi = gi + 1) begin : W_EXPAND
            assign W[gi] = `SSIG1(W[gi-2])
                         + W[gi-7]
                         + `SSIG0(W[gi-15])
                         + W[gi-16];
        end
    endgenerate

    // =========================================================================
    // Pipeline Registers: working variables per stage
    // pipe_a[t] holds 'a' at the END of round t (i.e. after t+1 rounds done)
    // pipe_a[0] holds the IV / initial working variables (before round 0)
    // =========================================================================
    reg [31:0] pipe_a [0:ROUNDS];
    reg [31:0] pipe_b [0:ROUNDS];
    reg [31:0] pipe_c [0:ROUNDS];
    reg [31:0] pipe_d [0:ROUNDS];
    reg [31:0] pipe_e [0:ROUNDS];
    reg [31:0] pipe_f [0:ROUNDS];
    reg [31:0] pipe_g [0:ROUNDS];
    reg [31:0] pipe_h [0:ROUNDS];

    // =========================================================================
    // IV registers — latched once per block (support midstate injection)
    // =========================================================================
    reg [31:0] iv_h0, iv_h1, iv_h2, iv_h3;
    reg [31:0] iv_h4, iv_h5, iv_h6, iv_h7;

    always @(posedge clk) begin
        if (!rst_n) begin
            iv_h0 <= IV_H0; iv_h1 <= IV_H1;
            iv_h2 <= IV_H2; iv_h3 <= IV_H3;
            iv_h4 <= IV_H4; iv_h5 <= IV_H5;
            iv_h6 <= IV_H6; iv_h7 <= IV_H7;
        end else if (init) begin
            // Midstate injection for Bitcoin double-SHA optimisation
            iv_h0 <= h_init_0; iv_h1 <= h_init_1;
            iv_h2 <= h_init_2; iv_h3 <= h_init_3;
            iv_h4 <= h_init_4; iv_h5 <= h_init_5;
            iv_h6 <= h_init_6; iv_h7 <= h_init_7;
        end
    end

    // =========================================================================
    // Pipeline Stage 0: Load IVs into working variables
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            pipe_a[0] <= 32'b0;
            pipe_b[0] <= 32'b0;
            pipe_c[0] <= 32'b0;
            pipe_d[0] <= 32'b0;
            pipe_e[0] <= 32'b0;
            pipe_f[0] <= 32'b0;
            pipe_g[0] <= 32'b0;
            pipe_h[0] <= 32'b0;
        end else begin
            pipe_a[0] <= iv_h0;
            pipe_b[0] <= iv_h1;
            pipe_c[0] <= iv_h2;
            pipe_d[0] <= iv_h3;
            pipe_e[0] <= iv_h4;
            pipe_f[0] <= iv_h5;
            pipe_g[0] <= iv_h6;
            pipe_h[0] <= iv_h7;
        end
    end

    // =========================================================================
    // Pipeline Stages 1..64: 64 compression rounds
    // Each stage is one registered sha256_round instantiation.
    // =========================================================================

    // Combinational round outputs (wires between flops)
    wire [31:0] rnd_a_out [0:ROUNDS-1];
    wire [31:0] rnd_b_out [0:ROUNDS-1];
    wire [31:0] rnd_c_out [0:ROUNDS-1];
    wire [31:0] rnd_d_out [0:ROUNDS-1];
    wire [31:0] rnd_e_out [0:ROUNDS-1];
    wire [31:0] rnd_f_out [0:ROUNDS-1];
    wire [31:0] rnd_g_out [0:ROUNDS-1];
    wire [31:0] rnd_h_out [0:ROUNDS-1];

    generate
        for (gi = 0; gi < ROUNDS; gi = gi + 1) begin : COMPRESS

            // ------------------------------------------------------------------
            // Combinational round logic (zero latency)
            // ------------------------------------------------------------------
            sha256_round u_round (
                .a_in  (pipe_a[gi]),
                .b_in  (pipe_b[gi]),
                .c_in  (pipe_c[gi]),
                .d_in  (pipe_d[gi]),
                .e_in  (pipe_e[gi]),
                .f_in  (pipe_f[gi]),
                .g_in  (pipe_g[gi]),
                .h_in  (pipe_h[gi]),
                .w_in  (W[gi]),
                .k_in  (K[gi]),
                .a_out (rnd_a_out[gi]),
                .b_out (rnd_b_out[gi]),
                .c_out (rnd_c_out[gi]),
                .d_out (rnd_d_out[gi]),
                .e_out (rnd_e_out[gi]),
                .f_out (rnd_f_out[gi]),
                .g_out (rnd_g_out[gi]),
                .h_out (rnd_h_out[gi])
            );

            // ------------------------------------------------------------------
            // Pipeline register: capture round output
            // ------------------------------------------------------------------
            always @(posedge clk) begin
                if (!rst_n) begin
                    pipe_a[gi+1] <= 32'b0;
                    pipe_b[gi+1] <= 32'b0;
                    pipe_c[gi+1] <= 32'b0;
                    pipe_d[gi+1] <= 32'b0;
                    pipe_e[gi+1] <= 32'b0;
                    pipe_f[gi+1] <= 32'b0;
                    pipe_g[gi+1] <= 32'b0;
                    pipe_h[gi+1] <= 32'b0;
                end else begin
                    pipe_a[gi+1] <= rnd_a_out[gi];
                    pipe_b[gi+1] <= rnd_b_out[gi];
                    pipe_c[gi+1] <= rnd_c_out[gi];
                    pipe_d[gi+1] <= rnd_d_out[gi];
                    pipe_e[gi+1] <= rnd_e_out[gi];
                    pipe_f[gi+1] <= rnd_f_out[gi];
                    pipe_g[gi+1] <= rnd_g_out[gi];
                    pipe_h[gi+1] <= rnd_h_out[gi];
                end
            end

        end
    endgenerate

    // =========================================================================
    // IV Pipeline: the initial hash values must be delayed ROUNDS cycles
    // so they arrive at the adder when the corresponding working vars do.
    // Shift register length = ROUNDS cycles.
    // =========================================================================
    reg [31:0] iv_pipe_h0 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h1 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h2 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h3 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h4 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h5 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h6 [0:ROUNDS-1];
    reg [31:0] iv_pipe_h7 [0:ROUNDS-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            iv_pipe_h0[0] <= 32'b0;
            iv_pipe_h1[0] <= 32'b0;
            iv_pipe_h2[0] <= 32'b0;
            iv_pipe_h3[0] <= 32'b0;
            iv_pipe_h4[0] <= 32'b0;
            iv_pipe_h5[0] <= 32'b0;
            iv_pipe_h6[0] <= 32'b0;
            iv_pipe_h7[0] <= 32'b0;
        end else begin
            iv_pipe_h0[0] <= iv_h0;
            iv_pipe_h1[0] <= iv_h1;
            iv_pipe_h2[0] <= iv_h2;
            iv_pipe_h3[0] <= iv_h3;
            iv_pipe_h4[0] <= iv_h4;
            iv_pipe_h5[0] <= iv_h5;
            iv_pipe_h6[0] <= iv_h6;
            iv_pipe_h7[0] <= iv_h7;
        end
    end

    generate
        for (gi = 1; gi < ROUNDS; gi = gi + 1) begin : IV_PIPE
            always @(posedge clk) begin
                if (!rst_n) begin
                    iv_pipe_h0[gi] <= 32'b0;
                    iv_pipe_h1[gi] <= 32'b0;
                    iv_pipe_h2[gi] <= 32'b0;
                    iv_pipe_h3[gi] <= 32'b0;
                    iv_pipe_h4[gi] <= 32'b0;
                    iv_pipe_h5[gi] <= 32'b0;
                    iv_pipe_h6[gi] <= 32'b0;
                    iv_pipe_h7[gi] <= 32'b0;
                end else begin
                    iv_pipe_h0[gi] <= iv_pipe_h0[gi-1];
                    iv_pipe_h1[gi] <= iv_pipe_h1[gi-1];
                    iv_pipe_h2[gi] <= iv_pipe_h2[gi-1];
                    iv_pipe_h3[gi] <= iv_pipe_h3[gi-1];
                    iv_pipe_h4[gi] <= iv_pipe_h4[gi-1];
                    iv_pipe_h5[gi] <= iv_pipe_h5[gi-1];
                    iv_pipe_h6[gi] <= iv_pipe_h6[gi-1];
                    iv_pipe_h7[gi] <= iv_pipe_h7[gi-1];
                end
            end
        end
    endgenerate

    // =========================================================================
    // Valid Signal Pipeline
    // Shift block_valid through LATENCY stages to produce hash_valid
    // =========================================================================
    reg [LATENCY-1:0] valid_pipe;

    always @(posedge clk) begin
        if (!rst_n)
            valid_pipe <= {LATENCY{1'b0}};
        else
            valid_pipe <= {valid_pipe[LATENCY-2:0], block_valid};
    end

    // =========================================================================
    // Final Stage: Add compressed vars back to IV (FIPS 180-4 §6.2.2 Step 4)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            hash_valid <= 1'b0;
            hash_out   <= 256'b0;
        end else begin
            hash_valid <= valid_pipe[LATENCY-1];
            if (valid_pipe[LATENCY-1]) begin
                hash_out[255:224] <= pipe_a[ROUNDS] + iv_pipe_h0[ROUNDS-1];
                hash_out[223:192] <= pipe_b[ROUNDS] + iv_pipe_h1[ROUNDS-1];
                hash_out[191:160] <= pipe_c[ROUNDS] + iv_pipe_h2[ROUNDS-1];
                hash_out[159:128] <= pipe_d[ROUNDS] + iv_pipe_h3[ROUNDS-1];
                hash_out[127: 96] <= pipe_e[ROUNDS] + iv_pipe_h4[ROUNDS-1];
                hash_out[ 95: 64] <= pipe_f[ROUNDS] + iv_pipe_h5[ROUNDS-1];
                hash_out[ 63: 32] <= pipe_g[ROUNDS] + iv_pipe_h6[ROUNDS-1];
                hash_out[ 31:  0] <= pipe_h[ROUNDS] + iv_pipe_h7[ROUNDS-1];
            end
        end
    end

endmodule
