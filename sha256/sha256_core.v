`include "sha256_functions.vh"

module sha256_core (
    input  wire          clk,
    input  wire          rst_n,

    // Optional midstate injection (for Bitcoin double-SHA optimisation)
    input  wire          init,
    input  wire [31:0]   h_init_0,
    input  wire [31:0]   h_init_1,
    input  wire [31:0]   h_init_2,
    input  wire [31:0]   h_init_3,
    input  wire [31:0]   h_init_4,
    input  wire [31:0]   h_init_5,
    input  wire [31:0]   h_init_6,
    input  wire [31:0]   h_init_7,

    // Data path
    input  wire          block_valid,
    input  wire [511:0]  block_in,

    output reg           hash_valid,
    output reg  [255:0]  hash_out
);

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam ROUNDS      = 64;
    localparam WMSG_STAGES = 6;          // 6 stages × 8 words = 48 expanded words
    localparam LATENCY     = ROUNDS + 1 + WMSG_STAGES;  // 71 cycles total

    // =========================================================================
    // Standard SHA-256 Initial Hash Values (FIPS 180-4 §5.3.3)
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
    // W[0..15] — directly unpacked from registered input block
    // (same as original, no change)
    // =========================================================================
    reg  [511:0] block_r;

    always @(posedge clk) begin
        if (!rst_n)         block_r <= 512'b0;
        else if (block_valid) block_r <= block_in;
    end

    // W[0..15]: wires into block_r (zero extra latency)
    wire [31:0] W_base [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : W_UNPACK
            assign W_base[gi] = block_r[511 - 32*gi -: 32];
        end
    endgenerate

    // =========================================================================
    // Pipelined Message Schedule  W[16..63]
    // =========================================================================

    // Flat register array: W_pipe[stage][word_within_stage]
    reg [31:0] W_pipe [0:WMSG_STAGES-1][0:7];

    // Helper function: index into the full W space.

    wire [31:0] W_all [0:63];

    // Lower 16: wires (block_r already registered)
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : WA_BASE
            assign W_all[gi] = W_base[gi];
        end
    endgenerate

    // Upper 48: from pipeline registers
    generate
        for (gi = 0; gi < WMSG_STAGES; gi = gi + 1) begin : WA_PIPE_STAGE
            // Each stage holds 8 words
            // words 16+8*gi .. 16+8*gi+7
            assign W_all[16 + 8*gi + 0] = W_pipe[gi][0];
            assign W_all[16 + 8*gi + 1] = W_pipe[gi][1];
            assign W_all[16 + 8*gi + 2] = W_pipe[gi][2];
            assign W_all[16 + 8*gi + 3] = W_pipe[gi][3];
            assign W_all[16 + 8*gi + 4] = W_pipe[gi][4];
            assign W_all[16 + 8*gi + 5] = W_pipe[gi][5];
            assign W_all[16 + 8*gi + 6] = W_pipe[gi][6];
            assign W_all[16 + 8*gi + 7] = W_pipe[gi][7];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage register logic — iterate across all 6 stages and 8 words each
    // -------------------------------------------------------------------------

    genvar gs, gw;
    generate
        for (gs = 0; gs < WMSG_STAGES; gs = gs + 1) begin : W_STAGE
            for (gw = 0; gw < 8; gw = gw + 1) begin : W_WORD
                localparam integer T = 16 + 8*gs + gw;  // global W index

                // Combinational expression — one SSIG1 + one SSIG0 + two adds
                wire [31:0] w_comb;
                assign w_comb = `SSIG1(W_all[T-2])
                              + W_all[T-7]
                              + `SSIG0(W_all[T-15])
                              + W_all[T-16];

                // Register the result — this is the pipeline stage flip-flop
                always @(posedge clk) begin
                    if (!rst_n)
                        W_pipe[gs][gw] <= 32'b0;
                    else
                        W_pipe[gs][gw] <= w_comb;
                end
            end
        end
    endgenerate

    // Extended compression pipeline depth
    localparam PIPE_DEPTH = WMSG_STAGES + ROUNDS;  // 70 stages

    reg [31:0] pipe_a [0:PIPE_DEPTH];
    reg [31:0] pipe_b [0:PIPE_DEPTH];
    reg [31:0] pipe_c [0:PIPE_DEPTH];
    reg [31:0] pipe_d [0:PIPE_DEPTH];
    reg [31:0] pipe_e [0:PIPE_DEPTH];
    reg [31:0] pipe_f [0:PIPE_DEPTH];
    reg [31:0] pipe_g [0:PIPE_DEPTH];
    reg [31:0] pipe_h [0:PIPE_DEPTH];

    // =========================================================================
    // IV registers
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
            pipe_a[0] <= 32'b0; pipe_b[0] <= 32'b0;
            pipe_c[0] <= 32'b0; pipe_d[0] <= 32'b0;
            pipe_e[0] <= 32'b0; pipe_f[0] <= 32'b0;
            pipe_g[0] <= 32'b0; pipe_h[0] <= 32'b0;
        end else begin
            pipe_a[0] <= iv_h0; pipe_b[0] <= iv_h1;
            pipe_c[0] <= iv_h2; pipe_d[0] <= iv_h3;
            pipe_e[0] <= iv_h4; pipe_f[0] <= iv_h5;
            pipe_g[0] <= iv_h6; pipe_h[0] <= iv_h7;
        end
    end

    // =========================================================================
    // Bubble stages 1..WMSG_STAGES: just register-through while W pipeline fills
    // =========================================================================
    generate
        for (gi = 0; gi < WMSG_STAGES; gi = gi + 1) begin : BUBBLE
            always @(posedge clk) begin
                if (!rst_n) begin
                    pipe_a[gi+1] <= 32'b0; pipe_b[gi+1] <= 32'b0;
                    pipe_c[gi+1] <= 32'b0; pipe_d[gi+1] <= 32'b0;
                    pipe_e[gi+1] <= 32'b0; pipe_f[gi+1] <= 32'b0;
                    pipe_g[gi+1] <= 32'b0; pipe_h[gi+1] <= 32'b0;
                end else begin
                    pipe_a[gi+1] <= pipe_a[gi]; pipe_b[gi+1] <= pipe_b[gi];
                    pipe_c[gi+1] <= pipe_c[gi]; pipe_d[gi+1] <= pipe_d[gi];
                    pipe_e[gi+1] <= pipe_e[gi]; pipe_f[gi+1] <= pipe_f[gi];
                    pipe_g[gi+1] <= pipe_g[gi]; pipe_h[gi+1] <= pipe_h[gi];
                end
            end
        end
    endgenerate

    // =========================================================================
    // Compression Stages (WMSG_STAGES+1)..(WMSG_STAGES+ROUNDS):
    // 64 SHA-256 rounds.  W_all[r] is used for round r.
    // Because the compression pipeline is delayed by WMSG_STAGES cycles,
    // W_pipe[s] has had s+1 register stages by the time round 16+8s runs.
    // Everything lines up correctly.
    // =========================================================================
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

            // Compression input comes from stage WMSG_STAGES + gi
            sha256_round u_round (
                .a_in  (pipe_a[WMSG_STAGES + gi]),
                .b_in  (pipe_b[WMSG_STAGES + gi]),
                .c_in  (pipe_c[WMSG_STAGES + gi]),
                .d_in  (pipe_d[WMSG_STAGES + gi]),
                .e_in  (pipe_e[WMSG_STAGES + gi]),
                .f_in  (pipe_f[WMSG_STAGES + gi]),
                .g_in  (pipe_g[WMSG_STAGES + gi]),
                .h_in  (pipe_h[WMSG_STAGES + gi]),
                .w_in  (W_all[gi]),     // W_all[gi] is registered: either block_r (r<16)
                .k_in  (K[gi]),         // or W_pipe (r>=16), both properly timed.
                .a_out (rnd_a_out[gi]),
                .b_out (rnd_b_out[gi]),
                .c_out (rnd_c_out[gi]),
                .d_out (rnd_d_out[gi]),
                .e_out (rnd_e_out[gi]),
                .f_out (rnd_f_out[gi]),
                .g_out (rnd_g_out[gi]),
                .h_out (rnd_h_out[gi])
            );

            always @(posedge clk) begin
                if (!rst_n) begin
                    pipe_a[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_b[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_c[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_d[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_e[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_f[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_g[WMSG_STAGES+gi+1] <= 32'b0;
                    pipe_h[WMSG_STAGES+gi+1] <= 32'b0;
                end else begin
                    pipe_a[WMSG_STAGES+gi+1] <= rnd_a_out[gi];
                    pipe_b[WMSG_STAGES+gi+1] <= rnd_b_out[gi];
                    pipe_c[WMSG_STAGES+gi+1] <= rnd_c_out[gi];
                    pipe_d[WMSG_STAGES+gi+1] <= rnd_d_out[gi];
                    pipe_e[WMSG_STAGES+gi+1] <= rnd_e_out[gi];
                    pipe_f[WMSG_STAGES+gi+1] <= rnd_f_out[gi];
                    pipe_g[WMSG_STAGES+gi+1] <= rnd_g_out[gi];
                    pipe_h[WMSG_STAGES+gi+1] <= rnd_h_out[gi];
                end
            end
        end
    endgenerate

    // =========================================================================
    // IV Delay Pipeline — must be LATENCY cycles long
    // (now LATENCY = 71 instead of 65)
    // =========================================================================
    reg [31:0] iv_pipe_h0 [0:LATENCY-2];
    reg [31:0] iv_pipe_h1 [0:LATENCY-2];
    reg [31:0] iv_pipe_h2 [0:LATENCY-2];
    reg [31:0] iv_pipe_h3 [0:LATENCY-2];
    reg [31:0] iv_pipe_h4 [0:LATENCY-2];
    reg [31:0] iv_pipe_h5 [0:LATENCY-2];
    reg [31:0] iv_pipe_h6 [0:LATENCY-2];
    reg [31:0] iv_pipe_h7 [0:LATENCY-2];

    always @(posedge clk) begin
        if (!rst_n) begin
            iv_pipe_h0[0] <= 32'b0; iv_pipe_h1[0] <= 32'b0;
            iv_pipe_h2[0] <= 32'b0; iv_pipe_h3[0] <= 32'b0;
            iv_pipe_h4[0] <= 32'b0; iv_pipe_h5[0] <= 32'b0;
            iv_pipe_h6[0] <= 32'b0; iv_pipe_h7[0] <= 32'b0;
        end else begin
            iv_pipe_h0[0] <= iv_h0; iv_pipe_h1[0] <= iv_h1;
            iv_pipe_h2[0] <= iv_h2; iv_pipe_h3[0] <= iv_h3;
            iv_pipe_h4[0] <= iv_h4; iv_pipe_h5[0] <= iv_h5;
            iv_pipe_h6[0] <= iv_h6; iv_pipe_h7[0] <= iv_h7;
        end
    end

    generate
        for (gi = 1; gi < LATENCY-1; gi = gi + 1) begin : IV_PIPE
            always @(posedge clk) begin
                if (!rst_n) begin
                    iv_pipe_h0[gi] <= 32'b0; iv_pipe_h1[gi] <= 32'b0;
                    iv_pipe_h2[gi] <= 32'b0; iv_pipe_h3[gi] <= 32'b0;
                    iv_pipe_h4[gi] <= 32'b0; iv_pipe_h5[gi] <= 32'b0;
                    iv_pipe_h6[gi] <= 32'b0; iv_pipe_h7[gi] <= 32'b0;
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
    // Valid Signal Pipeline — LATENCY = 71 bits
    // =========================================================================
    reg [LATENCY-1:0] valid_pipe;

    always @(posedge clk) begin
        if (!rst_n)
            valid_pipe <= {LATENCY{1'b0}};
        else
            valid_pipe <= {valid_pipe[LATENCY-2:0], block_valid};
    end

    // =========================================================================
    // Final Stage: Add compressed working vars back to IV
    // (FIPS 180-4 §6.2.2 Step 4)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            hash_valid <= 1'b0;
            hash_out   <= 256'b0;
        end else begin
            hash_valid <= valid_pipe[LATENCY-1];
            if (valid_pipe[LATENCY-1]) begin
                hash_out[255:224] <= pipe_a[PIPE_DEPTH] + iv_pipe_h0[LATENCY-2];
                hash_out[223:192] <= pipe_b[PIPE_DEPTH] + iv_pipe_h1[LATENCY-2];
                hash_out[191:160] <= pipe_c[PIPE_DEPTH] + iv_pipe_h2[LATENCY-2];
                hash_out[159:128] <= pipe_d[PIPE_DEPTH] + iv_pipe_h3[LATENCY-2];
                hash_out[127: 96] <= pipe_e[PIPE_DEPTH] + iv_pipe_h4[LATENCY-2];
                hash_out[ 95: 64] <= pipe_f[PIPE_DEPTH] + iv_pipe_h5[LATENCY-2];
                hash_out[ 63: 32] <= pipe_g[PIPE_DEPTH] + iv_pipe_h6[LATENCY-2];
                hash_out[ 31:  0] <= pipe_h[PIPE_DEPTH] + iv_pipe_h7[LATENCY-2];
            end
        end
    end

endmodule