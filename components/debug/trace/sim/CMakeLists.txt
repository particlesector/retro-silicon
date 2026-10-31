# SPDX-License-Identifier: Apache-2.0
rs_sim_test(trace_buffer_test SOURCES trace_buffer_test.cpp)
rs_verilate(trace_buffer_test COMPONENT trace_buffer PARAMS AW=4)
