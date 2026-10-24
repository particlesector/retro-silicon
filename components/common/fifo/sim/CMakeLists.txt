# SPDX-License-Identifier: Apache-2.0
rs_sim_test(fifo_test SOURCES fifo_test.cpp)
rs_verilate(fifo_test COMPONENT fifo PREFIX Vfifo_16 PARAMS DEPTH_LOG2=4)
rs_verilate(fifo_test COMPONENT fifo PREFIX Vfifo_2k)
