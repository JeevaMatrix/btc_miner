// =============================================================================
// nonce_ctrl.v
// =============================================================================
// Controls nonce generation and builds the padded 512-bit block for Pass 2.
//
// The second SHA-256 pass operates on the 16-byte tail of the block header
// with an incrementing nonce, padded to 512 bits.
//
// Bitcoin header tail block layout (Pass 2 input, 64 bytes / 512 bits):
//   Bytes 0-3   : header[64:67] = time        (W[0])
//   Bytes 4-7   : header[68:71] = bits/target  (W[1])
//   Bytes 8-11  : nonce                        (W[2])  ← we control this
//   Byte  12    : 0x80 (SHA-256 padding start)         (W[3] MSB)
//   Bytes 13-57 : 0x00                                 (W[3] LSB..W[14])
//   Bytes 58-59 : 0x00 (length high)
//   Bytes 60-63 : 0x00000280 (length = 640 bits)       (W[15])
//
// Block format:
//   W[ 0] = time           (from header_tail[127:96])
//   W[ 1] = bits           (from header_tail[95:64])
//   W[ 2] = nonce          (incremented here)
//   W[ 3] = 32'h80000000
//   W[ 4..13] = 32'h0
//   W[14] = 32'h00000000
//   W[15] = 32'h00000280   (640 bits = 0x280)
//
// Ports:
//   start         — pulse from job_loader when midstate is ready
//   header_tail   — header[64:79], 128-bit (4 words: time, bits, nonce_base, padding)
//                   Note: nonce_base from host is ignored; we start at 0
//   nonce_start   — optional nonce to start from (for multi-core offset)
//   nonce_out     — current nonce being tested (for solution reporting)
//   block_out     — 512-bit padded block for Pass 2 sha256_core
//   block_valid   — high every cycle while running (feeds Pass 2 continuously)
//   stop          — pulse to halt (solution found or job changed)
//   nonce_wrap    — pulses when nonce overflows 0xFFFFFFFF (no solution found)
// =============================================================================

module nonce_ctrl (
    input  wire         clk,
    input  wire         rst_n,

    // Control
    input  wire         start,          // begin/restart nonce iteration
    input  wire         stop,           // halt (solution found or new job)
    input  wire [127:0] header_tail,    // header bytes 64-79 (time + bits fields)
    input  wire [31:0]  nonce_start,    // nonce offset for multi-core (default 0)
    input  wire [31:0]  nonce_step,     // increment per cycle (1 for single core)

    // Output to Pass 2 sha256_core
    output reg  [511:0] block_out,
    output reg          block_valid,

    // Status
    output reg  [31:0]  nonce_out,      // current nonce being submitted
    output reg          nonce_wrap,     // full 2^32 space exhausted
    output wire         running
);
    // -------------------------------------------------------------------------
    // Extract time and bits from header_tail
    // header_tail is big-endian: byte64 at [127:120] ... byte79 at [7:0]
    // W[0] = bytes 64-67 = header_tail[127:96]
    // W[1] = bytes 68-71 = header_tail[95:64]
    // W[2] = nonce (bytes 72-75) — we override
    // W[3..] = padding
    // -------------------------------------------------------------------------
    wire [31:0] W0_time = header_tail[127:96];
    wire [31:0] W1_bits = header_tail[95:64];

    // -------------------------------------------------------------------------
    // Nonce register
    // -------------------------------------------------------------------------
    reg         active;
    reg [31:0]  nonce_r;

    assign running = active;

    always @(posedge clk) begin
        if (!rst_n) begin
            active      <= 0;
            nonce_r     <= 0;
            nonce_out   <= 0;
            block_valid <= 0;
            nonce_wrap  <= 0;
        end else begin
            nonce_wrap  <= 0; // default

            if (stop) begin
                active      <= 0;
                block_valid <= 0;
            end else if (start) begin
                active      <= 1;
                nonce_r     <= nonce_start;
                block_valid <= 1;
            end else if (active) begin
                // Increment nonce
                if (nonce_r == 32'hFFFFFFFF) begin
                    nonce_wrap <= 1;
                    active     <= 0;
                    block_valid<= 0;
                end else begin
                    nonce_r <= nonce_r + nonce_step;
                end
                nonce_out <= nonce_r;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Build padded 512-bit block every cycle (combinational from nonce_r)
    // -------------------------------------------------------------------------
    always @(*) begin
        block_out = 512'b0;
        // W[0] = time
        block_out[511:480] = W0_time;
        // W[1] = bits
        block_out[479:448] = W1_bits;
        // W[2] = nonce
        block_out[447:416] = nonce_r;
        // W[3] = 0x80000000 (SHA-256 padding byte)
        block_out[415:384] = 32'h80000000;
        // W[4..13] = 0 (already 0 from default)
        // W[14] = 0
        block_out[ 63: 32] = 32'h00000000;
        // W[15] = message length in bits = 80*8 = 640 = 0x280
        // (full header length, not just the tail — Bitcoin protocol requirement)
        block_out[ 31:  0] = 32'h00000280;
    end

endmodule
