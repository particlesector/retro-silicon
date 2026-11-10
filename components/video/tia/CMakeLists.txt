# SPDX-License-Identifier: Apache-2.0
rs_component(tia RTL rtl/tia_player.sv rtl/tia_missile.sv rtl/tia_ball.sv rtl/tia_audio.sv rtl/tia.sv)
rs_component(tia_rgb RTL rtl/tia_rgb.sv)
add_test(NAME "tia_rgb is what tools/gen_rgb.py makes"
         COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_rgb.py --check)
