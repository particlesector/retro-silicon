# SPDX-License-Identifier: Apache-2.0
rs_sim_test(axi_bridge_test SOURCES axi_bridge_test.cpp)
rs_verilate(axi_bridge_test COMPONENT axi_bridge PARAMS AW=12 BASE=32'h10000000)
