# SPDX-License-Identifier: Apache-2.0
rs_sim_test(uart_test SOURCES uart_test.cpp)
target_link_libraries(uart_test PRIVATE rs_harness)  # rig/uart_model.hpp
rs_verilate(uart_test COMPONENT uart TOP uart_rx PREFIX Vuart_rx_9 PARAMS CLKS_PER_BIT=9)
rs_verilate(uart_test COMPONENT uart TOP uart_rx PREFIX Vuart_rx_234 PARAMS CLKS_PER_BIT=234)
rs_verilate(uart_test COMPONENT uart TOP uart_tx PREFIX Vuart_tx_9 PARAMS CLKS_PER_BIT=9)
rs_verilate(uart_test COMPONENT uart TOP uart_tx PREFIX Vuart_tx_234 PARAMS CLKS_PER_BIT=234)
