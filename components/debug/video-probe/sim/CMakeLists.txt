# SPDX-License-Identifier: Apache-2.0
rs_sim_test(video_probe_test SOURCES video_probe_test.cpp)
rs_verilate(video_probe_test COMPONENT video_probe PREFIX Vvideo_probe PARAMS W=16 H=6)
target_link_libraries(video_probe_test PRIVATE rs_harness)
