# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.28)
project(retro_silicon LANGUAGES CXX)

# Works standalone or as a subdirectory of a rig project that adds its own
# backends; either way every test below lands in the same ctest run.
find_package(verilator REQUIRED HINTS $ENV{VERILATOR_ROOT})
find_package(Catch2 3 REQUIRED)
if(PROJECT_IS_TOP_LEVEL)
    include(CTest)
endif()

include(cmake/RetroSilicon.cmake)

# Dependencies first: rs_component needs the components it depends on.
add_subdirectory(components/common/crc32)
add_subdirectory(components/common/fifo)
add_subdirectory(components/common/por)
add_subdirectory(components/common/uart)
add_subdirectory(components/debug/test-shell)
add_subdirectory(systems/uart-echo)
add_subdirectory(systems/shell-ram)
add_subdirectory(boards/tang-nano-20k)
add_subdirectory(harness)

find_program(RS_FUSESOC fusesoc)
if(RS_FUSESOC)
    # Checks every .core parses and its dependencies resolve, then lints the
    # system through FuseSoC the way a library user would.
    foreach(system uart-echo shell-ram)
        add_test(NAME "fusesoc lint ${system}"
                 COMMAND ${RS_FUSESOC} --cores-root ${PROJECT_SOURCE_DIR} run
                         --build-root ${CMAKE_CURRENT_BINARY_DIR}/fusesoc --target lint
                         retro-silicon:system:${system})
    endforeach()
endif()
