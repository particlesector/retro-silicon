# SPDX-License-Identifier: Apache-2.0
rs_component(apu_2a03
    RTL rtl/apu_length.sv rtl/apu_envelope.sv rtl/apu_frame.sv rtl/apu_pulse.sv
        rtl/apu_triangle.sv rtl/apu_noise.sv rtl/apu_dmc.sv rtl/apu_2a03.sv)
add_subdirectory(sim)
