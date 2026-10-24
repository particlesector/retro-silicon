# SPDX-License-Identifier: Apache-2.0
rs_sim_test(uart_echo_test SOURCES uart_echo_test.cpp)
target_link_libraries(uart_echo_test PRIVATE rs_harness)  # rig/uart_model.hpp
rs_verilate(uart_echo_test COMPONENT uart_echo PREFIX Vuart_echo_3m PARAMS CLKS_PER_BIT=9)
rs_verilate(uart_echo_test COMPONENT uart_echo PREFIX Vuart_echo_115k PARAMS CLKS_PER_BIT=234)
