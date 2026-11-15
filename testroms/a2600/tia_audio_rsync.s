; SPDX-License-Identifier: Apache-2.0
; tia_audio, with RSYNC its first write, before any WSYNC has put the CPU in step with the line. From
; Stella's power-up the CPU's first cycle is the TIA's colour clock 0, its line counter and audio
; counter both at 0; an RSYNC then moves the line counter but not the audio counter, so where it lands
; sets where the sound's two clocks a line fall against the line for the rest of the run, and each
; sample's sums show it.

EARLY_RSYNC = 1
.include "tia_audio.s"
