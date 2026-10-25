# SPDX-License-Identifier: Apache-2.0
rs_sim_test(ppu_2c02_test SOURCES ppu_test.cpp)
rs_verilate(ppu_2c02_test COMPONENT ppu_2c02)
