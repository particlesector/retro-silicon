# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.28)
project(retro_silicon LANGUAGES CXX)

# Works standalone or as a subdirectory of a rig project that adds its own
# backends; either way every test below lands in the same ctest run.
find_package(verilator REQUIRED HINTS $ENV{VERILATOR_ROOT})
find_package(Catch2 3 REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter)  # generated-file checks
if(PROJECT_IS_TOP_LEVEL)
    include(CTest)
endif()

include(cmake/RetroSilicon.cmake)

# Where testroms/fetch.py put the test ROMs; tests that need one skip without it.
if(DEFINED ENV{RS_TESTROMS})
    set(default_roms $ENV{RS_TESTROMS})
else()
    set(default_roms $ENV{HOME}/.cache/retro-silicon/testroms)
endif()
set(RS_TESTROMS ${default_roms} CACHE PATH "Test-ROM directory (testroms/fetch.py --dest)")

# Dependencies first: rs_component needs the components it depends on.
add_subdirectory(components/audio/apu-2a03)
add_subdirectory(components/common/cdc)
add_subdirectory(components/common/clock-enable)
add_subdirectory(components/common/crc32)
add_subdirectory(components/common/fifo)
add_subdirectory(components/common/por)
add_subdirectory(components/common/save-state)
add_subdirectory(components/common/uart)
add_subdirectory(components/cpu/6502)
add_subdirectory(components/debug/test-shell)
add_subdirectory(components/debug/video-probe)
add_subdirectory(components/memory/arbiter)
add_subdirectory(components/memory/bram)
add_subdirectory(components/memory/sdram)
add_subdirectory(components/video/hdmi)
add_subdirectory(components/video/line-scaler)
add_subdirectory(components/video/ppu-2c02)
add_subdirectory(systems/uart-echo)
add_subdirectory(systems/shell-ram)
add_subdirectory(systems/shell-sdram)
add_subdirectory(systems/nes)
add_subdirectory(boards/tang-nano-20k)
add_subdirectory(boards/tang-console-138k)
add_subdirectory(boards/pynq-z2)
add_subdirectory(harness)

find_program(RS_FUSESOC fusesoc)
if(RS_FUSESOC)
    # Checks every .core parses and its dependencies resolve, then lints the
    # system through FuseSoC the way a library user would.
    foreach(system uart-echo shell-ram shell-sdram nes)
        add_test(NAME "fusesoc lint ${system}"
                 COMMAND ${RS_FUSESOC} --cores-root ${PROJECT_SOURCE_DIR} run
                         --build-root ${CMAKE_CURRENT_BINARY_DIR}/fusesoc --target lint
                         retro-silicon:system:${system})
    endforeach()
    # Components no system uses yet.
    add_test(NAME "fusesoc lint cpu-6502"
             COMMAND ${RS_FUSESOC} --cores-root ${PROJECT_SOURCE_DIR} run
                     --build-root ${CMAKE_CURRENT_BINARY_DIR}/fusesoc --target lint retro-silicon:cpu:6502)
endif()
