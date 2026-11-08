; SPDX-License-Identifier: Apache-2.0
; The Atari 2600's registers used by the test cartridges, from the Stella Programmer's Guide.

; TIA writes
VSYNC   = $00
VBLANK  = $01
WSYNC   = $02
COLUBK  = $09

; RIOT
SWCHA   = $280
SWACNT  = $281
SWCHB   = $282
SWBCNT  = $283
INTIM   = $284
TIMINT  = $285
TIM1T   = $294
TIM8T   = $295
TIM64T  = $296
T1024T  = $297

; Results: 32 bytes the cartridge's test leaves for show.inc to draw.
RESULTS = $C0
