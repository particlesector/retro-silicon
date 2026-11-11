# SPDX-License-Identifier: Apache-2.0
# The harness core: the Link interface, UART models, CRC32 and the tests, which
# any backend can run. A rig project adds its board backend on top of these.
add_library(rs_harness STATIC src/a2600.cpp src/echo_test.cpp src/ines.cpp src/nes.cpp src/sdram_test.cpp src/shell.cpp
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
get_property(nes_axi_id GLOBAL PROPERTY RS_NES_AXI_BUILD_ID)
string(REPLACE "32'h" "0x" nes_axi_id_c ${nes_axi_id})
get_property(shell_axi_id GLOBAL PROPERTY RS_SHELL_AXI_BUILD_ID)
string(REPLACE "32'h" "0x" shell_axi_id_c ${shell_axi_id})
get_property(nes_id GLOBAL PROPERTY RS_NES_BUILD_ID)
string(REPLACE "32'h" "0x" nes_id_c ${nes_id})
get_property(a2600_id GLOBAL PROPERTY RS_A2600_BUILD_ID)
string(REPLACE "32'h" "0x" a2600_id_c ${a2600_id})
add_library(rs_sim_link STATIC src/sim_systems.cpp)
set_source_files_properties(src/sim_systems.cpp PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
target_link_libraries(rs_sim_link PUBLIC rs_harness)
rs_verilate(rs_sim_link COMPONENT uart_echo PREFIX Vuart_echo_sim PARAMS CLKS_PER_BIT=18)
rs_verilate(rs_sim_link COMPONENT shell_ram PREFIX Vshell_ram_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_ram_id})
rs_verilate(rs_sim_link COMPONENT shell_sdram PREFIX Vshell_sdram_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_sdram_id})
# As the Tang Console 138K builds it (boards/tang-console-138k/rtl/shell_sdram_top.sv).
rs_verilate(rs_sim_link COMPONENT shell_sdram PREFIX Vshell_sdram_x16_sim
            PARAMS CLKS_PER_BIT=33 IDLE_CLKS=500000 FREQ_MHZ=50 REFRESH_NS=7500 DQ_W=16 ROW_W=13 COL_W=9 RANKS=2
                   BUILD_ID=${shell_sdram_id})
rs_verilate(rs_sim_link COMPONENT shell_axi PREFIX Vshell_axi_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_axi_id})
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${nes_id})
# The NES as the Tang Nano 20K runs it with HDMI (boards/tang-nano-20k/rtl/nes_top.sv's
# parameters): 46.40625 MHz, keeping pace with its display, without save states.
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_hdmi_sim
            PARAMS CLKS_PER_BIT=31 IDLE_CLKS=464063 FREQ_MHZ=47 DOT_NUM=13 DOT_DEN=110 PACE=1 CHR_EXT=1 SAVE_STATE=0
                   BUILD_ID=${nes_id})
# The 20K's lean build (nes_lean): the same, DEBUG=0.
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_lean_sim
            PARAMS CLKS_PER_BIT=31 IDLE_CLKS=464063 FREQ_MHZ=47 DOT_NUM=13 DOT_DEN=110 PACE=1 CHR_EXT=1 SAVE_STATE=0
                   DEBUG=0 BUILD_ID=${nes_id})
# The NES as the Tang Console 138K runs it with HDMI (boards/tang-console-138k/rtl/nes_top.sv):
# PRG in its SDRAM module (two 16M x 16 chips on one bus), 256 KB of CHR in
# block RAM, the system at half the pixel clock (25 clocks a bit, dots at
# 35/242), keeping pace; and the same without the display.
set(nes_x16_params CLKS_PER_BIT=25 IDLE_CLKS=371875 FREQ_MHZ=38 DOT_NUM=35 DOT_DEN=242 CHR_AW=18
                   DQ_W=16 ROW_W=13 COL_W=9 RANKS=2 REFRESH_NS=7000 BUILD_ID=${nes_id})
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_x16_hdmi_sim PARAMS ${nes_x16_params} PACE=1)
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_x16_sim PARAMS ${nes_x16_params})
# The same without the display, for running ROMs whose CHR ROM is in the SDRAM.
rs_verilate(rs_sim_link COMPONENT nes_sdram PREFIX Vnes_ext_sim
            PARAMS CLKS_PER_BIT=31 IDLE_CLKS=464063 FREQ_MHZ=47 DOT_NUM=13 DOT_DEN=110 CHR_EXT=1 BUILD_ID=${nes_id})
