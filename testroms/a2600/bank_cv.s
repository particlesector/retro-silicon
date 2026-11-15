; SPDX-License-Identifier: Apache-2.0
; CommaVid (Stella's CV): a 2 KB ROM at $1800-$1FFF and 1 KB of RAM on the cartridge, read at
; $1000-$13FF and written at $1400-$17FF. Results (show.inc):
;   0: the OR of the RAM's 1,024 bytes at power-up (0: Stella starts it cleared, its RAM randomising off)
;   1: errors reading back, through $1000-$13FF, byte n = n * 7 + 3 (low 8 bits) written through
;      $1400+n for n = 0-1023
;   2: $1000 read after writing $5A through $1400 (pattern's byte 0 replaced)
;   3: $13FF read after writing $A5 through $17FF
;   4: the ROM's byte at $1800 (this cartridge's first, $78: SEI)
; Bytes 5-31 are 0.

.include "vcs.inc"

RD      = $F000
WR      = $F400
ptr     = $80               ; 2 bytes: the page being checked

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$1F
@clr:   sta RESULTS,x
        dex
        bpl @clr

        ; 0: the RAM at power-up.
        lda #0
        ldx #0
@or:    ora RD,x
        ora RD+$100,x
        ora RD+$200,x
        ora RD+$300,x
        inx
        bne @or
        sta RESULTS+0

        ; 1: write the pattern through the write port, page by page (A carries on across pages).
        lda #3
        ldx #0
@w0:    sta WR,x
        clc
        adc #7
        inx
        bne @w0
@w1:    sta WR+$100,x
        clc
        adc #7
        inx
        bne @w1
@w2:    sta WR+$200,x
        clc
        adc #7
        inx
        bne @w2
@w3:    sta WR+$300,x
        clc
        adc #7
        inx
        bne @w3

        lda #3
        ldx #0
@r0:    cmp RD,x
        beq :+
        inc RESULTS+1
:       clc
        adc #7
        inx
        bne @r0
@r1:    cmp RD+$100,x
        beq :+
        inc RESULTS+1
:       clc
        adc #7
        inx
        bne @r1
@r2:    cmp RD+$200,x
        beq :+
        inc RESULTS+1
:       clc
        adc #7
        inx
        bne @r2
@r3:    cmp RD+$300,x
        beq :+
        inc RESULTS+1
:       clc
        adc #7
        inx
        bne @r3

        ; 2, 3: the first and last bytes again.
        lda #$5A
        sta WR
        lda RD
        sta RESULTS+2
        lda #$A5
        sta WR+$3FF
        lda RD+$3FF
        sta RESULTS+3

        ; 4: the ROM at $1800.
        lda $F800
        sta RESULTS+4
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
