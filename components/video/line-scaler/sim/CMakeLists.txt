# SPDX-License-Identifier: Apache-2.0
rs_sim_test(line_scaler_test SOURCES line_scaler_test.cpp)
rs_verilate(line_scaler_test COMPONENT line_scaler PREFIX Vls_nes)
rs_verilate(line_scaler_test COMPONENT line_scaler PREFIX Vls_late PARAMS REQ_Y=700)
rs_verilate(line_scaler_test COMPONENT line_scaler PREFIX Vls_small PARAMS LINES_LOG2=3)
