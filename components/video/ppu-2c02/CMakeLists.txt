# SPDX-License-Identifier: Apache-2.0
rs_component(ppu_2c02 RTL rtl/ppu_2c02.sv rtl/ppu_2c02_rgb.sv TOPS ppu_2c02 ppu_2c02_rgb)
add_test(NAME "ppu_2c02_rgb is what tools/gen_rgb.py makes"
         COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_rgb.py --check)
add_subdirectory(sim)
