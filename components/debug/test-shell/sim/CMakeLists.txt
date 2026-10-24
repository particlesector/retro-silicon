# SPDX-License-Identifier: Apache-2.0
rs_sim_test(test_shell_test SOURCES test_shell_test.cpp)
target_link_libraries(test_shell_test PRIVATE rs_harness)
# A fast bit rate and a short stall timeout keep the tests quick; the board
# build uses the defaults.
rs_verilate(test_shell_test COMPONENT test_shell PREFIX Vtest_shell
    PARAMS CLKS_PER_BIT=4 IDLE_CLKS=2700 BUILD_ID=32'h12345678)
