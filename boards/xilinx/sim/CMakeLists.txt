# SPDX-License-Identifier: Apache-2.0
# tmds_phy_xc7 with the lint stand-ins for its primitives: each OSERDESE2
# passes its first bit straight through, enough to check which channel comes
# out on which pins.
rs_sim_test(tmds_phy_xc7_test SOURCES tmds_phy_xc7_test.cpp)
rs_rtl(tmds_phy_xc7_files tmds_phy_xc7)
verilate(tmds_phy_xc7_test SOURCES ${tmds_phy_xc7_files} ${PROJECT_SOURCE_DIR}/boards/xilinx/lint/xilinx_prims.sv
         TOP_MODULE tmds_phy_xc7 VERILATOR_ARGS -Wall)
target_include_directories(tmds_phy_xc7_test SYSTEM PRIVATE ${VERILATOR_ROOT}/include ${VERILATOR_ROOT}/include/vltstd)
