# =============================================================================
# File        : sha256_core.sdc
# Project     : SHA-256 Core for FPGA Bitcoin Miner
# Description : Intel/Altera Quartus Prime Timing Constraints
#               Targeting Cyclone V / Arria 10 / Stratix 10
#
# Typical Achievable fclk:
#   Cyclone V   : ~150 MHz  (6.67 ns)
#   Arria 10    : ~400 MHz  (2.50 ns)
#   Stratix 10  : ~500 MHz  (2.00 ns)
# =============================================================================

# -----------------------------------------------------------------------------
# Primary Clock — adjust period for your device and speed grade
# -----------------------------------------------------------------------------
create_clock -period 6.667 -name clk [get_ports clk]

# -----------------------------------------------------------------------------
# Derive PLL clocks (if using a PLL for the mining clock domain)
# -----------------------------------------------------------------------------
# derive_pll_clocks

# -----------------------------------------------------------------------------
# I/O timing
# -----------------------------------------------------------------------------
set_input_delay  -clock clk -max 1.0 [get_ports {block_in[*] block_valid rst_n init}]
set_input_delay  -clock clk -min 0.2 [get_ports {block_in[*] block_valid rst_n init}]
set_output_delay -clock clk -max 1.0 [get_ports {hash_out[*] hash_valid}]
set_output_delay -clock clk -min 0.2 [get_ports {hash_out[*] hash_valid}]

# -----------------------------------------------------------------------------
# False paths
# -----------------------------------------------------------------------------
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports init]

# -----------------------------------------------------------------------------
# Timing Optimization directives
# Enable register retiming via Quartus Fitter settings:
#   Assignments → Settings → Compiler Settings → Advanced → Allow Register Retiming
# -----------------------------------------------------------------------------
