// SPDX-License-Identifier: Apache-2.0
#pragma once
// This repo's systems in Verilator, at SimLink::kClksPerBit (1.5 Mbaud), the
// same parameters as their Tang Nano 20K bitstreams. Link with rs_sim_link.

#include <memory>

#include "rig/sim_link.hpp"

namespace rig {

std::unique_ptr<SimLink> make_uart_echo_sim();
std::unique_ptr<SimLink> make_shell_ram_sim();  // reports RS_SHELL_RAM_BUILD_ID

} // namespace rig
