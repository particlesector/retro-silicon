# SPDX-License-Identifier: Apache-2.0
rs_sim_test(bram_mem_test SOURCES bram_mem_test.cpp)
rs_verilate(bram_mem_test COMPONENT bram_mem PARAMS AW=10 IW=12)
