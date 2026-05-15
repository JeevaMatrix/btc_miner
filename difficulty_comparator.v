// =============================================================================
// difficulty_comparator.v
// =============================================================================
// Compares the final double-SHA256 hash against the difficulty target.
//
// Bitcoin difficulty rule:
//   hash_out < target  →  valid block found
//
// The hash and target are 256-bit big-endian integers.
// "Less than" means numerically smaller — i.e. more leading zero bits.
//
// The comparator receives hash_valid and hash_out from Pass 2 sha256_core.
// It must also know WHICH nonce produced the winning hash.
//
// Pipeline latency tracking:
//   Pass 2 sha256_core has a 65-cycle latency.
//   The nonce that produced hash_out was submitted 65 cycles ago.
//   We delay-track the nonce through a matching 65-cycle shift register
//   so it arrives in sync with hash_out.
//
// Ports:
//   hash_valid    — from Pass 2 sha256_core
//   hash_out      — 256-bit double-SHA256 result (big-endian)
//   nonce_in      — current nonce from nonce_ctrl (must be pipeline-delayed here)
//   target        — 256-bit difficulty target (latched from job_loader)
//   solution_valid — pulses 1 cycle when a valid nonce is found
//   solution_nonce — the winning nonce
//   solution_hash  — the winning hash (for submission to pool)
// =============================================================================

module difficulty_comparator (
    input  wire         clk,
    input  wire         rst_n,

    // From Pass 2 sha256_core
    input  wire         hash_valid,
    input  wire [255:0] hash_out,

    // From nonce_ctrl (real-time, needs delay matching)
    input  wire [31:0]  nonce_in,

    // From job_loader
    input  wire [255:0] target,

    // Solution output
    output reg          solution_valid,
    output reg  [31:0]  solution_nonce,
    output reg  [255:0] solution_hash
);
    // -------------------------------------------------------------------------
    // Nonce delay pipeline — 65 stages to match Pass 2 latency
    // -------------------------------------------------------------------------
    localparam PASS2_LATENCY = 65;

    reg [31:0] nonce_pipe [0:PASS2_LATENCY-1];
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < PASS2_LATENCY; i = i+1)
                nonce_pipe[i] <= 32'b0;
        end else begin
            nonce_pipe[0] <= nonce_in;
            for (i = 1; i < PASS2_LATENCY; i = i+1)
                nonce_pipe[i] <= nonce_pipe[i-1];
        end
    end

    wire [31:0] matched_nonce = nonce_pipe[PASS2_LATENCY-1];

    // -------------------------------------------------------------------------
    // 256-bit comparison: hash < target
    // Bitcoin hashes are compared as big-endian 256-bit integers.
    // hash_out[255:224] is the most significant word.
    // We compare word by word from MSW to LSW.
    //
    // Implementation: subtract target from hash. If there's a borrow out,
    // hash < target. This is the most synthesis-efficient approach.
    //
    // For FPGA: use a carry-chain subtraction.
    // For critical path: this is a 256-bit comparator — one combinational
    // level. Synthesis will build it as a tree of 32-bit comparators.
    // -------------------------------------------------------------------------
    wire less_than;

    // 256-bit less-than via hierarchical 32-bit comparison
    // Compare word by word: first word where they differ determines the result
    wire [7:0] eq_w;   // word[i] == target_w[i]
    wire [7:0] lt_w;   // word[i] <  target_w[i] (unsigned)

    wire [31:0] hash_w  [0:7];
    wire [31:0] target_w[0:7];

    genvar gj;
    generate
        for (gj = 0; gj < 8; gj = gj+1) begin : WORD_SPLIT
            assign hash_w[gj]   = hash_out[255-32*gj -: 32];
            assign target_w[gj] = target  [255-32*gj -: 32];
            assign eq_w[gj]     = (hash_w[gj] == target_w[gj]);
            assign lt_w[gj]     = (hash_w[gj] <  target_w[gj]);
        end
    endgenerate

    // Priority encoder: find first word that differs, take lt_w of that word
    assign less_than =
        lt_w[0]                                                           ? 1'b1 :
        eq_w[0] && lt_w[1]                                                ? 1'b1 :
        eq_w[0] && eq_w[1] && lt_w[2]                                    ? 1'b1 :
        eq_w[0] && eq_w[1] && eq_w[2] && lt_w[3]                         ? 1'b1 :
        eq_w[0] && eq_w[1] && eq_w[2] && eq_w[3] && lt_w[4]             ? 1'b1 :
        eq_w[0] && eq_w[1] && eq_w[2] && eq_w[3] && eq_w[4] && lt_w[5]  ? 1'b1 :
        eq_w[0] && eq_w[1] && eq_w[2] && eq_w[3] && eq_w[4] && eq_w[5] && lt_w[6] ? 1'b1 :
        eq_w[0] && eq_w[1] && eq_w[2] && eq_w[3] && eq_w[4] && eq_w[5] && eq_w[6] && lt_w[7] ? 1'b1 :
        1'b0;

    // -------------------------------------------------------------------------
    // Register solution output
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            solution_valid <= 0;
            solution_nonce <= 0;
            solution_hash  <= 0;
        end else begin
            solution_valid <= 0; // default: no solution this cycle
            if (hash_valid && less_than) begin
                solution_valid <= 1;
                solution_nonce <= matched_nonce;
                solution_hash  <= hash_out;
            end
        end
    end

endmodule
