; SPDX-License-Identifier: Apache-2.0
; win_off_pixel: the Game Boy's blank pixel with the window disabled.
;
; Once WY has matched in a frame, the window stays triggered for the frame. If LCDC bit 5 is then
; cleared, the window isn't drawn, but on the Game Boy (not the Color) a WX matching the line's
; position + 7 while the fetcher waits to push with the BG FIFO empty puts one blank pixel
; (colour 0) into the FIFO, and the line's pixels after it move right by one (SameBoy issue 278).
;
; The frame: WY = 0, WX = 7, the window on (tile 2, solid colour 2) for lines 0-31 and 112-143,
; and off for lines 32-111, where the background shows (tile 1: colour 3 in its first column,
; colour 1 in the rest) with SCX = 0; BGP = $1B, so the blank pixel is black. With WX = 7 the
; match comes at the line's start: an extra black column at x = 0. Lines 64-95 have WX = 87, a
; match partway along the line, where the fetcher is mid-tile: SameBoy has the pixel only with
; the FIFO empty there. The LY=LYC interrupt, a line sooner, waits for its line's mode 0 and makes
; each change there, so each takes effect from the next line's start (no write lands in mode 3).

DEF rLCDC EQU $FF40
DEF rSTAT EQU $FF41
DEF rSCY  EQU $FF42
DEF rSCX  EQU $FF43
DEF rLY   EQU $FF44
DEF rLYC  EQU $FF45
DEF rBGP  EQU $FF47
DEF rWY   EQU $FF4A
DEF rWX   EQU $FF4B
DEF rIF   EQU $FF0F
DEF rIE   EQU $FFFF

DEF LCDCF_ON     EQU $80
DEF LCDCF_WIN9C00 EQU $40
DEF LCDCF_WINON  EQU $20
DEF LCDCF_BG8000 EQU $10
DEF LCDCF_BGON   EQU $01
DEF STATF_LYC    EQU $40
DEF IEF_STAT     EQU $02

SECTION "vblank", ROM0[$40]
    reti

SECTION "stat", ROM0[$48]
    jp Stat

SECTION "header", ROM0[$100]
    nop
    jp Start
    ds $150 - @, 0

SECTION "main", ROM0[$150]
Start:
    di
    ld sp, $FFFE
.waitvb:
    ldh a, [rLY]
    cp 144
    jr nz, .waitvb
    xor a
    ldh [rLCDC], a              ; the LCD off

    ; tile 0: blank; tile 1: colour 3 in column 0, colour 1 in the rest; tile 2: solid colour 2
    ld hl, $8000
    ld bc, 16
    xor a
    call Fill
    ld b, 8
.tile1:
    ld a, $FF                   ; low bitplane: every pixel 1
    ld [hl+], a
    ld a, $80                   ; high bitplane: column 0 also 1 (colour 3)
    ld [hl+], a
    dec b
    jr nz, .tile1
    ld b, 8
.tile2:
    xor a
    ld [hl+], a
    ld a, $FF
    ld [hl+], a
    dec b
    jr nz, .tile2

    ld hl, $9800                ; the background map: tile 1
    ld bc, $400
    ld a, 1
    call Fill
    ld hl, $9C00                ; the window map: tile 2
    ld bc, $400
    ld a, 2
    call Fill

    ld a, $1B
    ldh [rBGP], a
    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ldh [rWY], a
    ld a, 7
    ldh [rWX], a
    ld a, 31
    ldh [rLYC], a
    ld a, STATF_LYC
    ldh [rSTAT], a
    ld a, IEF_STAT
    ldh [rIE], a
    xor a
    ldh [rIF], a
    ; on, the window on with map $9C00, tiles at $8000, the background on
    ld a, LCDCF_ON | LCDCF_WIN9C00 | LCDCF_WINON | LCDCF_BG8000 | LCDCF_BGON
    ldh [rLCDC], a
    ei
.forever:
    halt
    jr .forever

; LY=LYC at 31, 63, 95 and 111, each change in that line's mode 0: from line 32 the window off,
; from 64 WX 87, from 96 WX 7, from 112 the window on; then 31 again.
Stat:
    push af
.hblank:
    ldh a, [rSTAT]
    and 3
    jr nz, .hblank
    ldh a, [rLY]
    cp 31
    jr z, .off
    cp 63
    jr z, .wx87
    cp 95
    jr z, .wx7
    ; 111
    ld a, LCDCF_ON | LCDCF_WIN9C00 | LCDCF_WINON | LCDCF_BG8000 | LCDCF_BGON
    ldh [rLCDC], a
    ld a, 31
    jr .next
.off:
    ld a, LCDCF_ON | LCDCF_WIN9C00 | LCDCF_BG8000 | LCDCF_BGON
    ldh [rLCDC], a
    ld a, 63
    jr .next
.wx87:
    ld a, 87
    ldh [rWX], a
    ld a, 95
    jr .next
.wx7:
    ld a, 7
    ldh [rWX], a
    ld a, 111
.next:
    ldh [rLYC], a
    pop af
    reti

; Fill: BC bytes of A from HL.
Fill:
    ld d, a
.loop:
    ld a, d
    ld [hl+], a
    dec bc
    ld a, b
    or c
    jr nz, .loop
    ret
