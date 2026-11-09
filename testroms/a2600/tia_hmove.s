; SPDX-License-Identifier: Apache-2.0
; HMOVE: every HM value, HMOVE landing at each cycle of the line, and HM changes during a movement.
; Eight bands of 24 lines, each placing the five objects on its first two lines (player 0 red, missile
; 0 red, the ball green, player 1 blue, missile 1 blue; band k with its own copies and widths), then on
; each of its other 22 lines:
;   bands 0, 1: HMOVE at the line's start, then new HM values for the next line, so each object steps
;     through all 16 (an 8-pixel black comb starts each line);
;   bands 2, 3, 4: HMOVE written a cycle later each line, from cycle 2 to cycle 67 (the comb only
;     while it lands in the blank; later ones move the objects as they're drawn);
;   band 5: HMOVE written at cycles 64-71 in turn, near the line's end, so the movement runs on into
;     the next line's blank;
;   band 6: HMOVE at the line's start and HMCLR a cycle later each line, during the movement, then
;     HMP0, HMM1 and HMBL back to $70 (player 1 and missile 0 keep HMCLR's 0 after the first line);
;   band 7: HMOVE written every second cycle, from cycle 2 to cycle 44.
; Line cycles count from the CPU's first cycle after WSYNC, 0; a STA writes on its third.

.include "vcs.inc"

; DELAY that takes 1 as 2.
.macro  DELAY_ n
        .if (n) = 1
        DELAY 2
        .else
        DELAY (n)
        .endif
.endmacro

; The band's first two lines: sizes, HM values and the objects' places.
.macro  SETUP k, nus0, nus1, ctrl, hp0, hp1, hm0, hm1, hbl
        sta WSYNC
        lda #nus0
        sta NUSIZ0
        lda #nus1
        sta NUSIZ1
        lda #ctrl
        sta CTRLPF
        lda #hp0
        sta HMP0
        lda #hp1
        sta HMP1
        lda #hm0
        sta HMM0
        lda #hm1
        sta HMM1
        lda #hbl
        sta HMBL
        lda #(k .mod 2) * 2 + 2
        sta COLUBK
        sta WSYNC
        DELAY 22
        sta RESP0
        DELAY 4
        sta RESM0
        DELAY 4
        sta RESBL
        DELAY 7
        sta RESP1
        DELAY 7
        sta RESM1
.endmacro

; HMOVE early, then each object's next HM value.
.macro  STEPS
        .repeat 22, i
        sta WSYNC
        sta HMOVE
        DELAY 26
        lda #(((i * 3) .mod 16) << 4)
        sta HMP0
        lda #(((i * 5 + 1) .mod 16) << 4)
        sta HMP1
        lda #(((i * 7 + 2) .mod 16) << 4)
        sta HMM0
        lda #(((31 - i) .mod 16) << 4)
        sta HMM1
        lda #(((i * 11 + 3) .mod 16) << 4)
        sta HMBL
        .endrep
.endmacro

; HMOVE at cycle base + i * step on line i.
.macro  LATE base, step
        .repeat 22, i
        sta WSYNC
        DELAY_ base + i * step
        sta HMOVE
        .endrep
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
        lda #$AA
        sta GRP0
        lda #$C3
        sta GRP1

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

        SETUP 0, $00, $10, $01, $00, $00, $00, $00, $00
        STEPS
        SETUP 1, $23, $36, $11, $00, $00, $00, $00, $00
        STEPS
        SETUP 2, $00, $10, $01, $70, $90, $F0, $10, $80
        LATE 0, 1
        SETUP 3, $10, $00, $11, $70, $90, $F0, $10, $80
        LATE 22, 1
        SETUP 4, $25, $37, $21, $70, $90, $F0, $10, $80
        LATE 44, 1
        SETUP 5, $00, $10, $01, $30, $C0, $50, $A0, $60
        .repeat 22, i
        sta WSYNC
        DELAY 62 + (i .mod 8)
        sta HMOVE
        .endrep
        SETUP 6, $00, $10, $11, $70, $70, $70, $70, $70
        .repeat 22, i
        sta WSYNC
        sta HMOVE
        DELAY_ i
        sta HMCLR
        lda #$70
        sta HMP0
        sta HMM1
        sta HMBL
        .endrep
        SETUP 7, $00, $10, $01, $80, $70, $80, $70, $70
        LATE 0, 2

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
