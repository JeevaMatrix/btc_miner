# SHA-256 Core — Industry-Grade FPGA Implementation
## For Bitcoin Miner Applications

---

## File Structure

```
sha256/
├── sha256_core.v          ← Top-level pipelined core (instantiate this)
├── sha256_round.v         ← Single compression round (combinational)
├── sha256_functions.vh    ← SHA-256 function macros (Ch, Maj, Σ, σ)
├── sha256_k_constants.vh  ← Reference K constants (for documentation)
├── sha256_tb.v            ← Self-checking testbench (NIST vectors)
├── sha256_core.xdc        ← Xilinx timing constraints
├── sha256_core.sdc        ← Intel/Altera timing constraints
└── README.md              ← This file
```

---

## Architecture

### Pipeline Overview

```
                  clk
                   │
 [block_in]──┐     │
 [block_valid]─→ [Stage 0: IV Load]
                   │
                   ↓
             [Round 0: Compress]  ← W[0], K[0]
                   │ (registered)
             [Round 1: Compress]  ← W[1], K[1]
                   │ (registered)
                  ...
                   │
             [Round 63: Compress] ← W[63], K[63]
                   │ (registered)
             [Final Adder: a..h + IV]
                   │
                   ↓
              [hash_out, hash_valid]
```

- **Latency**: 65 clock cycles (64 rounds + 1 adder stage)
- **Throughput**: 1 hash per clock (fully pipelined — no stalls)
- **Architecture**: Linear 64-stage pipeline, one `sha256_round` module per stage

### Resource Estimate (Xilinx Artix-7)

| Resource   | Estimate   | Notes                              |
|------------|------------|------------------------------------|
| LUTs       | ~6,500     | 64 × ~100 LUTs/round               |
| FFs        | ~16,640    | 64 stages × 8 × 32b + IV pipeline  |
| DSPs       | 0          | Pure LUT adders (fits BRAM-free)   |
| BRAMs      | 0          | All pipeline in flip-flops         |
| fclk       | ~180 MHz   | Artix-7 -2, no retiming            |
| fclk       | ~230 MHz   | Kintex-7 -2, with retiming         |
| Throughput | ~180 MH/s  | At 180 MHz, single core            |

Scale throughput linearly by instantiating multiple cores.

---

## Port Description

| Port         | Dir | Width | Description                                    |
|--------------|-----|-------|------------------------------------------------|
| `clk`        | in  | 1     | System clock (posedge active)                  |
| `rst_n`      | in  | 1     | Active-low synchronous reset                   |
| `init`       | in  | 1     | Pulse high to load custom IV (midstate inject) |
| `h_init_0..7`| in  | 32×8  | Custom initial hash values (Bitcoin midstate)  |
| `block_valid`| in  | 1     | Assert for 1 cycle when `block_in` is valid    |
| `block_in`   | in  | 512   | SHA-256 padded message block (big-endian)      |
| `hash_valid` | out | 1     | High for 1 cycle when `hash_out` is valid      |
| `hash_out`   | out | 256   | SHA-256 digest (big-endian)                    |

---

## Input Padding Requirements

The core takes a **pre-padded** 512-bit block conforming to FIPS 180-4:

```
[message bytes] [0x80] [0x00...0x00] [64-bit message length in bits]
```

**You must pad the message externally** before asserting `block_valid`.

### Example: SHA256("abc")
```
Input: 0x61 0x62 0x63
Padded block (big-endian, 64 bytes):
  61 62 63 80 00 00 00 00  00 00 00 00 00 00 00 00
  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 18
                                               ^^^^ = 24 bits = length of "abc"
Expected digest: ba7816bf 8f01cfea 414140de 5dae2ec7
                 3b00361a 396177a9 cb410ff6 1f20015a
```

---

## Bitcoin Mining Integration

Bitcoin uses **double-SHA256** of the 80-byte block header:
```
digest = SHA256(SHA256(block_header[0:79]))
```

### Midstate Optimisation

For mining, the first 64 bytes of the block header are constant per job.
Pre-compute SHA256(header[0:63]) once → this is the **midstate**.

