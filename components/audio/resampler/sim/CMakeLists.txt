# SPDX-License-Identifier: Apache-2.0
rs_sim_test(resampler_test SOURCES resampler_test.cpp)
rs_verilate(resampler_test COMPONENT resampler PREFIX Vresampler)
