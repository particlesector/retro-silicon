# SPDX-License-Identifier: Apache-2.0
rs_component(nes RTL rtl/nes.sv DEPENDS por crc32 test_shell sdram_ctrl cpu_6502)
rs_build_id(id nes)
set_property(GLOBAL PROPERTY RS_NES_BUILD_ID ${id})
