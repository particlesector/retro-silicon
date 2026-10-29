# resampler

Takes an unsigned audio level at a high rate, one sample per `ce`, to signed 16-bit PCM at a lower rate. The defaults take the NES's CPU-cycle levels to 48 kHz against a 60 Hz display: 800 samples per 29,780.5 cycles, the average NES frame with rendering on. In integer arithmetic throughout, so the output depends only on the inputs: the same in the sim and on any board.

Module `resampler`.

## What it does

- **Low-pass:** two one-pole filters at the input rate, `s += (x - s) / 2^LPF`, each with its corner near `fs / (2 pi 2^LPF)`. At 1.79 MHz and `LPF = 4`, that's about 17.8 kHz each, 11.5 kHz together.
- **Decimation:** an accumulator adds `NUM` each input and takes a sample when it reaches `DEN`, so the samples come `DEN / NUM` inputs apart on average, never more than one input from even.
- **DC block:** a one-pole high-pass at the output rate, `y = v - v' + y' - y' / 2^HPF`, with `v` the low-passed level halved. At 48 kHz and `HPF = 9`, its corner is near 15 Hz. The NES's own output has high-passes at 90 and 440 Hz; this one only centres the signal.
- **Output:** `y` saturated to 16 bits signed, so a full-scale step reaches ±32767.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset to silence |
| `ce`, `in` | in | 1, 16 | An input sample, unsigned |
| `valid` | out | 1 | A one-clock pulse the clock after a `ce` that made a sample |
| `out` | out | 16 | The latest sample, signed |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 2, 32, 1, 32 | Save-state port: 4 words, the two filters, {the last level, the accumulator}, and `y` |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `NUM`, `DEN` | 1600, 59561 | Output samples per `DEN` inputs; `NUM < DEN < 65536` |
| `LPF` | 4 | The low-pass filters' shift |
| `HPF` | 9 | The high-pass filter's shift |

## Status

Sim tests:

- 3,200 samples for two `DEN`s of input, 37 or 38 inputs apart;
- the RTL matches a C++ model sample for sample over 2 million inputs of held random levels;
- a constant level settles to within 64 of zero;
- a 1 kHz square wave of half scale swings about ±8,000;
- a save-state round trip in mid-stream runs on as the original.
