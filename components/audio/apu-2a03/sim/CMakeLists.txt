# SPDX-License-Identifier: Apache-2.0
rs_sim_test(apu_2a03_test SOURCES apu_test.cpp)
rs_verilate(apu_2a03_test COMPONENT apu_2a03 PREFIX Vapu_2a03)
rs_sim_test(apu_mixer_test SOURCES mixer_test.cpp)
rs_verilate(apu_mixer_test COMPONENT apu_2a03 TOP apu_mixer PREFIX Vapu_mixer)
