// =============================================================================
// File        : sha256_functions.vh
// Project     : SHA-256 Core for FPGA Bitcoin Miner
// Author      : Industry-Grade RTL Design
// Description : SHA-256 Logical Function Macros
//               All functions are purely combinational, zero-latency.
//               Inlined via `include to allow synthesis tool to optimise.
// =============================================================================
// Standard SHA-256 functions (FIPS 180-4):
//
//   Ch  (x,y,z) = (x & y) ^ (~x & z)
//   Maj (x,y,z) = (x & y) ^ (x & z) ^ (y & z)
//   Σ0  (x)     = ROTR²  ^ ROTR¹³ ^ ROTR²²
//   Σ1  (x)     = ROTR⁶  ^ ROTR¹¹ ^ ROTR²⁵
//   σ0  (x)     = ROTR⁷  ^ ROTR¹⁸ ^ SHR³
//   σ1  (x)     = ROTR¹⁷ ^ ROTR¹⁹ ^ SHR¹⁰
// =============================================================================

`ifndef SHA256_FUNCTIONS_VH
`define SHA256_FUNCTIONS_VH

// Rotation helpers
`define ROTR(x, n) ({x[n-1:0], x[31:n]})

// Choice: uses x to mux between y and z
// `define Ch(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
`define Ch(x,y,z)  ((z) ^ ((x) & ((y) ^ (z))))

// Majority: true when at least 2 of 3 inputs are 1
`define Maj(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

// Big-sigma 0: for a..h update (works on a)
`define BSIG0(x)   (`ROTR(x,  2) ^ `ROTR(x, 13) ^ `ROTR(x, 22))

// Big-sigma 1: for a..h update (works on e)
`define BSIG1(x)   (`ROTR(x,  6) ^ `ROTR(x, 11) ^ `ROTR(x, 25))

// Small-sigma 0: for message schedule (works on W[t-15])
`define SSIG0(x)   (`ROTR(x,  7) ^ `ROTR(x, 18) ^ ((x) >> 3))

// Small-sigma 1: for message schedule (works on W[t-2])
`define SSIG1(x)   (`ROTR(x, 17) ^ `ROTR(x, 19) ^ ((x) >> 10))

`endif // SHA256_FUNCTIONS_VH
