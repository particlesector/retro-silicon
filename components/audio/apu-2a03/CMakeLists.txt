# SPDX-License-Identifier: Apache-2.0
rs_component(apu_2a03
    RTL rtl/apu_length.sv rtl/apu_envelope.sv rtl/apu_frame.sv rtl/apu_pulse.sv
        rtl/apu_triangle.sv rtl/apu_noise.sv rtl/apu_dmc.sv rtl/apu_2a03.sv rtl/apu_mixer.sv
    TOPS apu_2a03 apu_mixer)
add_test(NAME "apu_mixer is what tools/gen_mixer.py makes"
         COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_mixer.py --check)
add_subdirectory(sim)
