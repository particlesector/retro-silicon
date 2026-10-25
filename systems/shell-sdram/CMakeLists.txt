# SPDX-License-Identifier: Apache-2.0
rs_component(shell_sdram RTL rtl/shell_sdram.sv DEPENDS por test_shell sdram_ctrl)
rs_build_id(id shell_sdram)
set_property(GLOBAL PROPERTY RS_SHELL_SDRAM_BUILD_ID ${id})
