// SPDX-License-Identifier: Apache-2.0
#include "rig/sim_systems.hpp"

#include "Vshell_ram_sim.h"
#include "Vuart_echo_sim.h"

namespace rig {

namespace {

// Any Verilated top with clk, uart_rx and uart_tx ports.
template <class V> class Verilated : public SimModel {
public:
    bool tick(bool rx) override {
        m_.uart_rx = rx;
        m_.clk = 0;
        m_.eval();
        m_.clk = 1;
        m_.eval();
        return m_.uart_tx;
    }

private:
    V m_;
};

} // namespace

std::unique_ptr<SimLink> make_uart_echo_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vuart_echo_sim>>());
}

std::unique_ptr<SimLink> make_shell_ram_sim() {
    return std::make_unique<SimLink>(std::make_unique<Verilated<Vshell_ram_sim>>());
}

} // namespace rig
