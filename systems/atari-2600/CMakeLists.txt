# SPDX-License-Identifier: Apache-2.0
rs_component(atari2600 RTL rtl/atari2600.sv DEPENDS cpu_6502 tia riot_6532 paddles)
add_subdirectory(sim)
