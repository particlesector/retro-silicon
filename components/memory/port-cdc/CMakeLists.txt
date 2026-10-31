# SPDX-License-Identifier: Apache-2.0
rs_component(mem_port_cdc RTL rtl/mem_port_cdc.sv DEPENDS cdc_sync)
add_subdirectory(sim)
