# =============================================================================
# File        : sha256_core.xdc
# Project     : SHA-256 Core for FPGA Bitcoin Miner
# Description : Xilinx Design Constraints for sha256_core
#               Targeting Xilinx Artix-7 / Kintex-7 / UltraScale+
#               Adjust clock period for your specific device and speed grade.
#
# Typical Achievable fclk:
#   Artix-7 -2  : ~180 MHz  (5.55 ns period)
#   Kintex-7 -2 : ~230 MHz  (4.35 ns period)
#   UltraScale+ : ~350 MHz  (2.86 ns period)
#   Cyclone V   : ~150 MHz  (via equivalent Quartus SDC)
# =============================================================================

# -----------------------------------------------------------------------------
# Primary Clock — adjust pin and period for your board
# -----------------------------------------------------------------------------
create_clock -period 5.000 -name clk [get_ports clk]

# -----------------------------------------------------------------------------
# Input / Output Timing (relax as needed, these are reasonable defaults)
# -----------------------------------------------------------------------------
set_input_delay  -clock clk -max 1.000 [get_ports {block_in[*] block_valid rst_n init}]
set_input_delay  -clock clk -min 0.200 [get_ports {block_in[*] block_valid rst_n init}]

set_output_delay -clock clk -max 1.000 [get_ports {hash_out[*] hash_valid}]
set_output_delay -clock clk -min 0.200 [get_ports {hash_out[*] hash_valid}]

# -----------------------------------------------------------------------------
# False Paths — reset is multi-cycle, constants don't need timing analysis
# -----------------------------------------------------------------------------
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports init]

# -----------------------------------------------------------------------------
# Multicycle Path for IV pipeline (shifts once per round, not every ns)
# Comment out if your fclk target is aggressive and you want full analysis.
# -----------------------------------------------------------------------------
# set_multicycle_path -from [get_cells {iv_pipe_h*}] -setup 2
# set_multicycle_path -from [get_cells {iv_pipe_h*}] -hold 1

# -----------------------------------------------------------------------------
# Pipelining Hint: enable register retiming for adder chains
# (Vivado: set via Synthesis settings → Strategy → Retiming ON)
# -----------------------------------------------------------------------------
# set_property RETIMING true [get_cells -hier -filter {REF_NAME =~ sha256_round*}]

# -----------------------------------------------------------------------------
# Floorplan hint (optional): keep pipeline stages in a single SLR
# Uncomment and adjust Pblock range for your device
# -----------------------------------------------------------------------------
# create_pblock pb_sha256
# add_cells_to_pblock [pb_sha256] [get_cells {dut}]
# resize_pblock [pb_sha256] -add {SLICE_X0Y0:SLICE_X99Y299}
