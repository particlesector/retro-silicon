# SPDX-License-Identifier: Apache-2.0
rs_sim_test(riot_6532_test SOURCES riot_6532_test.cpp)
rs_verilate(riot_6532_test COMPONENT riot_6532 PREFIX Vriot)
rs_verilate(riot_6532_test COMPONENT riot_6532 PREFIX Vriot_nost PARAMS SAVE_STATE=0)
