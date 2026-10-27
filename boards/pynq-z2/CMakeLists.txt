# SPDX-License-Identifier: Apache-2.0
# Bitstreams for the PYNQ-Z2, built when openXC7 is on PATH.
# Board tops: a system plus this board's pins. Linted with or without the tools.
rs_component(pynq_echo_top RTL rtl/pynq_echo_top.sv DEPENDS uart_echo)

if(NOT RS_BITSTREAMS OR NOT RS_NEXTPNR_XILINX)
    return()
endif()

set(build ${CMAKE_CURRENT_SOURCE_DIR}/build.sh)

rs_board_bitstream(pynq_uart_echo BUILD ${build} VENDOR xilinx COMPONENT pynq_echo_top CST pins.xdc)
