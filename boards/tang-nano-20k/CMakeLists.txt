# SPDX-License-Identifier: Apache-2.0
# Bitstreams for the Tang Nano 20K, built when OSS CAD Suite is on PATH.
find_program(RS_NEXTPNR_HIMBAECHEL nextpnr-himbaechel)
set(have_tools OFF)
if(RS_NEXTPNR_HIMBAECHEL)
    set(have_tools ON)
endif()
option(RS_BITSTREAMS "Build Tang Nano 20K bitstreams" ${have_tools})
if(NOT RS_BITSTREAMS)
    return()
endif()

set(RS_TANG_BUILD ${CMAKE_CURRENT_SOURCE_DIR}/build.sh)

# rs_tang_bitstream(<name> COMPONENT <c> CST <file> [TOP <module>] [PARAMS <NAME=VALUE>...])
#
# Builds ${CMAKE_BINARY_DIR}/fpga/<name>/<top>.fs from target <name>_bitstream,
# whose BITSTREAM property holds that path. A missed timing constraint fails the build.
function(rs_tang_bitstream name)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "COMPONENT;CST;TOP" "PARAMS")
    rs_rtl(files ${arg_COMPONENT})
    if(NOT arg_TOP)
        set(arg_TOP ${arg_COMPONENT})
    endif()
    set(cst ${CMAKE_CURRENT_SOURCE_DIR}/${arg_CST})
    set(dir ${CMAKE_BINARY_DIR}/fpga/${name})
    set(params)
    foreach(p IN LISTS arg_PARAMS)
        list(APPEND params -g ${p})
    endforeach()
    add_custom_command(
        OUTPUT ${dir}/${arg_TOP}.fs
        COMMAND ${RS_TANG_BUILD} ${params} -t ${arg_TOP} -c ${cst} -o ${dir} ${files}
        DEPENDS ${files} ${cst} ${RS_TANG_BUILD}
        COMMENT "Building the ${name} bitstream"
        VERBATIM)
    add_custom_target(${name}_bitstream ALL DEPENDS ${dir}/${arg_TOP}.fs)
    set_target_properties(${name}_bitstream PROPERTIES BITSTREAM ${dir}/${arg_TOP}.fs)
endfunction()

# Both at 1.5 Mbaud (27 MHz / 18), the rate SimLink models, on the same pins.
rs_tang_bitstream(uart_echo COMPONENT uart_echo CST uart_echo.cst PARAMS CLKS_PER_BIT=18)
get_property(shell_ram_id GLOBAL PROPERTY RS_SHELL_RAM_BUILD_ID)
rs_tang_bitstream(shell_ram COMPONENT shell_ram CST uart_echo.cst PARAMS CLKS_PER_BIT=18 BUILD_ID=${shell_ram_id})
