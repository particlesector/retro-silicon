; SPDX-License-Identifier: Apache-2.0
; The paddles' inputs (INPT0-3) and their dump (VBLANK bit 7), against Stella's paddle circuit with
; every knob in the middle (500 kohm): each input's capacitor charges until the TIA reads it as 1,
; 190 lines after a dump; this checks the colour clock it crosses on.
;
; Two frames dumped throughout, then 128 measured, in 32 groups of 4, each group reading one input
; (group mod 4). Each measured frame, on line 4: reads the input (charged since the last frame), sets
; VBLANK bit 7, reads it again (dumped: 0), and clears bit 7 D cycles later (the group's DTAB), which
; leaves a trace of charge that moves the crossing by a fraction of a cycle to 50 colour clocks;
; then on line 193 reads the input at cycle 11 + E (ETAB). Each group's 4 reads are the 2 cycles
; before Stella's crossing and the 2 after (tia_paddles_plan.py, from the circuit's equations, plans
; them and prints the tables), so a read a colour clock early or late shows.
;
; Results (show.inc): bytes 0-15, the line 193 reads, frame f's in byte f / 8, bit 7 - f mod 8 (the
; groups' 0, 0, 1, 1); bytes 16-31, the same for the read before the dump, cleared if the read in the
; dump wasn't 0.

.include "vcs.inc"

WARMUP = 2              ; frames dumped throughout first
MEASURED = 128
ND = 60                 ; the dump's sled: entering it at ND - D delays D + 3 cycles
NE = 128                ; the read's sled

frame   = $80           ; frames since power-up
port    = $81           ; the input this frame reads (0-3)
dptr    = $82           ; where the dump's sled is entered
rptr    = $84           ; where the read's sled is entered
rel     = $86           ; what line 4 writes to VBLANK to end the dump (2; $82 while warming up)
pre     = $87           ; the read before the dump
during  = $88           ; the read in it
hit     = $89           ; the read on line 193
tmp     = $8A

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
        lda #$82
        sta VBLANK
        jsr plan

nextf:  lda frame
        cmp #WARMUP + MEASURED
        bcc @go
        jmp show
@go:    lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        ldx port
        ldy #$82
        sta WSYNC               ; line 4, cycle 0
        lda INPT0,x             ; read at cycle 3
        sty VBLANK              ; the dump, at 6
        sta pre
        ldy INPT0,x             ; read at 13: dumped
        sty during
        lda rel
        jmp (dptr)              ; 5, at 20
dsled:  .res ND, $C9            ; CMP #$C9 pairs: entered at ND - D, D + 3 cycles in all
        .byte $C5, $EA
        sta VBLANK              ; the dump's end, at 30 + D
        ldy #188
@lines: sta WSYNC
        dey
        bne @lines
        ldx port
        sta WSYNC               ; line 193, cycle 0
        jmp (rptr)
rsled:  .res NE, $C9
        .byte $C5, $EA
        lda INPT0,x             ; read at 11 + E
        sta hit
        sta WSYNC               ; line 194: the results

        lda frame
        sec
        sbc #WARMUP
        bcc @done               ; warming up: nothing to keep
        tay
        and #7
        tax
        lda mask,x
        sta tmp
        tya
        lsr
        lsr
        lsr
        tax
        lda hit
        bpl @pre
        lda RESULTS,x
        ora tmp
        sta RESULTS,x
@pre:   lda during
        bmi @done
        lda pre
        bpl @done
        lda RESULTS+16,x
        ora tmp
        sta RESULTS+16,x
@done:  inc frame
        sta WSYNC               ; line 195: the next frame's plan
        jsr plan
        ldy #66
@os:    sta WSYNC
        dey
        bne @os
        jmp nextf

; The next frame's input, dump and read: its group's DTAB and its ETAB, or while warming up a dump
; that doesn't end.
plan:   lda frame
        sec
        sbc #WARMUP
        bcs @meas
        lda #$82
        sta rel
        lda #0
        sta port
        tax                     ; D = 0
        tay                     ; E = 0
        beq @ptrs
@meas:  cmp #MEASURED
        bcs @end
        tay
        lsr
        lsr
        tax
        and #3
        sta port
        lda #2
        sta rel
        lda ETAB,y
        tay
        lda DTAB,x
        tax
@ptrs:  stx tmp                 ; dptr = dsled + ND - D
        lda #<(dsled + ND)
        sec
        sbc tmp
        sta dptr
        lda #>(dsled + ND)
        sbc #0
        sta dptr + 1
        sty tmp                 ; rptr = rsled + NE - E
        lda #<(rsled + NE)
        sec
        sbc tmp
        sta rptr
        lda #>(rsled + NE)
        sbc #0
        sta rptr + 1
@end:   rts

; Never run: Stella plugs in paddles for a cartridge that reads an input this way.
detect: lda INPT0,x
        bmi detect

mask:   .byte $80, $40, $20, $10, $08, $04, $02, $01

; From tia_paddles_plan.py.
DTAB:   .byte 4, 17, 30, 11, 24, 5, 18, 31, 12, 25, 6, 19, 32, 13, 26, 7, 20, 33, 14, 27, 8, 21, 34, 15, 28, 9, 22, 35, 16, 29, 10, 23
ETAB:   .byte 85, 70, 71, 72, 98, 99, 100, 101, 111, 112, 113, 114, 90, 91, 92, 93
        .byte 105, 106, 107, 108, 74, 75, 76, 77, 99, 100, 101, 102, 112, 113, 114, 115
        .byte 91, 92, 93, 94, 106, 107, 108, 109, 78, 79, 80, 81, 100, 101, 102, 103
        .byte 113, 114, 115, 116, 93, 94, 95, 96, 107, 108, 109, 110, 81, 82, 83, 84
        .byte 101, 102, 103, 104, 114, 115, 116, 117, 94, 95, 96, 97, 108, 109, 110, 111
        .byte 83, 84, 85, 86, 102, 103, 104, 105, 115, 116, 117, 118, 95, 96, 97, 98
        .byte 109, 110, 111, 112, 86, 87, 88, 89, 103, 104, 105, 106, 116, 117, 118, 119
        .byte 97, 98, 99, 100, 110, 111, 112, 113, 88, 89, 90, 91, 104, 105, 106, 107

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
