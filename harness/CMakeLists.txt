# SPDX-License-Identifier: Apache-2.0
# The harness core: the Link interface, UART models, CRC32 and the tests, which
# any backend can run. A rig project adds its board backend on top of these.
add_library(rs_harness STATIC src/echo_test.cpp src/ines.cpp src/nes.cpp src/sdram_test.cpp src/shell.cpp
                             src/shell_test.cpp src/sim_link.cpp)
target_include_directories(rs_harness PUBLIC include)
target_compile_features(rs_harness PUBLIC cxx_std_20)
target_compile_options(rs_harness PRIVATE -Wall -Wextra)

# The sim backend: this repo's systems in Verilator at the board link's rate,
# 27 MHz / 18 = 1.5 Mbaud (SimLink::kClksPerBit), with the same build IDs.
get_property(shell_ram_id GLOBAL PROPERTY RS_SHELL_RAM_BUILD_ID)
string(REPLACE "32'h" "0x" shell_ram_id_c ${shell_ram_id})
get_property(shell_sdram_id GLOBAL PROPERTY RS_SHELL_SDRAM_BUILD_ID)
string(REPLACE "32'h" "0x" shell_sdram_id_c ${shell_sdram_id})
get_property(nes_id GLOBAL PROPERTY RS_NES_BUILD_ID)
string(REPLACE "32'h" "0x" nes_id_c ${nes_id})
get_property(nes_bram_id GLOBAL PROPERTY RS_NES_BRAM_BUILD_ID)
string(REPLACE "32'h" "0x" nes_bram_id_c ${nes_bram_id})
add_library(rs_sim_link STATIC src/sim_systems.cpp)
set_source_files_properties(src/sim_systems.cpp PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
target_link_libraries(rs_sim_link PUBLIC rs_harness)
rs_verilate(rs_sim_link COMPONENT uart_echo PREFIX Vuart_echo_sim PARAMS CLKS_PER_BIT=18)
rs_verilate(rs_sim_link COMPONENT shell_ram PREFIX Vshell_ram_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_ram_id})
rs_verilate(rs_sim_link COMPONENT shell_sdram PREFIX Vshell_sdram_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_sdram_id})
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${nes_id})
# The NES as the Tang Console 138K runs it: block RAM, and a 50 MHz clock's
# rates (1.515 Mbaud, and the dot rate at 189/1760 of the clock).
rs_verilate(rs_sim_link COMPONENT nes_bram PREFIX Vnes_bram_sim
            PARAMS CLKS_PER_BIT=33 IDLE_CLKS=500000 DOT_NUM=189 DOT_DEN=1760 BUILD_ID=${nes_bram_id})
# The NES as the Tang Nano 20K runs it with HDMI (boards/tang-nano-20k/rtl/nes_top.sv's
# parameters): 46.40625 MHz, and keeping pace with its display.
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_hdmi_sim
            PARAMS CLKS_PER_BIT=31 IDLE_CLKS=464063 FREQ_MHZ=47 DOT_NUM=14 DOT_DEN=121 PACE=1 BUILD_ID=${nes_id})
target_include_directories(rs_sim_link PRIVATE ${PROJECT_SOURCE_DIR}/components/memory/sdram/sim)
# The build IDs the models and bitstreams report, for runners to check.
target_compile_definitions(rs_sim_link PUBLIC RS_SHELL_RAM_BUILD_ID=${shell_ram_id_c}
                                              RS_SHELL_SDRAM_BUILD_ID=${shell_sdram_id_c}
                                              RS_NES_BUILD_ID=${nes_id_c}
                                              RS_NES_BRAM_BUILD_ID=${nes_bram_id_c})

rs_sim_test(harness_test SOURCES tests/echo_test_test.cpp tests/sim_link_test.cpp tests/shell_test.cpp
                               tests/sdram_test.cpp tests/nes_test.cpp tests/hdmi_test.cpp)
target_link_libraries(harness_test PRIVATE rs_sim_link)
target_include_directories(harness_test PRIVATE ${PROJECT_SOURCE_DIR}/components/video/hdmi/sim)
target_compile_definitions(harness_test PRIVATE
    RS_ECHO_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/echo_crc32.txt"
    RS_SHELL_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/shell_crc32.txt"
    RS_SDRAM_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/sdram_crc32.txt"
    RS_NES_TRACE_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_trace_crc32.txt"
    RS_NES_FRAMES_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_frames_crc32.txt"
    RS_NES_HDMI_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_hdmi_crc32.txt"
    RS_PPU_RGB_SV="${PROJECT_SOURCE_DIR}/components/video/ppu-2c02/rtl/ppu_2c02_rgb.sv"
    RS_TESTROMS="${RS_TESTROMS}")
