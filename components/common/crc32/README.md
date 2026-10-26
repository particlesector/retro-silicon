# crc32

CRC-32 as used by zlib, Ethernet and PNG (IEEE 802.3 polynomial, reflected, initial value and final XOR `0xFFFFFFFF`), consuming `W` bits per enabled clock, bit 0 first: by default one byte. The test shell uses it for frame, scanline and audio CRCs, and the harness's software `rig::Crc32` matches it.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `rst` | in | 1 | Synchronous; restarts the CRC |
| `en` | in | 1 | Consume `data` this cycle |
| `data` | in | `W` | Next byte, or `W` bits |
| `crc` | out | 32 | CRC of every byte since reset, final XOR applied |
| `st_we`, `st_wdata` | in | 1, 32 | Save state: set the CRC to `st_wdata`, ahead of any byte that clock |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `W` | 8 | Bits per enabled clock, 1 to 32 |

## Save state

One word, the CRC: `crc` is its read side (it needs no address). Writing a saved CRC back makes the next bytes go on from it exactly as if the bytes before it had gone in. Tie `st_we` low where nothing restores the CRC.

## Status

Sim tests pass: the standard check value (`"123456789"` → `0xCBF43926`), the empty input, random data up to 61,440 bytes (one NES frame) against a bitwise software model, holding its value while `en` is low, a CRC restored mid-stream finishing as if it had seen the whole stream, and `W` = 30 against the bitwise model. Not yet run on a board.
