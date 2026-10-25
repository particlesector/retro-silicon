# SPDX-License-Identifier: Apache-2.0
# Two regions: 300 bytes at 0x10 and 5 at 0x01000200 (region 0 in the low word).
rs_sim_test(save_state_ctrl_test SOURCES save_state_ctrl_test.cpp)
rs_verilate(save_state_ctrl_test COMPONENT save_state_ctrl
            PARAMS NREG=2 BASES=64'h01000200_00000010 LENS=64'h00000005_0000012C AW=9)
