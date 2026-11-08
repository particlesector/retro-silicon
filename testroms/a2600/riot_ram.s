; SPDX-License-Identifier: Apache-2.0
; The RIOT's 128 bytes of RAM and their mirrors. The RAM answers wherever A12 = 0, A9 = 0 and A7 = 1, so
; $80-$FF, $180-$1FF (the stack), $480, $D80 and the rest all reach the same bytes. Results (show.inc):
;   0: errors reading $80-$BF back after writing a pattern there
;   1: errors reading the same pattern through $180-$1BF
;   2: errors reading through $480-$4BF
;   3: errors reading through $D80-$DBF
;   4: errors reading $80-$BF directly after writing a second pattern through $180-$1BF
;   5: $FF after PHA of $A5 with S = $FF (the stack's $1FF is $FF)
;   6: $A5 pulled back by PLA
;   7: S after that PLA ($FF)
; All 0 but 5 and 6 ($A5) and 7 ($FF) on a working RIOT. Bytes 8-31 are 0.

.include "vcs.inc"

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

        ; Pattern 1: byte n = n * 7 + 3, at $80+n for n = 0-63
        ldx #0
        lda #3
@w1:    sta $80,x
        clc
        adc #7
        inx
        cpx #64
        bne @w1
        ldx #0
        lda #3
@r1:    cmp $80,x
        beq :+
        inc RESULTS+0
:       cmp $180,x
        beq :+
        inc RESULTS+1
:       cmp $480,x
        beq :+
        inc RESULTS+2
:       cmp $D80,x
        beq :+
        inc RESULTS+3
:       clc
        adc #7
        inx
        cpx #64
        bne @r1

        ; Pattern 2: byte n = n * 13 + $55, written through $180+n
        ldx #0
        lda #$55
@w2:    sta $180,x
        clc
        adc #13
        inx
        cpx #64
        bne @w2
        ldx #0
        lda #$55
@r2:    cmp $80,x
        beq :+
        inc RESULTS+4
:       clc
        adc #13
        inx
        cpx #64
        bne @r2

        ; The stack
        lda #0
        sta $FF
        lda #$A5
        pha
        lda $FF
        sta RESULTS+5
        lda #0
        pla
        sta RESULTS+6
        tsx
        stx RESULTS+7
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
