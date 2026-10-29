# SPDX-License-Identifier: Apache-2.0
# Helpers every component, system and board CMakeLists.txt uses.

include(Catch)

find_program(RS_YOSYS yosys)

# Board bitstreams build when nextpnr is on PATH, unless this is turned off.
# Xilinx boards also need openXC7's nextpnr-xilinx.
find_program(RS_NEXTPNR_HIMBAECHEL nextpnr-himbaechel)
find_program(RS_NEXTPNR_XILINX nextpnr-xilinx)
set(rs_have_pnr OFF)
if(RS_NEXTPNR_HIMBAECHEL)
    set(rs_have_pnr ON)
endif()
option(RS_BITSTREAMS "Build the boards' bitstreams" ${rs_have_pnr})

# rs_board_bitstream(<name> BUILD <board build.sh> COMPONENT <c> CST <file> [TOP <module>]
#                    [VENDOR gowin|xilinx] [PARAMS <NAME=VALUE>...] [CLOCKS <net=MHz>...]
#                    [SEED <n>])
#
# Builds ${CMAKE_BINARY_DIR}/fpga/<name>/<top>.fs (Gowin, the default) or
# <top>.bit (Xilinx) with a board's build script (CST, the pin constraints,
# relative to the calling directory) from target <name>_bitstream, whose
# BITSTREAM property holds that path. CLOCKS constrains clock nets the board
# makes (PLL and divider outputs; Gowin only, as Xilinx boards put them in
# their XDC). SEED fixes nextpnr's placement seed (Gowin only: the Xilinx
# build tries seeds itself). A missed timing constraint fails the build.
function(rs_board_bitstream name)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "BUILD;COMPONENT;CST;TOP;VENDOR;SEED" "PARAMS;CLOCKS")
    if(NOT arg_VENDOR)
        set(arg_VENDOR gowin)
    endif()
    set(ext fs)
    if(arg_VENDOR STREQUAL "xilinx")
        set(ext bit)
    endif()
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
    foreach(c IN LISTS arg_CLOCKS)
        list(APPEND params -k ${c})
    endforeach()
    if(arg_SEED)
        if(NOT arg_VENDOR STREQUAL "gowin")
            message(FATAL_ERROR "rs_board_bitstream(${name}): SEED is for Gowin builds")
        endif()
        list(APPEND params -s ${arg_SEED})
    endif()
    add_custom_command(
        OUTPUT ${dir}/${arg_TOP}.${ext}
        COMMAND ${arg_BUILD} ${params} -t ${arg_TOP} -c ${cst} -o ${dir} ${files}
        DEPENDS ${files} ${cst} ${arg_BUILD} ${PROJECT_SOURCE_DIR}/boards/${arg_VENDOR}/build.sh
        COMMENT "Building the ${name} bitstream"
        VERBATIM)
    add_custom_target(${name}_bitstream ALL DEPENDS ${dir}/${arg_TOP}.${ext})
    set_target_properties(${name}_bitstream PROPERTIES BITSTREAM ${dir}/${arg_TOP}.${ext})
endfunction()

