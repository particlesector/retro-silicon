# SPDX-License-Identifier: Apache-2.0
rs_component(shell_ram RTL rtl/shell_ram.sv DEPENDS por test_shell)
rs_build_id(id shell_ram)
set_property(GLOBAL PROPERTY RS_SHELL_RAM_BUILD_ID ${id})
