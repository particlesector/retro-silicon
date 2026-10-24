# SPDX-License-Identifier: Apache-2.0
# Helpers every component, system and board CMakeLists.txt uses.

include(Catch)

find_program(RS_YOSYS yosys)

# rs_component(<name> RTL <files...> [DEPENDS <components...>] [TOPS <modules...>])
#
# Registers a component's RTL (paths relative to the calling directory) under
# <name>, after the RTL of every component it depends on, so later calls can
# verilate or synthesise it by name. Adds lint tests for each top module
# (default: <name>): Verilator -Wall, and Yosys synthesis when Yosys is on PATH.
function(rs_component name)
    cmake_parse_arguments(PARSE_ARGV 1 arg "" "" "RTL;DEPENDS;TOPS")
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
    foreach(top IN LISTS arg_TOPS)
        add_test(NAME "lint verilator ${top}"
                 COMMAND ${VERILATOR_BIN_COMMAND} --lint-only -Wall --top-module ${top} ${files})
        if(RS_YOSYS)
            list(JOIN files " " file_args)
            add_test(NAME "lint yosys ${top}"
                     COMMAND ${RS_YOSYS} -q -p "read_verilog -sv ${file_args}; synth -top ${top}")
        endif()
    endforeach()
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
