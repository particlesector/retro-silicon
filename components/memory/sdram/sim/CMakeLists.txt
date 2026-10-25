# SPDX-License-Identifier: Apache-2.0
# The Tang Nano 20K's clock, and a fast one where tRAS and tRC span several clocks.
foreach(mhz 27 100)
    rs_sim_test(sdram_test_${mhz} SOURCES sdram_test.cpp)
    rs_verilate(sdram_test_${mhz} COMPONENT sdram_ctrl PARAMS FREQ_MHZ=${mhz})
    target_compile_definitions(sdram_test_${mhz} PRIVATE RS_SDRAM_MHZ=${mhz})
endforeach()
