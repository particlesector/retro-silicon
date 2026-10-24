# fifo

Synchronous first-in, first-out queue. The read port is registered, so synthesis maps the storage to block RAM: `rdata` holds a byte the cycle after its read is accepted.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which empties the FIFO |
| `wdata` | in | `WIDTH` | Entry to write |
| `wen` | in | 1 | Write `wdata`; ignored when full |
| `full` | out | 1 | No room for a write this cycle |
| `ren` | in | 1 | Read the oldest entry; ignored when empty |
| `rdata` | out | `WIDTH` | The entry read on the previous cycle; held otherwise |
| `empty` | out | 1 | Nothing to read this cycle |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `WIDTH` | 8 | Bits per entry |
| `DEPTH_LOG2` | 11 | log2 of the entry count; 2,048 × 8 bits is one 18 Kbit Gowin BSRAM |

## Status

Sim tests at 16 and 2,048 entries: it fills to its depth, ignores a write when full and a read when empty, empties on reset, and matches a software queue over 100,000 cycles of random reads and writes. On a Tang Nano 20K, inside `systems/uart-echo`, it carried 100 MB at 1.5 Mbaud with no errors.
