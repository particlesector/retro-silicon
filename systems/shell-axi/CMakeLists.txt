# SPDX-License-Identifier: Apache-2.0
rs_component(shell_axi RTL rtl/shell_axi.sv DEPENDS por test_shell axi_bridge)
rs_build_id(id shell_axi)
set_property(GLOBAL PROPERTY RS_SHELL_AXI_BUILD_ID ${id})
