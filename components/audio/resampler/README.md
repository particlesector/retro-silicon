# resampler

Takes an unsigned audio level at a high rate, one sample per `ce`, to signed 16-bit PCM at a lower rate. The defaults take the NES's CPU-cycle levels to 48 kHz against a 60 Hz display: 800 samples per 29,780.5 cycles, the average NES frame with rendering on. In integer arithmetic throughout, so the output depends only on the inputs: the same in the sim and on any board.

Module `resampler`.

## What it does

- **Decimation:** an accumulator adds `NUM` each input and takes a sample when it reaches `DEN`, so the samples come `DEN / NUM` inputs apart on average, never more than one input from even (37 or 38 at the defaults).
- **Low-pass:** each sample is the average of the inputs since the last, a box filter: their sum times 2^16 over their count, rounded down, on a multiplier (a DSP block where there is one). For held levels like the APU's, that's the level's average over the sample. Its first null is at the output rate; the NES's own output has a low-pass near 14 kHz.
- **DC block:** a one-pole high-pass at the output rate, `y = v - v' + y' - y' / 2^HPF`, with `v` the average halved. At 48 kHz and `HPF = 9`, its corner is near 15 Hz. The NES's own output has high-passes at 90 and 440 Hz; this one only centres the signal.
- **Output:** `y` saturated to 16 bits signed, so a full-scale step reaches ±32767.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset to silence |
| `ce`, `in` | in | 1, 16 | An input sample, unsigned |
| `valid` | out | 1 | A one-clock pulse three clocks after a `ce` that made a sample: the sum, the multiply and the high-pass take a clock each. `ce` must come at least four clocks apart |
| `busy` | out | 1 | A sample is between its `ce` and its `valid`: don't read or write the save state yet |
| `out` | out | 16 | The latest sample, signed |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 2, 32, 1, 32 | Save-state port: 4 words, {count, sum}, {the last average, the accumulator}, `y`, and one unused |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `NUM`, `DEN` | 1600, 59561 | Output samples per `DEN` inputs; `NUM < DEN < 65536`, `DEN / NUM <= 60` |
| `HPF` | 9 | The high-pass filter's shift |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0. For a board short of logic |

## Status

Sim tests:

- 3,200 samples for two `DEN`s of input, 37 or 38 inputs apart;
- the RTL matches a C++ model sample for sample over 2 million inputs of held random levels;
- a constant level settles to within 64 of zero;
- a 1 kHz square wave of half scale swings about ±8,000;
- a save-state round trip in mid-stream runs on as the original.
