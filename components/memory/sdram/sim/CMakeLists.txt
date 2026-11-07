# SPDX-License-Identifier: Apache-2.0
# The Tang Nano 20K's clocks (27 MHz, and 46.4 MHz with HDMI, rounded up as
# its FREQ_MHZ is), and a fast one where tRAS and tRC span several clocks.
foreach(mhz 27 47 100)
    rs_sim_test(sdram_test_${mhz} SOURCES sdram_test.cpp)
    rs_verilate(sdram_test_${mhz} COMPONENT sdram_ctrl PARAMS FREQ_MHZ=${mhz})
    target_compile_definitions(sdram_test_${mhz} PRIVATE RS_SDRAM_MHZ=${mhz})
endforeach()
# A 16M x 16 chip (W9825G6KH, as on the Tang Console 138K's SDRAM module), at
# the 138K's 50 MHz oscillator and at 100 MHz.
foreach(mhz 50 100)
    rs_sim_test(sdram_test_x16_${mhz} SOURCES sdram_test.cpp)
    rs_verilate(sdram_test_x16_${mhz} COMPONENT sdram_ctrl
                PARAMS FREQ_MHZ=${mhz} DQ_W=16 ROW_W=13 COL_W=9 REFRESH_NS=7500)
    target_compile_definitions(sdram_test_x16_${mhz} PRIVATE RS_SDRAM_MHZ=${mhz}
                               RS_SDRAM_DQ=16 RS_SDRAM_ROW=13 RS_SDRAM_COL=9)
endforeach()
# The 138K's module: two of them on the same pins, the second on CS high
# (MiSTer's dual-chip wiring).
rs_sim_test(sdram_test_x16x2_50 SOURCES sdram_test.cpp)
rs_verilate(sdram_test_x16x2_50 COMPONENT sdram_ctrl
            PARAMS FREQ_MHZ=50 DQ_W=16 ROW_W=13 COL_W=9 REFRESH_NS=7500 RANKS=2)
target_compile_definitions(sdram_test_x16x2_50 PRIVATE RS_SDRAM_MHZ=50
                           RS_SDRAM_DQ=16 RS_SDRAM_ROW=13 RS_SDRAM_COL=9 RS_SDRAM_RANKS=2)
