# SPDX-License-Identifier: Apache-2.0
rs_sim_test(paddles_test SOURCES paddles_test.cpp)
rs_verilate(paddles_test COMPONENT paddles PREFIX Vpaddles)
rs_verilate(paddles_test COMPONENT paddles PREFIX Vpaddles_nost PARAMS SAVE_STATE=0)
