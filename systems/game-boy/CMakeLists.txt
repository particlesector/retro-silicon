# SPDX-License-Identifier: Apache-2.0
rs_component(gameboy RTL rtl/gb_timer.sv rtl/gb_serial.sv rtl/gb_joypad.sv rtl/gb_ppu.sv
             rtl/gameboy.sv DEPENDS cpu_sm83 apu_gb)
rs_component(gb_video RTL rtl/gb_video.sv DEPENDS por cdc_sync crc32 hdmi)
rs_component(gb_sys RTL rtl/gb_sys.sv DEPENDS gameboy gb_video resampler por clock_enable crc32 test_shell)
rs_build_id(gb_id gb_sys)
set_property(GLOBAL PROPERTY RS_GB_BUILD_ID ${gb_id})
add_subdirectory(sim)
