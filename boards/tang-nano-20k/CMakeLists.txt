# SPDX-License-Identifier: Apache-2.0
# Bitstreams for the Tang Nano 20K, built when OSS CAD Suite is on PATH.
# Board tops: a system plus this board's pins. Linted with or without the tools.
rs_component(shell_sdram_top RTL rtl/shell_sdram_top.sv DEPENDS shell_sdram)
rs_component(tmds_phy RTL ../gowin/rtl/tmds_phy.sv
             LINT ${PROJECT_SOURCE_DIR}/boards/gowin/lint/gowin_prims.sv)
rs_component(nes_top RTL rtl/nes_top.sv DEPENDS nes_sdram tmds_phy
             LINT ${PROJECT_SOURCE_DIR}/boards/gowin/lint/gowin_prims.sv)

if(NOT RS_BITSTREAMS)
    return()
endif()

set(build ${CMAKE_CURRENT_SOURCE_DIR}/build.sh)

# Both at 1.5 Mbaud (27 MHz / 18), the rate SimLink models, on the same pins.
rs_board_bitstream(uart_echo BUILD ${build} COMPONENT uart_echo CST uart_echo.cst PARAMS CLKS_PER_BIT=18)
get_property(shell_ram_id GLOBAL PROPERTY RS_SHELL_RAM_BUILD_ID)
rs_board_bitstream(shell_ram BUILD ${build} COMPONENT shell_ram CST uart_echo.cst PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_ram_id})
get_property(shell_sdram_id GLOBAL PROPERTY RS_SHELL_SDRAM_BUILD_ID)
rs_board_bitstream(shell_sdram BUILD ${build} COMPONENT shell_sdram_top CST uart_echo.cst PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_sdram_id})
get_property(nes_id GLOBAL PROPERTY RS_NES_BUILD_ID)
# The NES makes its own clocks (rtl/nes_top.sv): 46.40625 MHz for the system,
# 74.25 MHz for the HDMI pixels and 371.25 MHz for their serializers.
# nextpnr doesn't check hold for Gowin parts, and some placements that meet
# timing fail on the chip: with HDMI audio, seeds 2 and 3 gave wrong HDMI
# frames, while 1, 4 and 5 matched the sim (and with the APU alone, seed 1
# lost palette bits). Seed 5's passes every board test. Re-check on the
# board whenever the RTL changes.
rs_board_bitstream(nes BUILD ${build} COMPONENT nes_top CST nes.cst PARAMS BUILD_ID=${nes_id}
                   CLOCKS sclk=46.40625 pclk=74.25 fclk=371.25 SEED 5)
