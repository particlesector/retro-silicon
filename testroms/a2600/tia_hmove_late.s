; SPDX-License-Identifier: Apache-2.0
; Late HMOVEs: HMOVE written near a line's end, at cycles 64 to 72, so its movement runs on into the
; next line's blank, with player 1's HM value 0, 1, 3, 7, 8, 9, 12 or 15 (as Ice Hockey moves its
; player with HM 0 and HMOVE at cycles 69-72).
;
; 72 pairs of lines from the picture's first: pair k's HMOVE at cycle 64 + k / 8, with HM value
; HMV[k mod 8]. Its first line sets HMP1, places player 1 left of the middle (RESP1 written at cycle 42),
; and writes HMOVE at its cycle; its second draws player 1 as one pixel (GRP1 $80), so the pixel's
; column shows where the movement left it. The other 48 lines are blank. Line cycles count from the
; CPU's first cycle after WSYNC, 0; a STA writes on its third.

.include "vcs.inc"

PAIRS = 72
NE = 24                 ; the sled: entering it at NE - D delays D + 3 cycles
CYC0 = 64               ; pair 0's HMOVE cycle

pair    = $80           ; the pair being drawn
ptr     = $81           ; where its first line enters the sled
tmp     = $83

.segment "CODE"
reset:  sei
        cld
        ldx #$FF
        txs
        ; Clear zero page: RAM and every TIA register.
        lda #0
        tax
@clr:   sta $00,x
        inx
        bne @clr
        lda #$0E
        sta COLUP1

frame:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #2
        sta VBLANK
        ldy #36
@vb:    sta WSYNC
        dey
        bne @vb
        lda #0
        sta pair
        jsr plan
        sta WSYNC
        lda #0
        sta VBLANK

pairs:  sta WSYNC               ; the pair's first line, cycle 0
        lda pair                ; 3
        and #7                  ; 2: 5
        tay                     ; 2: 7
        lda HMV,y               ; 4: 11
        sta HMP1                ; 3: 14
        ldx #5                  ; 2: 16, then 24 cycles
@w:     dex
        bne @w
        sta RESP1               ; written at 42
        jmp (ptr)               ; at 43: HMOVE written at 53 + D
sled:   .res NE, $C9            ; CMP #$C9 pairs: entered at NE - D, D + 3 cycles in all
        .byte $C5, $EA
        sta HMOVE
        sta WSYNC               ; the pair's second line
        lda #$80
        sta GRP1                ; written at 4
        inc pair                ; 10
        jsr plan                ; 55: the next pair's sled
        lda #0
        sta GRP1                ; written at 59, after player 1 is drawn
        lda pair
        cmp #PAIRS
        bne pairs               ; 68: its WSYNC written at 70

        ldy #48
@blank: sta WSYNC
        dey
        bne @blank
        lda #2
        sta VBLANK
        ldy #30
@os:    sta WSYNC
        dey
        bne @os
        jmp frame

; ptr for pair `pair`: D = CYC0 + pair / 8 - 53, entering the sled at its end - D (39 cycles with
; the JSR).
plan:   lda pair
        lsr
        lsr
        lsr
        clc
        adc #CYC0 - 53
        sta tmp
        lda #<(sled + NE)
        sec
        sbc tmp
        sta ptr
        lda #>(sled + NE)
        sbc #0
        sta ptr + 1
        rts

HMV:    .byte $00, $10, $30, $70, $80, $90, $C0, $F0

.segment "VECTORS"
        .word reset, reset, reset
