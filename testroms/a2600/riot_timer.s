; SPDX-License-Identifier: Apache-2.0
; The RIOT's interval timer: each divider set, then read back every 7 CPU cycles (LDA INTIM, STA zp),
; through its count down, its underflow, and the count at one a clock after it. Results (show.inc):
;    0-7:  TIM1T = 3, eight reads of INTIM
;    8-15: TIM8T = 2, eight reads of INTIM
;   16-19: TIM64T = 0, four reads of INTIM
;   20-23: T1024T = 0, four reads of INTIM
;   24-31: TIM1T = 1, then TIMINT, INTIM, TIMINT, INTIM ... (the flag in TIMINT's bit 7, cleared by
;          reading INTIM)
; The values are Stella's (the golden frame); the timer's starting value at power-up is never read.

.include "vcs.inc"

.macro  READS reg, first, count
        .repeat count, i
        lda reg
        sta RESULTS+first+i
        .endrep
.endmacro

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$7F
@clr:   sta $80,x
        dex
        bpl @clr

        lda #3
        sta TIM1T
        READS INTIM, 0, 8
        lda #2
        sta TIM8T
        READS INTIM, 8, 8
        lda #0
        sta TIM64T
        READS INTIM, 16, 4
        lda #0
        sta T1024T
        READS INTIM, 20, 4
        lda #1
        sta TIM1T
        .repeat 4, i
        lda TIMINT
        sta RESULTS+24+2*i
        lda INTIM
        sta RESULTS+25+2*i
        .endrep
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
