; Video adapter for the engine port: the arcade text RAM ($110000-$110FFF,
; emulated byte for byte in arcade (big endian) order, as CannonBall's
; tile_layer->text_ram), the tile RAM pages the screens write directly
; (14-15: best outrunners table, music select, $10E000-$10FFFF), palette
; RAM writes (road / sky / tile palettes through PalSet) and
; video.enabled.  The text layer renderer reads txt_ram / txt_dirty.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"

.import PalSet, TextPalWrite

.export VidWriteText16, VidWriteText8, VidWriteText32, VidReadText8, VidReadText16
.export VidWriteTile16, VidWriteTile8, VidWriteTile32, VidReadTile8, VidReadTile16
.export VidWritePal32, VidClearTextRam, VidSetEnabled, VidInit
.export txt_ram, txt_dirty, tile_ram14, vid_enabled
.export VidDirty, VidMarkTextAll, txt_lo, txt_hi

.segment "BWBSS": far
txt_ram:    .res $1000          ; text RAM (arcade byte order)
tile_ram14: .res $2000          ; tile RAM pages 14-15 ($10E000-$10FFFF)

.segment "BSS"
txt_lo:     .res 64             ; first changed byte-column per row (128: clean)
txt_hi:     .res 64             ; last changed byte-column per row
txt_dirty:  .res 4              ; bit per text row (0-31)
vid_enabled: .res 2
vp_a:       .res 2
vp_v:       .res 2
vp_t:       .res 2

.segment "SA1CODE"
.a16
.i16

VidInit:
    stz vid_enabled
    jmp VidMarkTextAll

VidMarkTextAll:
    ldx #62
@row:
    stz txt_lo,x
    lda #126
    sta txt_hi,x
    dex
    dex
    bpl @row
    lda #$FFFF
    sta txt_dirty
    sta txt_dirty+2
    rts

; Dirty / VidDirty: A = text RAM offset (0-$FFF) -> row bit set (A, X
; clobbered)
VidDirty:
Dirty:
    pha
    pha
    and #$007E
    sta vp_t
    pla
    asl a
    xba
    and #$001F
    asl a
    tax
    lda vp_t
    cmp txt_lo,x
    bcs :+
    sta txt_lo,x
:   lda vp_t
    cmp txt_hi,x
    bcc :+
    sta txt_hi,x
:   pla
    asl a                       ; row = offset >> 7: bits 8-12 after the shift
    xba
    and #$001F
    cmp #16
    bcs :+
    asl a
    tax
    lda f:Bit16,x
    tsb txt_dirty
    rts
:   and #$000F
    asl a
    tax
    lda f:Bit16,x
    tsb txt_dirty+2
    rts

;----------------------------------------------------------------------------
; text RAM: A = address (low word), X = value
;----------------------------------------------------------------------------
VidWriteText16:
    and #$0FFF
    pha
    txa
    xba                         ; arcade order: high byte first
    plx
    cmp f:txt_ram,x
    beq @same                   ; (the HUD rewrites unchanged cells every tick)
    sta f:txt_ram,x
    txa
    jmp Dirty
@same:
    rts

VidWriteText8:
    and #$0FFF
    sta vp_a
    txa
    ldx vp_a
    sep #$20
    .a8
    cmp f:txt_ram,x
    beq @same
    sta f:txt_ram,x
    rep #$20
    .a16
    lda vp_a
    jmp Dirty
@same:
    rep #$20
    rts

; A = address, X = high word, Y = low word
VidWriteText32:
    and #$0FFF
    sta vp_a
    sty vp_v
    txa
    xba                         ; high word, arcade order
    sta vp_t
    ldx vp_a
    cmp f:txt_ram,x
    bne @w
    lda vp_v
    xba
    cmp f:txt_ram+2,x
    beq @same
@w: lda vp_t
    sta f:txt_ram,x
    lda vp_v
    xba
    sta f:txt_ram+2,x
    lda vp_a
    jsr Dirty
    lda vp_a
    clc
    adc #2
    and #$0FFF
    jmp Dirty
@same:
    rts

VidReadText8:
    and #$0FFF
    tax
    lda f:txt_ram,x
    and #$00FF
    rts

VidReadText16:
    and #$0FFF
    tax
    lda f:txt_ram,x
    xba
    rts

;----------------------------------------------------------------------------
; tile RAM (pages 14-15 only; other addresses are not displayed directly by
; the SNES tile backend): A = address (low word), X = value
;----------------------------------------------------------------------------
TileOfs:                        ; A = address -> X = offset, C set if outside
    cmp #$E000
    bcc :+
    and #$1FFF
    tax
    clc
    rts
:   sec
    rts

VidWriteTile16:
    stx vp_v
    jsr TileOfs
    bcs :+
    lda vp_v
    xba
    sta f:tile_ram14,x
:   rts

VidWriteTile8:
    stx vp_v
    jsr TileOfs
    bcs :+
    lda vp_v
    sep #$20
    .a8
    sta f:tile_ram14,x
    rep #$20
    .a16
:   rts

VidWriteTile32:
    stx vp_v
    sty vp_a
    jsr TileOfs
    bcs :+
    lda vp_v
    xba
    sta f:tile_ram14,x
    lda vp_a
    xba
    sta f:tile_ram14+2,x
:   rts

VidReadTile8:
    jsr TileOfs
    bcs :+
    lda f:tile_ram14,x
    and #$00FF
    rts
:   lda #0
    rts

VidReadTile16:
    jsr TileOfs
    bcs :+
    lda f:tile_ram14,x
    xba
    rts
:   lda #0
    rts

;----------------------------------------------------------------------------
; VidWritePal32: A = palette RAM address (low word), X = high word, Y = low
; word of the value (two entries).  Entries $400-$7FF go to PalSet.
;----------------------------------------------------------------------------
VidWritePal32:
    and #$1FFF
    lsr a
    sta vp_a                    ; entry
    sty vp_v
    txa
    ldx vp_a
    jsr PalOne
    lda vp_a
    inc a
    tax
    lda vp_v
PalOne:                         ; X = entry, A = colour
    cpx #$0040
    bcs :+
    jmp TextPalWrite            ; text palettes 0-7
:   cpx #$0400
    bcc :+
    cpx #$0800
    bcs :+
    jmp PalSet
:   rts

;----------------------------------------------------------------------------
; VidClearTextRam / VidSetEnabled (A = 0/1)
;----------------------------------------------------------------------------
VidClearTextRam:
    ldx #0
    lda #0
:   sta f:txt_ram,x
    inx
    inx
    cpx #$1000
    bcc :-
    jmp VidMarkTextAll

VidSetEnabled:
    and #$00FF
    sta vid_enabled
    rts

.segment "RODATA"
Bit16:
    .repeat 16, I
    .word 1 << I
    .endrepeat
.endif
