# crc32

CRC-32 as used by zlib, Ethernet and PNG (IEEE 802.3 polynomial, reflected, initial value and final XOR `0xFFFFFFFF`), consuming one byte per enabled clock. The test shell uses it for frame, scanline and audio CRCs, and the harness's software `rig::Crc32` matches it.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `rst` | in | 1 | Synchronous; restarts the CRC |
| `en` | in | 1 | Consume `data` this cycle |
| `data` | in | 8 | Next byte |
| `crc` | out | 32 | CRC of every byte since reset, final XOR applied |

No parameters.

## Status

Sim tests pass: the standard check value (`"123456789"` → `0xCBF43926`), the empty input, random data up to 61,440 bytes (one NES frame) against a bitwise software model, and holding its value while `en` is low. Not yet run on a board.
