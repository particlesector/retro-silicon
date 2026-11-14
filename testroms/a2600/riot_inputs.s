; SPDX-License-Identifier: Apache-2.0
; The controllers and the console's switches, as an input script sets them frame by frame: the
; joysticks (SWCHA), the switches (SWCHB) and the fire buttons (INPT4, INPT5), with the fire buttons'
; latch (VBLANK bit 6) and SWCHA with half its port driven as outputs.
;
; Each frame, 20 lines after VSYNC, the cartridge records what it reads, for 16 frames: frame k + 2
; (Stella's count, the first frame ending at the first VSYNC) is sample k, k = 0-15, in result bytes
; 2k and 2k + 1:
;   2k:     SWCHA
;   2k + 1: SWCHB's switches (bits 7, 6, 3, 1, 0) with INPT4's bit 7 in bit 4 and INPT5's in bit 5
; From sample 8 (frame 10) VBLANK keeps bit 6 set, so INPT4 and INPT5 hold a press until the end. From
; sample 12 (frame 14) SWCHA is read with its high nibble an output of $5 (SWACNT = $F0, SWCHA = $50),
; so player 0's pins read as the joystick and the output together, and the nibble set back to input.
;
; The frames' input script is the manifest's (input = ...), the same in Stella and on the core. After
; frame 17, nothing changes. The timer times VBLANK, so every frame has 262 lines.

.include "vcs.inc"

FRAME = $80                     ; samples taken, up to 16
LATCH = $81                     ; VBLANK's bit 6: $40 from sample 8

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
        sta SWACNT
        sta SWBCNT

frame:  lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        lda #43                 ; 37 lines' VBLANK, ending at a WSYNC
        sta TIM64T
        lda FRAME
        cmp #8
        bcc :+
        lda #$40                ; the fire buttons latched from here on
        sta LATCH
:       lda LATCH
        ora #2
        sta VBLANK
        ldx #20
@vb1:   sta WSYNC
        dex
        bne @vb1

        lda FRAME
        cmp #16
        bcs @wait
        asl a
        tay
        lda FRAME
        cmp #12
        bcc @in
        lda #$F0
        sta SWACNT
        lda #$50
        sta SWCHA
@in:    lda SWCHA
        sta RESULTS,y
        lda #0
        sta SWACNT
        lda SWCHB
        and #$CB
        sta RESULTS+1,y
        lda INPT4
        and #$80
        lsr a
        lsr a
        lsr a
        ora RESULTS+1,y
        sta RESULTS+1,y
        lda INPT5
        and #$80
        lsr a
        lsr a
        ora RESULTS+1,y
        sta RESULTS+1,y
        inc FRAME

@wait:  lda INTIM
        bne @wait
        sta WSYNC
        lda LATCH
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
        lda LATCH
        ora #2
        sta VBLANK
        ldx #30
@os:    sta WSYNC
        dex
        bne @os
        jmp frame

.segment "VECTORS"
        .word reset, reset, reset
