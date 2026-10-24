-- SPDX-License-Identifier: Apache-2.0
-- MesenCE test runner for ROMs that report blargg-style at $6000 (see
-- testroms/manifest.toml). Prints the ROM's text report and the frame it
-- finished on, then exits with the result code: 0 pass, 1-127 the ROM's error
-- code, 255 if no result appears within two emulated minutes.
--   xvfb-run -a Mesen --testrunner <rom.nes> tools/mesen/blargg.lua
local mt = emu.memType.nesMemory
local frames, done = 0, false

local function text()
  local s, a = "", 0x6004
  while true do
    local c = emu.read(a, mt)
    if c == 0 or a > 0x7FFF then return s end
    s = s .. string.char(c)
    a = a + 1
  end
end

emu.addEventCallback(function()
  if done then return end
  frames = frames + 1
  local valid = emu.read(0x6001, mt) == 0xDE and emu.read(0x6002, mt) == 0xB0 and emu.read(0x6003, mt) == 0x61
  local status = emu.read(0x6000, mt)
  if valid and status < 0x80 then
    done = true
    print(text())
    print(string.format("result %d after %d frames", status, frames))
    emu.stop(status)
  elseif frames > 60 * 120 then
    done = true
    print("no result after 7200 frames")
    emu.stop(255)
  end
end, emu.eventType.endFrame)
