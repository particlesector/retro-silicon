; SPDX-License-Identifier: Apache-2.0
; M Network's E7 bank switching: 16 KB in eight 2 KB slices, and 2 KB of RAM. $1000-$17FF shows the
; slice an access to $1FE0-$1FE6 selects, or with $1FE7 1 KB of RAM, written at $1000-$13FF and read
; at $1400-$17FF; $1800-$18FF writes and $1900-$19FF reads one of four 256-byte RAM banks, which
; $1FE8-$1FEB select; $1A00-$1FFF is slice 7's, which holds this program. Each slice's first byte is
; its ID ($40 + its number; bank_id.s for 0-6). Results (show.inc):
;   0: the ID at $1000 at reset (slice 0: $40)
;   1-7: the ID at $1000 after selecting each slice 0-6
;   8, 9: the 1 KB RAM's first and last byte at the start (0)
;   10: errors reading the 1 KB back after writing byte n = n x 7 + $5A (low byte)
;   11: the ID at $1000 after selecting slice 3 ($43)
;   12: the 1 KB RAM's byte 5 after selecting it again ($7D)
;   13: the 256-byte RAM bank 0's byte 0 at the start (0)
;   14-17: byte 0 of each 256-byte bank after writing $B0 + its number to each ($B0-$B3)
;   18-21: byte 255 of each, after writing $C0 + its number ($C0-$C3)
;   22: byte 5 of bank 1 after a write of $EE to its read port ($00: nothing written)

.include "vcs.inc"

.segment "CODE"
        .res $200, $FF          ; $1800-$19FF: the 256-byte RAM's ports

reset:  sei
        cld
        ldx #$FF
        txs
        lda #0
        ldx #$7F
@clr:   sta $80,x
        dex
        bpl @clr

        lda $F000
        sta RESULTS+0
        .repeat 7, s
        lda $FFE0+s
        lda $F000
        sta RESULTS+1+s
        .endrepeat

        ; The 1 KB RAM
        lda $FFE7
        lda $F400
        sta RESULTS+8
        lda $F7FF
        sta RESULTS+9
        ldx #0
        lda #$5A
@w:     sta $F000,x
        sta $F100,x
        sta $F200,x
        sta $F300,x
        clc
        adc #7
        inx
        bne @w
        ldx #0
        lda #$5A
@r:     cmp $F400,x
        beq :+
        inc RESULTS+10
:       cmp $F500,x
        beq :+
        inc RESULTS+10
:       cmp $F600,x
        beq :+
        inc RESULTS+10
:       cmp $F700,x
        beq :+
        inc RESULTS+10
:       clc
        adc #7
        inx
        bne @r
        lda $FFE3
        lda $F000
        sta RESULTS+11
        lda $FFE7
        lda $F405
        sta RESULTS+12

        ; The 256-byte banks
        lda $F900
        sta RESULTS+13
        .repeat 4, b
        lda $FFE8+b
        lda #$B0+b
        sta $F800
        lda #$C0+b
        sta $F8FF
        .endrepeat
        .repeat 4, b
        lda $FFE8+b
        lda $F900
        sta RESULTS+14+b
        lda $F9FF
        sta RESULTS+18+b
        .endrepeat
        lda $FFE9
        lda #$EE
        sta $F905
        lda $F905
        sta RESULTS+22

        lda #2
        sta VBLANK
        jmp show

.include "show.inc"

.segment "VECTORS"
        .word reset, reset
