# SPDX-License-Identifier: Apache-2.0
rs_sim_test(hdmi_test SOURCES hdmi_test.cpp)
target_include_directories(hdmi_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
rs_verilate(hdmi_test COMPONENT hdmi TOP tmds_encoder PREFIX Vtmds_encoder)
rs_verilate(hdmi_test COMPONENT hdmi TOP hdmi PREFIX Vhdmi_720p)
rs_verilate(hdmi_test COMPONENT hdmi TOP hdmi PREFIX Vhdmi_small
            PARAMS H_ACTIVE=16 H_FRONT=2 H_SYNC=3 H_BACK=4 V_ACTIVE=8 V_FRONT=1 V_SYNC=2 V_BACK=3
                   H_POS=0 V_POS=0 LATENCY=4)
