// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_template_test_macros.hpp>
#include <catch2/catch_test_macros.hpp>

#include "Vpor_1.h"
#include "Vpor_16.h"

namespace {

template <class T> constexpr int cycles = 0;
template <> constexpr int cycles<Vpor_16> = 16;
template <> constexpr int cycles<Vpor_1> = 1;

} // namespace

TEMPLATE_TEST_CASE("por holds rst for CYCLES clocks, then releases it for good", "", Vpor_16, Vpor_1) {
    TestType m;
    m.clk = 0;
    m.eval();
    for (int i = 0; i < cycles<TestType>; i++) {
        REQUIRE(m.rst);
        m.clk = 1;
        m.eval();
        m.clk = 0;
        m.eval();
    }
    for (int i = 0; i < 1000; i++) {
        REQUIRE_FALSE(m.rst);
        m.clk = 1;
        m.eval();
        m.clk = 0;
        m.eval();
    }
}
