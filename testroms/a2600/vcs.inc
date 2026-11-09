; SPDX-License-Identifier: Apache-2.0
; The Atari 2600's registers used by the test cartridges, from the Stella Programmer's Guide.

; TIA writes
VSYNC   = $00
VBLANK  = $01
WSYNC   = $02
COLUP0  = $06
COLUP1  = $07
COLUPF  = $08
COLUBK  = $09
CTRLPF  = $0A
PF0     = $0D
PF1     = $0E
PF2     = $0F

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

; DELAY n: exactly n CPU cycles (n = 0 or n >= 2), touching only the flags; 12 at a time by calling
; wait12 (an RTS that each cartridge using DELAY defines).
.macro  DELAY n
        .if n = 1
        .error "DELAY can't take 1 cycle"
        .elseif n >= 14
        jsr wait12
        DELAY n - 12
        .elseif n > 0
        .if (n .mod 2) = 1
        bit $80
        .repeat (n - 3) / 2
        nop
        .endrep
        .else
        .repeat n / 2
        nop
        .endrep
        .endif
        .endif
.endmacro

; Results: 32 bytes the cartridge's test leaves for show.inc to draw.
RESULTS = $C0
