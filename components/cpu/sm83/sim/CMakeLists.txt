# SPDX-License-Identifier: Apache-2.0
rs_sim_test(cpu_sm83_test SOURCES sst_test.cpp cpu_test.cpp)
rs_verilate(cpu_sm83_test COMPONENT cpu_sm83)
target_compile_definitions(cpu_sm83_test PRIVATE RS_TESTROMS="${RS_TESTROMS}")
