# SPDX-License-Identifier: Apache-2.0
rs_component(uart RTL rtl/uart_rx.sv rtl/uart_tx.sv TOPS uart_rx uart_tx)
add_subdirectory(sim)
