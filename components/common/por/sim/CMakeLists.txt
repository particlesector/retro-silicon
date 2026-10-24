# SPDX-License-Identifier: Apache-2.0
rs_sim_test(por_test SOURCES por_test.cpp)
rs_verilate(por_test COMPONENT por PREFIX Vpor_16)
rs_verilate(por_test COMPONENT por PREFIX Vpor_1 PARAMS CYCLES=1)
