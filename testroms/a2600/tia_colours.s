; SPDX-License-Identifier: Apache-2.0
; Every colour: picture line x has the background colour 2x, so lines 0-127 show all 128 NTSC colours
; (16 hues, each in 8 luminances), then lines 128-191 repeat the first 64.

.include "vcs.inc"

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
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
        ldx #0
@pic:   txa
        asl a
        sta COLUBK
        sta WSYNC
        inx
        cpx #192
        bne @pic
        lda #0
        sta COLUBK
        lda #2
        sta VBLANK
        ldx #30
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

.segment "VECTORS"
        .word reset, reset, reset
