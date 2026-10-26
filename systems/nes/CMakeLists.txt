# SPDX-License-Identifier: Apache-2.0
rs_component(nes RTL rtl/nes.sv
             DEPENDS por clock_enable crc32 test_shell video_probe mem_arbiter save_state_ctrl cpu_6502 ppu_2c02)
rs_component(nes_video RTL rtl/nes_video.sv DEPENDS por cdc_sync crc32 line_scaler ppu_2c02 hdmi)
rs_component(nes_sdram RTL rtl/nes_sdram.sv DEPENDS nes nes_video sdram_ctrl)
rs_component(nes_bram RTL rtl/nes_bram.sv DEPENDS nes nes_video bram_mem)
rs_build_id(sdram_id nes_sdram)
set_property(GLOBAL PROPERTY RS_NES_BUILD_ID ${sdram_id})
rs_build_id(bram_id nes_bram)
set_property(GLOBAL PROPERTY RS_NES_BRAM_BUILD_ID ${bram_id})