# The NES as the PYNQ-Z2 runs it, its PRG in DDR3 through HP0 (an AXI memory
# model here): 37.125 MHz (25 clocks a bit, dots at 35/242), 256 KB of CHR, no display.
rs_verilate(rs_sim_link COMPONENT nes_axi PREFIX Vnes_axi_sim
            PARAMS CLKS_PER_BIT=25 IDLE_CLKS=371250 DOT_NUM=9 DOT_DEN=61 CHR_AW=18 BUILD_ID=${nes_axi_id})
# The 2600 at 27 MHz, colour clocks at 35/264 (NTSC's rate), with 64 KB of cartridge ROM: every
# bank-switching scheme's test cartridge fits.
rs_verilate(rs_sim_link COMPONENT a2600_sys PREFIX Va2600_sim PARAMS CLKS_PER_BIT=18 BUILD_ID=${a2600_id})
# ...and as the Tang Nano 20K runs it, with HDMI (boards/tang-nano-20k/rtl/a2600_top.sv's parameters):
# 46.40625 MHz, colour clocks at 7/89, its display on a 74.25 MHz pixel clock, the cartridge's ROM
# in the SDRAM (a2600_sdram, 512 KB of room); and the same without the display.
set(a2600_20k_params CLKS_PER_BIT=31 IDLE_CLKS=464063 CC_NUM=7 CC_DEN=89 FREQ_MHZ=47 BUILD_ID=${a2600_id})
rs_verilate(rs_sim_link COMPONENT a2600_sdram PREFIX Va2600_hdmi_sim PARAMS ${a2600_20k_params} VIDEO=1)
rs_verilate(rs_sim_link COMPONENT a2600_sdram PREFIX Va2600_ext_sim PARAMS ${a2600_20k_params})
target_include_directories(rs_sim_link PRIVATE ${PROJECT_SOURCE_DIR}/components/memory/sdram/sim
                                               ${PROJECT_SOURCE_DIR}/components/memory/axi-bridge/sim)
# The build IDs the models and bitstreams report, for runners to check.
target_compile_definitions(rs_sim_link PUBLIC RS_SHELL_RAM_BUILD_ID=${shell_ram_id_c}
                                              RS_SHELL_SDRAM_BUILD_ID=${shell_sdram_id_c}
                                              RS_SHELL_AXI_BUILD_ID=${shell_axi_id_c}
                                              RS_NES_AXI_BUILD_ID=${nes_axi_id_c}
                                              RS_NES_BUILD_ID=${nes_id_c}
                                              RS_A2600_BUILD_ID=${a2600_id_c})

rs_sim_test(harness_test SOURCES tests/echo_test_test.cpp tests/sim_link_test.cpp tests/shell_test.cpp
                               tests/sdram_test.cpp tests/nes_test.cpp tests/hdmi_test.cpp tests/a2600_test.cpp
                               tests/a2600_hdmi_test.cpp)
target_link_libraries(harness_test PRIVATE rs_sim_link)
target_include_directories(harness_test PRIVATE ${PROJECT_SOURCE_DIR}/components/video/hdmi/sim)
target_compile_definitions(harness_test PRIVATE
    RS_ECHO_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/echo_crc32.txt"
    RS_SHELL_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/shell_crc32.txt"
    RS_SDRAM_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/sdram_crc32.txt"
    RS_SDRAM_X16_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/sdram_x16_crc32.txt"
    RS_NES_TRACE_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_trace_crc32.txt"
    RS_NES_FRAMES_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_frames_crc32.txt"
    RS_NES_FRAMES_ONES_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_frames_ones_crc32.txt"
    RS_NES_FRAMES_LEAD6_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_frames_lead6_crc32.txt"
    RS_NES_FRAMES_LEAD7_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_frames_lead7_crc32.txt"
    RS_NES_AUDIO_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_audio_crc32.txt"
    RS_NES_HDMI_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/nes_hdmi_crc32.txt"
    RS_PPU_RGB_SV="${PROJECT_SOURCE_DIR}/components/video/ppu-2c02/rtl/ppu_2c02_rgb.sv"
    RS_A2600_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/a2600_frames_crc32.txt"
    RS_A2600_AUDIO_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/a2600_audio_crc32.txt"
    RS_A2600_PADDLES="${CMAKE_CURRENT_SOURCE_DIR}/golden/a2600_paddles.txt"
    RS_A2600_HDMI_GOLDEN="${CMAKE_CURRENT_SOURCE_DIR}/golden/a2600_hdmi_crc32.txt"
    RS_TIA_RGB_SV="${PROJECT_SOURCE_DIR}/components/video/tia/rtl/tia_rgb.sv"
    RS_TESTROMS="${RS_TESTROMS}")
