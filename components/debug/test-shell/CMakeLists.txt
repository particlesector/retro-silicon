# SPDX-License-Identifier: Apache-2.0
rs_component(test_shell RTL rtl/ts_rx.sv rtl/ts_tx.sv rtl/test_shell.sv DEPENDS crc32 uart)
add_subdirectory(sim)
