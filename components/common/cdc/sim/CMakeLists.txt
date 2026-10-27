# SPDX-License-Identifier: Apache-2.0
rs_sim_test(cdc_sync_test SOURCES cdc_sync_test.cpp)
rs_verilate(cdc_sync_test COMPONENT cdc_sync PREFIX Vcdc_sync3 PARAMS W=9 STAGES=3)
