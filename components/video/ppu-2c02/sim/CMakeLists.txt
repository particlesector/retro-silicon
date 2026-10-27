# SPDX-License-Identifier: Apache-2.0
rs_sim_test(ppu_2c02_test SOURCES ppu_test.cpp)
rs_verilate(ppu_2c02_test COMPONENT ppu_2c02 TOP ppu_2c02 PREFIX Vppu_2c02)
rs_sim_test(ppu_2c02_rgb_test SOURCES rgb_test.cpp)
rs_verilate(ppu_2c02_rgb_test COMPONENT ppu_2c02 TOP ppu_2c02_rgb PREFIX Vppu_2c02_rgb)
