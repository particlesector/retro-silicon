; SPDX-License-Identifier: Apache-2.0
; RSYNC: cutting a line short at each cycle of it. Eight bands over a striped playfield, with both
; players (quad width), both missiles and the ball (8 wide) placed on each band's first line; then 11
; groups of three lines, the first cut by RSYNC written at cycle 9k + i + 2 (band k, group i: from
; cycle 2 to cycle 75, the line's last), then two whole lines (the WSYNC after the cut waits out the
; next line, and the group's own WSYNC another). The cut line ends 3 colour clocks after the write:
; what it drew so far, those 3 colour clocks drawn on from there, and black to its end; and the
; objects, having missed the rest of the line's ticks, sit further right from then on.
; The frame runs 351 lines (89 of them short), more than the 262 Stella's frame manager expects, so it
; ends some frames by its count of lines without VSYNC (frame 30 among them): the frame check follows.

.include "vcs.inc"

; DELAY that takes 1 as 2.
.macro  DELAY_ n
        .if (n) = 1
        DELAY 2
        .else
        DELAY (n)
        .endif
.endmacro

.macro  BAND k
        sta WSYNC
        DELAY 24
        sta RESP0
        sta RESM0
        DELAY 6
        sta RESBL
        DELAY 6
        sta RESP1
        sta RESM1
        .repeat 11, i
        sta WSYNC
        DELAY_ k * 9 + i
        sta RSYNC
        sta WSYNC
        .endrep
        sta WSYNC
.endmacro

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        lda #$46
        sta COLUP0
        lda #$86
        sta COLUP1
        lda #$C6
        sta COLUPF
        lda #$04
        sta COLUBK
        lda #$A0
        sta PF0
        lda #$55
        sta PF1
        lda #$AA
        sta PF2
        lda #$C3
        sta GRP0
        lda #$3C
        sta GRP1
        lda #$37
        sta NUSIZ0
        sta NUSIZ1
        lda #$30
        sta CTRLPF

frame:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #2
        sta VBLANK
        ldx #37
@vb:    sta WSYNC
        dex
        bne @vb
        lda #0
        sta VBLANK
        lda #2
        sta ENAM0
        sta ENAM1
        sta ENABL

        BAND 0
        BAND 1
        BAND 2
        BAND 3
        BAND 4
        BAND 5
        BAND 6
        BAND 7

        lda #2
        sta WSYNC
        sta VBLANK
        lda #0
        sta ENAM0
        sta ENAM1
        sta ENABL
        ldx #29
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

wait12: rts

.segment "VECTORS"
        .word reset, reset, reset
