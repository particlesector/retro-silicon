# SPDX-License-Identifier: Apache-2.0
# Bitstreams for the PYNQ-Z2, built when openXC7 is on PATH.
# Board tops: a system plus this board's pins. Linted with or without the tools.
rs_component(pynq_echo_top RTL rtl/pynq_echo_top.sv DEPENDS uart_echo)
rs_component(pynq_shell_ram_top RTL rtl/pynq_shell_ram_top.sv DEPENDS shell_ram)
rs_component(tmds_phy_xc7 RTL ../xilinx/rtl/tmds_phy_xc7.sv
             LINT ${PROJECT_SOURCE_DIR}/boards/xilinx/lint/xilinx_prims.sv)
rs_component(pynq_nes_top RTL rtl/pynq_nes_top.sv DEPENDS nes_bram tmds_phy_xc7
             LINT ${PROJECT_SOURCE_DIR}/boards/xilinx/lint/xilinx_prims.sv)

if(NOT RS_BITSTREAMS OR NOT RS_NEXTPNR_XILINX)
    return()
endif()

set(build ${CMAKE_CURRENT_SOURCE_DIR}/build.sh)

rs_board_bitstream(pynq_uart_echo BUILD ${build} VENDOR xilinx COMPONENT pynq_echo_top CST pins.xdc)
get_property(shell_ram_id GLOBAL PROPERTY RS_SHELL_RAM_BUILD_ID)
rs_board_bitstream(pynq_shell_ram BUILD ${build} VENDOR xilinx COMPONENT pynq_shell_ram_top CST pins.xdc
                   PARAMS BUILD_ID=${shell_ram_id})
get_property(nes_bram_id GLOBAL PROPERTY RS_NES_BRAM_BUILD_ID)
# The NES makes its own clocks (rtl/pynq_nes_top.sv): 46.40625 MHz for the
# system, 74.25 MHz for the HDMI pixels and 371.25 MHz for their serializers.
rs_board_bitstream(pynq_nes BUILD ${build} VENDOR xilinx COMPONENT pynq_nes_top CST nes.xdc
                   PARAMS BUILD_ID=${nes_bram_id})
