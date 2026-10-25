# SPDX-License-Identifier: Apache-2.0
# Bitstreams for the Tang Console 138K, built when OSS CAD Suite is on PATH.
# Board tops: a system plus this board's pins. Linted with or without the tools.
rs_component(console_echo_top RTL rtl/echo_top.sv DEPENDS uart_echo TOPS echo_top)
rs_component(console_shell_ram_top RTL rtl/shell_ram_top.sv DEPENDS shell_ram TOPS shell_ram_top)
rs_component(console_nes_top RTL rtl/nes_top.sv DEPENDS nes_bram TOPS nes_top)

if(NOT RS_BITSTREAMS)
    return()
endif()

set(build ${CMAKE_CURRENT_SOURCE_DIR}/build.sh)

# All at 50 MHz / 33 = 1.515 Mbaud, which the host's 1.5 Mbaud reads fine (1%).
rs_board_bitstream(console_uart_echo BUILD ${build} COMPONENT console_echo_top TOP echo_top CST pins.cst)
get_property(shell_ram_id GLOBAL PROPERTY RS_SHELL_RAM_BUILD_ID)
rs_board_bitstream(console_shell_ram BUILD ${build} COMPONENT console_shell_ram_top TOP shell_ram_top CST pins.cst
                   PARAMS BUILD_ID=${shell_ram_id})
get_property(nes_bram_id GLOBAL PROPERTY RS_NES_BRAM_BUILD_ID)
rs_board_bitstream(console_nes BUILD ${build} COMPONENT console_nes_top TOP nes_top CST pins.cst
                   PARAMS BUILD_ID=${nes_bram_id})
