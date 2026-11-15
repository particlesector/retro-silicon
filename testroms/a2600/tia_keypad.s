; SPDX-License-Identifier: Apache-2.0
; Keypads (Stella's Keyboard controller) in both joystick ports, no key pressed, against Stella's
; keypad: each column of 3 keys is wired to 5 V through 4.7 kohm inside the keypad, so with no key
; down INPT0 and INPT1 (the left keypad's first two columns) and INPT2 and INPT3 (the right's) charge
; like a paddle's input with a 4.7 kohm pot: about 187 cycles after a dump ends, the TIA reads 1.
; The keypad's rows are port A's pins (SWCHA, the left's 4-7, the right's 0-3); with no key down
; they don't change the columns.
;
; Two frames dumped throughout, then 128 measured: in two halves, the rows left as inputs (SWACNT 0)
; and then driven low (SWACNT $FF, SWCHA 0); in each, 32 frames an input, from INPT0 to INPT3. Each
; measured frame, on line 4: sets VBLANK bit 7 (the dump) and clears it 40 cycles later, then reads
; the input E cycles after (E from the frame's number mod 16, a cycle apart), which shows the cycle
; the input crosses on and so its charge.
;
; Results (show.inc):
;   0-15: the reads, frame f's (f from 0) in byte f / 8, bit 7 - f mod 8 (each input's 16 reads in
;         two bytes, the rows as inputs in bytes 0-7, driven low in 8-15)
;   16:   SWCHA read with SWACNT $FF and SWCHA 0 (Stella: 0)
;   17:   SWCHA read with SWACNT 0 (Stella: $FF)
;   18:   INPT4 bit 7, then INPT5's in bit 6 (the third columns, the fire buttons' lines: $C0)
;   19:   the OR of every read in a dump (0)
; Bytes 20-31 are 0.

.include "vcs.inc"

WARMUP = 2
MEASURED = 128
NE = 16                 ; the read's sled: entering it at NE - D delays D + 3 cycles

frame   = $80           ; frames since power-up
port    = $81           ; the input this frame reads (0-3)
rptr    = $82           ; where the read's sled is entered
rel     = $84           ; what line 4 writes to VBLANK to end the dump (2; $82 while warming up)
during  = $85           ; the read in the dump
hit     = $86           ; the read after it
tmp     = $87

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
        jmp last
@go:    lda #2
        sta VSYNC
        ; The rows: inputs in the first half, driven low in the second.
        lda #0
        sta SWCHA
        lda frame
        sec
        sbc #WARMUP
        bcc @in
        cmp #MEASURED / 2
        bcc @in
        lda #$FF
        bne @ddr
@in:    lda #0
@ddr:   sta SWACNT
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC
        ldx port
        ldy #$82
        sta WSYNC               ; line 4, cycle 0
        sty VBLANK              ; the dump, at 3
        ldy #7                  ; 40 cycles of dump
@dump:  dey
        bne @dump
        lda INPT0,x             ; read in the dump
        ora during
        sta during
        lda rel
        sta VBLANK              ; the dump's end
        ldy #34                 ; 169 cycles
@wait:  dey
        bne @wait
        jmp (rptr)
rsled:  .res NE, $C9
        .byte $C5, $EA
        lda INPT0,x             ; read E cycles after the dump's end
        sta hit
        sta WSYNC

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
        bpl @done
        lda RESULTS,x
        ora tmp
        sta RESULTS,x
@done:  inc frame
        sta WSYNC
        jsr plan
        ldy #255
@os:    sta WSYNC
        dey
        bne @os
        jmp nextf

; The next frame's input and read: frame f - WARMUP's, or while warming up a dump that doesn't end.
plan:   lda frame
        sec
        sbc #WARMUP
        bcs @meas
        lda #$82
        sta rel
        lda #0
        sta port
        tay                     ; D = 0
        beq @ptr
@meas:  cmp #MEASURED
        bcs @end
        tay
        lsr
        lsr
        lsr
        lsr
        and #3
        sta port
        lda #2
        sta rel
        tya
        and #NE - 1
        tay
@ptr:   sty tmp                 ; rptr = rsled + NE - D
        lda #<(rsled + NE)
        sec
        sbc tmp
        sta rptr
        lda #>(rsled + NE)
        sbc #0
        sta rptr + 1
@end:   rts

; Port A and the third columns, then the results.
last:   lda #0
        sta VBLANK
        sta SWCHA
        lda #$FF
        sta SWACNT
        ldx #0
        lda SWCHA,x
        sta RESULTS+16
        stx SWACNT
        lda SWCHA,x
        sta RESULTS+17
        lda INPT5
        and #$80
        lsr
        sta tmp
        lda INPT4
        and #$80
        ora tmp
        sta RESULTS+18
        lda during
        and #$80
        sta RESULTS+19
        jmp show

; Never run: Stella gives a cartridge keypads in both ports when it reads the fire buttons and
; INPT0-3 this way (its ControllerDetector).
detect: bit INPT4
        bmi detect
        bit INPT5
        bmi detect
        bit INPT0
        bmi detect
        bit INPT1
        bmi detect
        bit INPT2
        bmi detect
        bit INPT3
        bmi detect

mask:   .byte $80, $40, $20, $10, $08, $04, $02, $01

.include "show.inc"

.segment "VECTORS"
        .word reset, reset, reset
