# SPDX-License-Identifier: Apache-2.0
rs_component(gameboy RTL rtl/gb_timer.sv rtl/gb_serial.sv rtl/gb_joypad.sv rtl/gb_ppu.sv
             rtl/gameboy.sv DEPENDS cpu_sm83 apu_gb)
rs_component(gb_cart RTL rtl/gb_cart.sv)
rs_component(gb_video RTL rtl/gb_color.sv rtl/gb_video.sv DEPENDS por cdc_sync crc32 hdmi)
rs_component(gb_sys RTL rtl/gb_sys.sv DEPENDS gameboy gb_cart gb_video resampler por clock_enable crc32 test_shell)
rs_component(gb_sdram RTL rtl/gb_sdram.sv DEPENDS gb_sys sdram_ctrl por)
rs_component(gb_axi RTL rtl/gb_axi.sv DEPENDS gb_sys mem_cache mem_port_cdc axi_bridge por)
rs_build_id(gb_id gb_sdram)
rs_build_id(gb_axi_id gb_axi)
set_property(GLOBAL PROPERTY RS_GB_AXI_BUILD_ID ${gb_axi_id})
set_property(GLOBAL PROPERTY RS_GB_BUILD_ID ${gb_id})
add_subdirectory(sim)
