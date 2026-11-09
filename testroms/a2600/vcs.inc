; SPDX-License-Identifier: Apache-2.0
; The Atari 2600's registers used by the test cartridges, from the Stella Programmer's Guide.

; TIA writes
VSYNC   = $00
VBLANK  = $01
WSYNC   = $02
RSYNC   = $03
NUSIZ0  = $04
NUSIZ1  = $05
COLUP0  = $06
COLUP1  = $07
COLUPF  = $08
COLUBK  = $09
CTRLPF  = $0A
REFP0   = $0B
REFP1   = $0C
PF0     = $0D
PF1     = $0E
PF2     = $0F
RESP0   = $10
RESP1   = $11
RESM0   = $12
RESM1   = $13
RESBL   = $14
AUDC0   = $15
AUDC1   = $16
AUDF0   = $17
AUDF1   = $18
AUDV0   = $19
AUDV1   = $1A
GRP0    = $1B
GRP1    = $1C
ENAM0   = $1D
ENAM1   = $1E
ENABL   = $1F
HMP0    = $20
HMP1    = $21
HMM0    = $22
HMM1    = $23
HMBL    = $24
VDELP0  = $25
VDELP1  = $26
VDELBL  = $27
RESMP0  = $28
RESMP1  = $29
HMOVE   = $2A
HMCLR   = $2B
CXCLR   = $2C

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
; wait12 (an RTS that each cartridge using DELAY defines). `n` may be an expression.
.macro  DELAY n
        .if (n) = 1
        .error "DELAY can't take 1 cycle"
        .elseif (n) >= 14
        jsr wait12
        DELAY (n) - 12
        .elseif (n) > 0
        .if ((n) .mod 2) = 1
        bit $80
        .repeat ((n) - 3) / 2
        nop
        .endrep
        .else
        .repeat (n) / 2
        nop
        .endrep
        .endif
        .endif
.endmacro

; Results: 32 bytes the cartridge's test leaves for show.inc to draw.
RESULTS = $C0
