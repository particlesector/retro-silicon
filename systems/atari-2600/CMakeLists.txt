# SPDX-License-Identifier: Apache-2.0
rs_component(atari2600 RTL rtl/atari2600.sv DEPENDS cpu_6502 tia riot_6532 paddles)
rs_component(a2600_frame RTL rtl/a2600_frame.sv DEPENDS crc32)
rs_component(a2600_video RTL rtl/a2600_video.sv DEPENDS por cdc_sync crc32 fifo tia_rgb resampler hdmi)
rs_component(a2600_sys RTL rtl/a2600_sys.sv DEPENDS atari2600 a2600_frame a2600_video por clock_enable crc32 test_shell)
rs_build_id(a2600_id a2600_sys)
set_property(GLOBAL PROPERTY RS_A2600_BUILD_ID ${a2600_id})
add_subdirectory(sim)
