# SPDX-License-Identifier: Apache-2.0
rs_sim_test(gb_roms_test SOURCES gb_roms_test.cpp)
rs_verilate(gb_roms_test COMPONENT gameboy PREFIX Vgameboy)
target_compile_definitions(gb_roms_test PRIVATE RS_TESTROMS="${RS_TESTROMS}"
    RS_GB_MANIFEST="${PROJECT_SOURCE_DIR}/testroms/manifest-gb.toml"
    RS_GB_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/gb_frames_crc32.txt")