```
1. Run sha256_core with header[0:63] padded → get midstate H[0..7]
2. For each nonce trial:
   a. Assert init=1, load h_init_0..7 = midstate H[0..7]
   b. Feed block_in = SHA256_pad(header[64:79] | nonce)
   c. Feed result into second sha256_core instance for the outer SHA256
   d. Compare hash_out to target difficulty
```

### Example Instantiation for Mining

```verilog
// First SHA256 pass (midstate, run once per job)
sha256_core u_sha256_pass1 (
    .clk         (clk),
    .rst_n       (rst_n),
    .init        (1'b0),          // Use standard IVs
    .h_init_0    (32'b0), ...     // Not used
    .block_valid (job_valid),
    .block_in    (header_block0), // header[0:63] padded to 512 bits
    .hash_valid  (midstate_valid),
    .hash_out    (midstate)
);

// Second SHA256 pass (per-nonce, fully pipelined)
sha256_core u_sha256_pass2 (
    .clk         (clk),
    .rst_n       (rst_n),
    .init        (midstate_valid),    // Load midstate when ready
    .h_init_0    (midstate[255:224]),
    .h_init_1    (midstate[223:192]),
    .h_init_2    (midstate[191:160]),
    .h_init_3    (midstate[159:128]),
    .h_init_4    (midstate[127: 96]),
    .h_init_5    (midstate[ 95: 64]),
    .h_init_6    (midstate[ 63: 32]),
    .h_init_7    (midstate[ 31:  0]),
    .block_valid (nonce_valid),
    .block_in    (nonce_block),       // header[64:79]|nonce padded to 512 bits
    .hash_valid  (hash_valid_raw),
    .hash_out    (hash_raw)           // → feed to outer SHA256 core
);
```

---

## Synthesis Instructions

### Xilinx Vivado
```tcl
read_verilog sha256_functions.vh
read_verilog sha256_round.v
read_verilog sha256_core.v
read_xdc sha256_core.xdc
synth_design -top sha256_core -part xc7a100tcsg324-2
opt_design
place_design
route_design
report_timing_summary -file timing_report.txt
```

Enable retiming for better fclk:
```tcl
synth_design -top sha256_core -retiming
```

### Intel Quartus Prime
```
1. Add all .v and .vh files to project
2. Set sha256_core as top-level entity
3. Import sha256_core.sdc
4. Enable "Allow Register Retiming" in Fitter settings
5. Run Compilation → Timing Analysis
```

### Icarus Verilog (Simulation Only)
```bash
iverilog -g2005 -o sha256_tb sha256_tb.v sha256_core.v sha256_round.v
vvp sha256_tb
gtkwave sha256_tb.vcd
```

---

## Known SHA-256 Test Vectors

| Input                | Expected Hash (hex)                                              |
|----------------------|------------------------------------------------------------------|
| `""`  (empty)        | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `"abc"`              | `ba7816bf8f01cfea414140de5dae2ec73b00361a396177a9cb410ff61f20015a` |
| `"abcabc..."`(55B)  | `248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1`  |

---

## Design Notes

1. **No DSPs**: All arithmetic uses carry-chain adders (CARRY4/CARRY8 primitives).
   This maximises utilisation for mining arrays where DSPs are needed elsewhere.

2. **Message Schedule**: `W[0..63]` is computed combinationally from the registered
   `block_in`. For very high fclk (>300 MHz), you may want to pipeline the schedule
   expansion across 2-3 clock stages before the compression rounds.

3. **IV Pipeline**: The initial hash values are delay-matched through a 64-stage
   shift register so they arrive at the final adder in sync. This adds 64×8×32 = 16Kb
   of flip-flops but avoids any BRAM dependency and keeps the design portable.

4. **Retiming**: Enabling register retiming in Vivado (`synth_design -retiming`) can
   improve fclk by 10-20% by moving registers across the logic boundary between the
   message schedule and the compression rounds.

5. **Bitcoin nonce loop**: For a complete miner, drive `block_valid` every cycle
   with an incrementing nonce packed into `block_in[95:64]` (Bitcoin nonce field),
   and compare `hash_out[255:224]` (first word of inner hash) ≤ target after the
   outer SHA256 pass.

---

## License

This RTL is provided for educational and research purposes.
Ensure compliance with your local regulations regarding ASIC/FPGA mining hardware.
