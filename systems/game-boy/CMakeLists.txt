# SPDX-License-Identifier: Apache-2.0
rs_component(gameboy RTL rtl/gb_timer.sv rtl/gb_serial.sv rtl/gb_joypad.sv rtl/gb_ppu.sv
             rtl/gb_apu_regs.sv rtl/gameboy.sv DEPENDS cpu_sm83)
add_subdirectory(sim)
