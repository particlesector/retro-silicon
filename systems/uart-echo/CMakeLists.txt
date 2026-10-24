# SPDX-License-Identifier: Apache-2.0
rs_component(uart_echo RTL rtl/uart_echo.sv DEPENDS por uart fifo)
add_subdirectory(sim)
