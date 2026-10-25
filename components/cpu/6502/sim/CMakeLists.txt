# SPDX-License-Identifier: Apache-2.0
# The NES's 2A03: no decimal mode.
rs_sim_test(cpu_6502_test SOURCES cpu_test.cpp nes_roms_test.cpp)
rs_verilate(cpu_6502_test COMPONENT cpu_6502 PARAMS DECIMAL=0)
target_compile_definitions(cpu_6502_test PRIVATE RS_TESTROMS="${RS_TESTROMS}"
    RS_NES_TRACE_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/nes_trace_crc32.txt")
target_include_directories(cpu_6502_test PRIVATE ${PROJECT_SOURCE_DIR}/harness/tests)  # golden.hpp

include(${PROJECT_SOURCE_DIR}/cmake/Perfect6502.cmake)
if(TARGET perfect6502)
    # A stock NMOS 6502, decimal mode included, as perfect6502 models.
    rs_sim_test(cpu_6502_lockstep SOURCES perfect6502_test.cpp)
    rs_verilate(cpu_6502_lockstep COMPONENT cpu_6502 PARAMS DECIMAL=1)
    target_link_libraries(cpu_6502_lockstep PRIVATE perfect6502)
endif()
