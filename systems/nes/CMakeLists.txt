# SPDX-License-Identifier: Apache-2.0
rs_component(nes RTL rtl/nes.sv DEPENDS por clock_enable crc32 test_shell video_probe sdram_ctrl cpu_6502 ppu_2c02)
rs_build_id(id nes)
set_property(GLOBAL PROPERTY RS_NES_BUILD_ID ${id})
