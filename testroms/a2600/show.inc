; SPDX-License-Identifier: Apache-2.0
; Draws the 32 result bytes at RESULTS, forever, as a standard NTSC frame: 3 lines of VSYNC, 37 of
; VBLANK, 192 of picture, 30 of overscan. Each byte takes 6 picture lines, 3 with the background
; colour set to the byte and 3 to the byte shifted left once; the TIA ignores a colour's bit 0, so the
; two together show all 8 bits. Each colour is set in the line's horizontal blank, so every
; line is one colour. Uses A, X and Y only, never the timer.

show:   lda #2
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
        ldy #0
@row:   lda RESULTS,y
        ldx #3
@hi:    sta COLUBK
        sta WSYNC
        dex
        bne @hi
        asl a
        ldx #3
@lo:    sta COLUBK
        sta WSYNC
        dex
        bne @lo
        iny
        cpy #32
        bne @row
        lda #0
        sta COLUBK
        lda #2
        sta VBLANK
        ldx #30
@os:    sta WSYNC
        dex
        bne @os
        jmp show
