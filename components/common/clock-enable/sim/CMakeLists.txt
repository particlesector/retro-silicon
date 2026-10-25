# SPDX-License-Identifier: Apache-2.0
rs_sim_test(clock_enable_test SOURCES clock_enable_test.cpp)
rs_verilate(clock_enable_test COMPONENT clock_enable PREFIX Vce_nes PARAMS NUM=35 DEN=176)
rs_verilate(clock_enable_test COMPONENT clock_enable PREFIX Vce_half PARAMS NUM=1 DEN=2)
rs_verilate(clock_enable_test COMPONENT clock_enable PREFIX Vce_all PARAMS NUM=7 DEN=7)
