# SPDX-License-Identifier: Apache-2.0
rs_sim_test(crc32_test SOURCES crc32_test.cpp)
rs_verilate(crc32_test COMPONENT crc32)
rs_verilate(crc32_test COMPONENT crc32 PREFIX Vcrc32_w30 PARAMS W=30)
