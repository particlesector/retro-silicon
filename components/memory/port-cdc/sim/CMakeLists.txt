# SPDX-License-Identifier: Apache-2.0
rs_sim_test(mem_port_cdc_test SOURCES mem_port_cdc_test.cpp)
rs_verilate(mem_port_cdc_test COMPONENT mem_port_cdc PREFIX Vmem_port_cdc PARAMS AW=12 DW=64)
