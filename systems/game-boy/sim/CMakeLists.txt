# SPDX-License-Identifier: Apache-2.0
rs_component(gb_cart_top RTL gb_cart_top.sv DEPENDS gameboy gb_cart)
rs_sim_test(gb_roms_test SOURCES gb_roms_test.cpp)
rs_verilate(gb_roms_test COMPONENT gb_cart_top PREFIX Vgb_cart_top)
target_compile_definitions(gb_roms_test PRIVATE RS_TESTROMS="${RS_TESTROMS}"
    RS_GB_MANIFEST="${PROJECT_SOURCE_DIR}/testroms/manifest-gb.toml"
    RS_GB_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/gb_frames_crc32.txt"
    RS_GB_AUDIO_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/gb_audio_crc32.txt")
rs_sim_test(gb_cart_test SOURCES gb_cart_test.cpp)
rs_verilate(gb_cart_test COMPONENT gb_cart PREFIX Vgb_cart)
