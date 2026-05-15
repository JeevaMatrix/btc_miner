// =============================================================================
// job_loader.v
// =============================================================================
// Receives a new mining job from the host (stratum work unit) and manages the
// midstate computation.
//
// A Bitcoin block header is 80 bytes:
//   [0:3]   version      (4 bytes)
//   [4:35]  prev_hash    (32 bytes)
//   [36:67] merkle_root  (32 bytes)
//   [68:71] time         (4 bytes)
//   [72:75] bits/target  (4 bytes)
//   [76:79] nonce        (4 bytes)  ← miner controls this field
//
// The first 64 bytes are constant for a given job. SHA256(first 64 bytes) is
// the midstate — computed ONCE per job by Pass 1 SHA256 core.
//
// The second chunk (bytes 64-79) changes every nonce trial.
// It must be padded to 512 bits before feeding Pass 2.
//
// Padding for the 16-byte second chunk:
//   16 bytes message | 0x80 | zeros | 64-bit length = 640 bits = 0x280
//   Packed as 512-bit block:
//   W[0]  = header[64:67]  (time, already in block_r[0])
//   W[1]  = header[68:71]  (bits)
//   W[2]  = header[72:75]  (nonce — injected by nonce_ctrl)
//   W[3]  = 32'h80000000  (padding start)
//   W[4..13] = 0
//   W[14] = 32'h00000000  (length high word = 0, length is only 640 bits)
//   W[15] = 32'h00000280  (640 in decimal = 0x280)
//
// Ports:
//   job_valid     — host pulses this for 1 cycle with a new 640-bit header
//   header_in     — full 80-byte (640-bit) block header, big-endian
//   target_in     — 256-bit difficulty target (from bits field, expanded)
//   midstate_valid — goes high 65 cycles after job_valid; nonce_ctrl may start
//   midstate_out   — 8 × 32-bit midstate words, fed to Pass 2 as custom IV
//   header_tail_out — header[64:79] held for nonce_ctrl to build nonce blocks
//   target_out     — latched target forwarded to comparator
//   busy           — high while computing midstate (65 cycles)
// =============================================================================

module job_loader (
    input  wire         clk,
    input  wire         rst_n,

    // From host / stratum interface
    input  wire         job_valid,
    input  wire [639:0] header_in,      // 80 bytes big-endian
    input  wire [255:0] target_in,      // difficulty target

    // To nonce controller + comparator
    output reg          midstate_valid,
    output reg  [255:0] midstate_out,
    output reg  [127:0] header_tail_out, // header[64:79] = W[0..3] excl. nonce
    output reg  [255:0] target_out,
    output reg          busy
);
    // -------------------------------------------------------------------------
    // Latch header and target on job_valid
    // -------------------------------------------------------------------------
    reg [639:0] header_r;
    reg [255:0] target_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            header_r        <= 0;
            target_r        <= 0;
            header_tail_out <= 0;
            target_out      <= 0;
        end else if (job_valid) begin
            header_r        <= header_in;
            target_r        <= target_in;
            // Tail = header[64:79] = bits [639-512 : 639-512-127] in big-endian
            // header_in[639:0]: byte 0 at [639:632], byte 79 at [7:0]
            // bytes 64-79 = bits [127:0] of header_in
            header_tail_out <= header_in[127:0];
            target_out      <= target_in;
        end
    end

    // -------------------------------------------------------------------------
    // Build the 512-bit Pass 1 block: header[0:63] with standard SHA-256 padding
    // header[0:63] = header_in[639:128]  (big-endian, bytes 0-63)
    // Padding: message is exactly 512 bits (64 bytes = one full block)
    // so we need a SECOND block: 0x80 | zeros | length(512) = 0x200
    // But wait — SHA-256 processes 64-byte blocks. If the message IS 64 bytes,
    // the padding block is: 80 00...00 00000000 00000200
    // -------------------------------------------------------------------------
    wire [511:0] pass1_block = header_r[639:128]; // bytes 0-63, already 512 bits

    // -------------------------------------------------------------------------
    // Drive Pass 1 SHA-256 core
    // -------------------------------------------------------------------------
    wire        p1_hash_valid;
    wire [255:0] p1_hash_out;
    reg         p1_block_valid;

    sha256_core u_pass1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .init        (1'b0),
        .h_init_0    (32'b0), .h_init_1(32'b0), .h_init_2(32'b0), .h_init_3(32'b0),
        .h_init_4    (32'b0), .h_init_5(32'b0), .h_init_6(32'b0), .h_init_7(32'b0),
        .block_valid (p1_block_valid),
        .block_in    (pass1_block),
        .hash_valid  (p1_hash_valid),
        .hash_out    (p1_hash_out)
    );

    // -------------------------------------------------------------------------
    // Job FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_READY   = 2'd2;

    reg [1:0] state;

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            busy           <= 0;
            p1_block_valid <= 0;
            midstate_valid <= 0;
            midstate_out   <= 0;
        end else begin
            p1_block_valid <= 0; // default

            case (state)
                S_IDLE: begin
                    midstate_valid <= 0;
                    if (job_valid) begin
                        state          <= S_COMPUTE;
                        busy           <= 1;
                        p1_block_valid <= 1; // pulse for 1 cycle
                    end
                end

                S_COMPUTE: begin
                    // Wait for Pass 1 to finish (65 cycles)
                    if (p1_hash_valid) begin
                        midstate_out   <= p1_hash_out;
                        midstate_valid <= 1;
                        busy           <= 0;
                        state          <= S_READY;
                    end
                end

                S_READY: begin
                    midstate_valid <= 0; // pulse for 1 cycle only
                    // Accept next job immediately if it arrives
                    if (job_valid) begin
                        state          <= S_COMPUTE;
                        busy           <= 1;
                        p1_block_valid <= 1;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
