// =============================================================================
// bitcoin_miner_top.v
// =============================================================================
// Full Bitcoin miner top-level.
// Integrates: job_loader → nonce_ctrl → sha256_core(Pass2) → difficulty_comparator
//             job_loader internally instantiates sha256_core(Pass1) for midstate.
//
// Data flow:
//   1. Host asserts job_valid with 640-bit header + 256-bit target.
//   2. job_loader feeds header[0:63] to Pass 1 SHA-256 → midstate (65 cycles).
//   3. On midstate_valid: nonce_ctrl starts iterating nonces.
//   4. nonce_ctrl builds padded 512-bit block every clock.
//   5. Pass 2 SHA-256 is configured with midstate as custom IV.
//      block_valid goes high every cycle → 1 hash/clock after 65-cycle fill.
//   6. difficulty_comparator checks every hash against target.
//   7. On match: solution_valid pulses, solution_nonce/hash captured.
//      stop sent to nonce_ctrl.
//
// Multi-core scaling:
//   Instantiate N copies of this module with nonce_start = k*(2^32/N)
//   and nonce_step = N. Each core covers a non-overlapping nonce slice.
//
// Ports:
//   job_valid      — pulse from host with new work
//   header_in      — 640-bit block header (80 bytes, big-endian)
//   target_in      — 256-bit difficulty target
//   solution_valid — pulses when a valid block is found
//   solution_nonce — winning nonce (32-bit)
//   solution_hash  — winning double-SHA256 hash (256-bit)
//   hash_rate_tick — pulses every hash computed (for rate metering)
//   nonce_exhaust  — all 2^32 nonces tried, no solution
// =============================================================================

module bitcoin_miner_top (
    input  wire         clk,
    input  wire         rst_n,

    // Host interface
    input  wire         job_valid,
    input  wire [639:0] header_in,
    input  wire [255:0] target_in,

    // Multi-core nonce partitioning
    input  wire [31:0]  nonce_start,   // e.g. core_id * (2^32 / NUM_CORES)
    input  wire [31:0]  nonce_step,    // e.g. NUM_CORES

    // Solution output
    output wire         solution_valid,
    output wire [31:0]  solution_nonce,
    output wire [255:0] solution_hash,

    // Monitoring
    output wire         hash_rate_tick, // 1 pulse per hash for rate counter
    output wire         nonce_exhaust,  // nonce space fully scanned
    output wire         busy            // midstate computation in progress
);
    // -------------------------------------------------------------------------
    // Wires between modules
    // -------------------------------------------------------------------------
    wire         midstate_valid;
    wire [255:0] midstate;
    wire [127:0] header_tail;
    wire [255:0] target_latched;

    wire [511:0] nonce_block;
    wire         nonce_block_valid;
    wire [31:0]  nonce_current;
    wire         nonce_wrap;
    wire         nonce_running;

    wire         p2_hash_valid;
    wire [255:0] p2_hash_out;

    // Solution found → stop nonce controller
    wire         solution_found; // internal alias

    // -------------------------------------------------------------------------
    // job_loader: receives work, computes midstate via internal Pass 1 SHA-256
    // -------------------------------------------------------------------------
    job_loader u_job (
        .clk             (clk),
        .rst_n           (rst_n),
        .job_valid       (job_valid),
        .header_in       (header_in),
        .target_in       (target_in),
        .midstate_valid  (midstate_valid),
        .midstate_out    (midstate),
        .header_tail_out (header_tail),
        .target_out      (target_latched),
        .busy            (busy)
    );

    // -------------------------------------------------------------------------
    // nonce_ctrl: iterates nonces, builds padded 512-bit blocks
    // -------------------------------------------------------------------------
    nonce_ctrl u_nonce (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (midstate_valid),
        .stop        (solution_found | job_valid), // stop on solution OR new job
        .header_tail (header_tail),
        .nonce_start (nonce_start),
        .nonce_step  (nonce_step),
        .block_out   (nonce_block),
        .block_valid (nonce_block_valid),
        .nonce_out   (nonce_current),
        .nonce_wrap  (nonce_wrap),
        .running     (nonce_running)
    );

    // -------------------------------------------------------------------------
    // Pass 2 SHA-256 core — midstate injected as custom IV
    // Processes one nonce block per clock. Latency = 65 clocks.
    // -------------------------------------------------------------------------
    sha256_core u_pass2 (
        .clk         (clk),
        .rst_n       (rst_n),
        // Load midstate as IV when job_loader signals it
        .init        (midstate_valid),
        .h_init_0    (midstate[255:224]),
        .h_init_1    (midstate[223:192]),
        .h_init_2    (midstate[191:160]),
        .h_init_3    (midstate[159:128]),
        .h_init_4    (midstate[127: 96]),
        .h_init_5    (midstate[ 95: 64]),
        .h_init_6    (midstate[ 63: 32]),
        .h_init_7    (midstate[ 31:  0]),
        // Nonce blocks in, 1 per clock
        .block_valid (nonce_block_valid),
        .block_in    (nonce_block),
        // Hash results out, 65 cycles later
        .hash_valid  (p2_hash_valid),
        .hash_out    (p2_hash_out)
    );

    // -------------------------------------------------------------------------
    // Difficulty comparator: checks hash < target, recovers matched nonce
    // -------------------------------------------------------------------------
    difficulty_comparator u_cmp (
        .clk           (clk),
        .rst_n         (rst_n),
        .hash_valid    (p2_hash_valid),
        .hash_out      (p2_hash_out),
        .nonce_in      (nonce_current),
        .target        (target_latched),
        .solution_valid(solution_found),
        .solution_nonce(solution_nonce),
        .solution_hash (solution_hash)
    );

    // -------------------------------------------------------------------------
    // Output assignments
    // -------------------------------------------------------------------------
    assign solution_valid  = solution_found;
    assign hash_rate_tick  = p2_hash_valid;   // 1 tick per completed hash
    assign nonce_exhaust   = nonce_wrap;

endmodule
