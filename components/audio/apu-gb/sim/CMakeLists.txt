# SPDX-License-Identifier: Apache-2.0
rs_sim_test(apu_gb_test SOURCES apu_gb_test.cpp)
rs_verilate(apu_gb_test COMPONENT apu_gb PREFIX Vapu_gb)
