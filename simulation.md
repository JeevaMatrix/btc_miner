iverilog -g2005-sv -I sha256 -o miner_sim sha256/sha256_functions.vh sha256/sha256_round.v sha256/sha256_core.v job_loader.v nonce_ctrl.v difficulty_comparator.v bitcoin_miner_top.v bitcoin_miner_tb.v

vvp miner_sim

gtkwave bitcoin_miner_tb.vcd