# rs_component(<name> RTL <files...> [DEPENDS <components...>] [TOPS <modules...>] [LINT <files...>])
#
# Registers a component's RTL (paths relative to the calling directory) under
# <name>, after the RTL of every component it depends on, so later calls can
# verilate or synthesise it by name. Adds lint tests for each top module
# (default: <name>): Verilator -Wall, and, when Yosys is on PATH, Yosys's
# synthesis up to technology mapping plus its design checks (undriven or
# multiply driven signals, combinational loops). Board builds run the rest.
# LINT files (absolute paths) go to the lint tests only: stand-ins for a
# board's vendor primitives, which its own synthesis provides.
function(rs_component name)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "" "RTL;DEPENDS;TOPS;LINT")
    set(files)
    foreach(dep IN LISTS arg_DEPENDS)
        get_property(dep_files GLOBAL PROPERTY RS_RTL_${dep})
        if(NOT dep_files)
            message(FATAL_ERROR "rs_component(${name}): unknown component ${dep}; add it first")
        endif()
        list(APPEND files ${dep_files})
    endforeach()
    list(TRANSFORM arg_RTL PREPEND ${CMAKE_CURRENT_SOURCE_DIR}/)
    list(APPEND files ${arg_RTL})
    list(REMOVE_DUPLICATES files)
    set_property(GLOBAL PROPERTY RS_RTL_${name} ${files})

    if(NOT arg_TOPS)
        set(arg_TOPS ${name})
    endif()
    list(APPEND files ${arg_LINT})
    foreach(top IN LISTS arg_TOPS)
        add_test(NAME "lint verilator ${top}"
                 COMMAND ${VERILATOR_BIN_COMMAND} --lint-only -Wall --top-module ${top} ${files})
        if(RS_YOSYS)
            list(JOIN files " " file_args)
            add_test(NAME "lint yosys ${top}"
                     COMMAND ${RS_YOSYS} -q -p "read_verilog -sv ${file_args}; synth -top ${top} -run :fine; check -assert")
        endif()
    endforeach()
endfunction()

# rs_build_id(<out-var> <component>)
#
# A 32-bit build ID for a test-shell system: the first 8 hex digits of the
# SHA-256 of all its RTL, as a Verilog literal (32'h...) for a BUILD_ID
# parameter. CMake reconfigures when any of those files changes, so the ID
# always matches the RTL; the sim and the board report the same one.
function(rs_build_id out name)
    rs_rtl(files ${name})
    set(all "")
    foreach(f IN LISTS files)
        file(READ ${f} text)
        string(APPEND all "${text}")
    endforeach()
    string(SHA256 sha "${all}")
    string(SUBSTRING ${sha} 0 8 id)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${files})
    set(${out} "32'h${id}" PARENT_SCOPE)
endfunction()

# rs_rtl(<out-var> <component>): the component's RTL, dependencies first.
function(rs_rtl out name)
    get_property(files GLOBAL PROPERTY RS_RTL_${name})
    if(NOT files)
        message(FATAL_ERROR "rs_rtl: unknown component ${name}")
    endif()
    set(${out} ${files} PARENT_SCOPE)
endfunction()

# rs_verilate(<target> COMPONENT <name> [TOP <module>] [PREFIX <class>] [PARAMS <NAME=VALUE>...])
#
# Verilates a registered component into <target> with -Wall; TOP defaults to
# the component name, and PARAMS override top-level parameters.
function(rs_verilate target)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "COMPONENT;TOP;PREFIX" "PARAMS")
    rs_rtl(files ${arg_COMPONENT})
    if(NOT arg_TOP)
        set(arg_TOP ${arg_COMPONENT})
    endif()
    set(prefix)
    if(arg_PREFIX)
        set(prefix PREFIX ${arg_PREFIX})
    endif()
    list(TRANSFORM arg_PARAMS PREPEND -G OUTPUT_VARIABLE gparams)
    verilate(${target} SOURCES ${files} TOP_MODULE ${arg_TOP} ${prefix} VERILATOR_ARGS -Wall ${gparams})
    # Verilator's headers aren't -Wextra clean; as system headers they don't warn.
    target_include_directories(${target} SYSTEM PRIVATE ${VERILATOR_ROOT}/include ${VERILATOR_ROOT}/include/vltstd)
endfunction()

# rs_sim_test(<target> SOURCES <files...>)
#
# A Catch2 test executable whose test cases ctest runs one by one. Warnings
# apply to these sources only: Verilator's generated code isn't -Wextra clean.
function(rs_sim_test target)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "" "SOURCES")
    add_executable(${target} ${arg_SOURCES})
    set_source_files_properties(${arg_SOURCES} PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_link_libraries(${target} PRIVATE Catch2::Catch2WithMain)
    catch_discover_tests(${target})
endfunction()
