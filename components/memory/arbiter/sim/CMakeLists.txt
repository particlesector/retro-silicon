# SPDX-License-Identifier: Apache-2.0
rs_sim_test(mem_arbiter_test SOURCES mem_arbiter_test.cpp)
rs_verilate(mem_arbiter_test COMPONENT mem_arbiter PARAMS N=3 AW=10)
