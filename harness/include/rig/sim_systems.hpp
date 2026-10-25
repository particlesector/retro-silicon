// SPDX-License-Identifier: Apache-2.0
#pragma once
// This repo's systems in Verilator, at SimLink::kClksPerBit (1.5 Mbaud), the
// same parameters as their Tang Nano 20K bitstreams. Link with rs_sim_link.
// The SDRAM systems' links add jitter to the host's timing (see SimLink).

#include <memory>

#include "rig/sim_link.hpp"

namespace rig {

std::unique_ptr<SimLink> make_uart_echo_sim();
std::unique_ptr<SimLink> make_shell_ram_sim();    // reports RS_SHELL_RAM_BUILD_ID
std::unique_ptr<SimLink> make_shell_sdram_sim();  // reports RS_SHELL_SDRAM_BUILD_ID
std::unique_ptr<SimLink> make_nes_sim();          // reports RS_NES_BUILD_ID
// The NES as the Tang Console 138K runs it: block RAM for its memory, and a
// 50 MHz clock (33 clocks a bit). Reports RS_NES_BRAM_BUILD_ID.
std::unique_ptr<SimLink> make_nes_bram_sim();

} // namespace rig
