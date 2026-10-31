# SPDX-License-Identifier: Apache-2.0
rs_sim_test(mem_cache_test SOURCES mem_cache_test.cpp)
rs_verilate(mem_cache_test COMPONENT mem_cache PARAMS AW=16 IDX=6)
rs_verilate(mem_cache_test COMPONENT mem_cache PREFIX Vmem_cache_nopf PARAMS AW=16 IDX=6 PREFETCH=0)
