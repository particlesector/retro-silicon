# SPDX-License-Identifier: Apache-2.0
rs_component(paddles RTL rtl/paddles_rate.sv rtl/paddles.sv)
add_test(NAME "paddles_rate is what tools/gen_rate.py makes"
         COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_rate.py --check)
add_subdirectory(sim)
