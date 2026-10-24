# SPDX-License-Identifier: Apache-2.0
# The harness core: the Link interface, UART models, CRC32 and the tests, which
# any backend can run. A rig project adds its board backend on top of these.
add_library(rs_harness STATIC src/echo_test.cpp)
target_include_directories(rs_harness PUBLIC include)
target_compile_features(rs_harness PUBLIC cxx_std_20)
target_compile_options(rs_harness PRIVATE -Wall -Wextra)

# The sim backend: systems/uart-echo in Verilator at the board link's rate,
# 27 MHz / 18 = 1.5 Mbaud (SimLink::kClksPerBit).
add_library(rs_sim_link STATIC src/sim_link.cpp)
set_source_files_properties(src/sim_link.cpp PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
target_link_libraries(rs_sim_link PUBLIC rs_harness)
rs_verilate(rs_sim_link COMPONENT uart_echo PREFIX Vuart_echo_sim PARAMS CLKS_PER_BIT=18)

rs_sim_test(harness_test SOURCES tests/echo_test_test.cpp tests/sim_link_test.cpp)
target_link_libraries(harness_test PRIVATE rs_sim_link)
target_compile_definitions(harness_test PRIVATE RS_ECHO_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/echo_crc32.txt")
