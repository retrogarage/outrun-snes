; OPalette: sky, ground and road palettes - port of CannonBall DX
; engine/opalette.cpp (classic arcade), on the arcade palette mirror PALAR /
; PALSN (PalSet, rrender.s): the road colours go to CGRAM, the sky / solid
; and ground colours are the per-line backdrop (HDMA).
;
;   setup_*          stage 1 colours (oinitengine.init)
;   setup_sky_change current + next sky palette (on the road split)
;   setup_sky_cycle  30 intermediate sky palettes, one colour per tick
;   cycle_sky_palette  shows them in turn (vertical interrupt)
;   fade_palette     road and ground colours fade over $80 vertical
;                    interrupts (setup takes two)
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "gamevars.inc"
.include "road.inc"
.include "roaddata.inc"

.import PalSet

.export OPalInit, OPalSetupStage, SetupSkyChange, SetupSkyCycle
.export CycleSkyPalette, FadePalette, pal_manip_ctrl

.segment "BSS"
pal_manip_ctrl:    .res 2
sky_palette_init:  .res 2
cycle_counter:     .res 2
fade_counter:      .res 2
sky_palette_index: .res 2
sky_fade_offset:   .res 2
op_t:              .res 8
pal_fade:          .res 9*$18*2   ; 24 entries x 9 words (see opalette.hpp)

.segment "BWBSS": far
pal_manip:         .res 32*64*2   ; 32 sky palettes x 64 words (arcade order)

.segment "SA1CODE"
.a16
.i16

OPalInit:
    stz sky_palette_init
    stz sky_fade_offset
    stz cycle_counter
    rts

;----------------------------------------------------------------------------
; LevelPalPtr: A = stage lookup offset -> X = ArcLevelPals offset
; (trackloader.get_level: level = [0,1,3,6,10][off >> 3] + (off & 7))
;----------------------------------------------------------------------------
LevelPalPtr:
    pha
    lsr a
    lsr a
    lsr a
    and #7
    asl a
    tax
    pla
    and #7
    clc
    adc f:LpBase,x
    ; * 192
    sta op_t
    asl a
    clc
    adc op_t                ; *3
    xba
    lsr a
    lsr a                   ; *3*64
    tax
    rts

;----------------------------------------------------------------------------
; OPalSetupStage: colours of the level at stage_lookup_off (setup_sky_palette,
; setup_ground_color, setup_road_centre/stripes/side/colour)
;----------------------------------------------------------------------------
OPalSetupStage:
    lda stage_lookup_off
    jsr LevelPalPtr
    stx op_t+2
    ; sky -> $780-$7BF
    ldy #0
:   phy
    lda f:ArcLevelPals+ARCPAL_SKY,x
    pha
    tya
    clc
    adc #$0780
    tax
    pla
    jsr PalSet
    ply
    tya
    asl a
    clc
    adc op_t+2
    adc #2
    tax
    iny
    cpy #64
    bne :-
    ; ground -> $420-$42F and $430-$43F
    ldx op_t+2
    ldy #0
:   phy
    lda f:ArcLevelPals+ARCPAL_GND,x
    sta op_t+4
    tya
    clc
    adc #$0420
    tax
    lda op_t+4
    jsr PalSet
    ply
    phy
    tya
    clc
    adc #$0430
    tax
    lda op_t+4
    jsr PalSet
    ply
    tya
    asl a
    clc
    adc op_t+2
    adc #2
    tax
    iny
    cpy #16
    bne :-
    ; road 1 / road 2 -> $400-$40F
    ldx op_t+2
    ldy #0
:   phy
    lda f:ArcLevelPals+ARCPAL_ROAD,x
    pha
    tya
    clc
    adc #$0400
    tax
    pla
    jsr PalSet
    ply
    tya
    asl a
    clc
    adc op_t+2
    adc #2
    tax
    iny
    cpy #16
    bne :-
    rts

;----------------------------------------------------------------------------
; SetupSkyChange: current sky palette + the next stage's (setup_sky_change)
;----------------------------------------------------------------------------
SetupSkyChange:
    ldx #0
:   lda f:PALAR+($780-$400)*2,x
    sta f:pal_manip,x
    inx
    inx
    cpx #128
    bne :-
    lda stage_lookup_off
    ldx end_stage_props
    pha
    txa
    and #$0004
    bne :+
    pla
    clc
    adc #8
    pha
:   lda end_stage_props
    and #$FFFB
    sta end_stage_props
    pla
    jsr LevelPalPtr
    ldy #0
:   lda f:ArcLevelPals+ARCPAL_SKY,x
    phx
    tyx
    sta f:pal_manip+$1F*128,x
    plx
    inx
    inx
    iny
    iny
    cpy #128
    bne :-
    lda sky_palette_init
    ora #1
    sta sky_palette_init
    ; (Yu Suzuki easter egg with START: text layer, see hud)
    rts

;----------------------------------------------------------------------------
; SetupSkyCycle: one colour of the 30 intermediate palettes per call
;----------------------------------------------------------------------------
SetupSkyCycle:
    lda sky_fade_offset
    bne @go
    lda sky_palette_init
    tax
    and #$FFFE
    sta sky_palette_init
    txa
    and #1
    bne @go
    rts
@go:
    lda sky_fade_offset
    inc a
    sta sky_fade_offset
    cmp #$41
    bcc :+
    lda sky_palette_init
    ora #2
    sta sky_palette_init
    stz sky_fade_offset
    rts
:   dec a                   ; word index j (0-63)
    asl a
    tax
    stx op_t+6
    lda f:pal_manip,x
    sta op_t                ; start colour
    lda f:pal_manip+$1F*128,x
    sta op_t+2              ; end colour
    ; fade_sky_pal_entry: channels << 6, step = (end - start) >> 5
    lda op_t
    jsr Chan5
    sta fs_r1
    stx fs_g1
    sty fs_b1
    lda op_t+2
    jsr Chan5
    sec
    sbc fs_r1
    jsr Asr5
    sta fs_r2
    txa
    sec
    sbc fs_g1
    jsr Asr5
    sta fs_g2
    tya
    sec
    sbc fs_b1
    jsr Asr5
    sta fs_b2
    ; palettes 1..$1E, word j
    lda op_t+6
    clc
    adc #128
    tax
    ldy #$1E
@pal:
    lda fs_r1
    clc
    adc fs_r2
    sta fs_r1
    lda fs_g1
    clc
    adc fs_g2
    sta fs_g1
    lda fs_b1
    clc
    adc fs_b2
    sta fs_b1
    ; rgb = bit6 -> bits 12/13/14, bits 7-10 -> nibbles
    lda fs_r1
    and #$0040
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a                   ; << 6: bit 12
    sta op_t
    lda fs_g1
    and #$0040
    xba
    lsr a                   ; bit 13
    tsb op_t
    lda fs_b1
    and #$0040
    xba                     ; bit 14
    tsb op_t
    lda fs_r1
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    and #$000F
    tsb op_t
    lda fs_g1
    lsr a
    lsr a
    lsr a
    and #$00F0
    tsb op_t
    lda fs_b1
    asl a
    and #$0F00
    ora op_t
    sta f:pal_manip,x
    txa
    clc
    adc #128
    tax
    dey
    bne @pal
    rts

; Chan5: A = arcade colour -> A = r5 << 6, X = g5 << 6, Y = b5 << 6
Chan5:
    sta fs_t
    and #$000F
    asl a
    sta fs_u
    lda fs_t
    and #$1000
    beq :+
    inc fs_u
:   lda fs_u
    jsr Shl6
    pha
    lda fs_t
    lsr a
    lsr a
    lsr a
    and #$001E
    sta fs_u
    lda fs_t
    and #$2000
    beq :+
    inc fs_u
:   lda fs_u
    jsr Shl6
    pha
    lda fs_t
    xba
    and #$000F
    asl a
    sta fs_u
    lda fs_t
    and #$4000
    beq :+
    inc fs_u
:   lda fs_u
    jsr Shl6
    tay
    plx
    pla
    rts
Shl6:
    asl a
    asl a
    asl a
    asl a
    asl a
    asl a
    rts
; Asr5: A (int) >> 5 arithmetic (C++ int shift, stored back as uint16)
Asr5:
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    rts

.segment "BSS"
fs_r1: .res 2
fs_g1: .res 2
fs_b1: .res 2
fs_r2: .res 2
fs_g2: .res 2
fs_b2: .res 2
fs_t:  .res 2
fs_u:  .res 2
.segment "SA1CODE"

;----------------------------------------------------------------------------
; CycleSkyPalette (vertical interrupt): next intermediate sky palette
;----------------------------------------------------------------------------
CycleSkyPalette:
    lda sky_palette_init
    and #2
    bne :+
    rts
:   inc cycle_counter       ; (the arcade's odd/even test always passes)
    lda sky_palette_index
    inc a
    sta sky_palette_index
    cmp #$20
    bcc @show
    lda sky_palette_init
    and #$FFFD
    sta sky_palette_init
    stz sky_palette_index
    ; (clears the easter egg text outside best outrunners)
    rts
@show:
    xba
    lsr a                   ; * 128 bytes
    sta op_t
    ldy #0
:   phy
    tya
    asl a
    clc
    adc op_t
    tax
    lda f:pal_manip,x
    pha
    tya
    clc
    adc #$0780
    tax
    pla
    jsr PalSet
    ply
    iny
    cpy #64
    bne :-
    rts

;----------------------------------------------------------------------------
; FadePalette (vertical interrupt): road / ground colours to the next stage's
;----------------------------------------------------------------------------
FadePalette:
    lda pal_manip_ctrl
    and #1
    bne :+
    rts
:   lda game_state
    cmp #GS_ATTRACT
    beq :+
    cmp #GS_INGAME
    beq :+
    rts
:   lda pal_manip_ctrl
    and #2
    bne :+
    jmp SetupFadeData
:   ; do_next_fade
    ldx #0
    ldy #$18
@e: lda pal_fade+6,x
    clc
    adc pal_fade+12,x
    sta pal_fade+6,x
    lda pal_fade+8,x
    clc
    adc pal_fade+14,x
    sta pal_fade+8,x
    lda pal_fade+10,x
    clc
    adc pal_fade+16,x
    sta pal_fade+10,x
    jsr RepackRgb
    txa
    clc
    adc #18
    tax
    dey
    bne @e
    jsr WriteFadeToPalram
    dec fade_counter
    bne :+
    stz pal_manip_ctrl
:   rts

; RepackRgb: X = entry offset (bytes)
RepackRgb:
    lda pal_fade+6,x        ; blue
    lsr a
    lsr a
    lsr a
    and #$0F00
    sta op_t
    lda pal_fade+6,x
    asl a
    asl a
    asl a
    asl a
    and #$4000
    tsb op_t
    lda pal_fade+8,x        ; green
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    and #$00F0
    tsb op_t
    lda pal_fade+8,x
    asl a
    asl a
    asl a
    and #$2000
    tsb op_t
    lda pal_fade+10,x       ; red
    xba
    lsr a
    lsr a
    lsr a
    and #$000F
    tsb op_t
    lda pal_fade+10,x
    asl a
    asl a
    and #$1000
    ora op_t
    sta pal_fade+2,x
    rts

; setup_fade_data (two calls: entries 0-11, then 12-23)
SetupFadeData:
    lda pal_manip_ctrl
    and #4
    beq :+
    ldx #$6C*2
    bra @ex
:   jsr WriteCurrentPalToRam
    jsr WriteNextPalToRam
    ldx #0
@ex:
    ldy #12
@l: phy
    ; blue
    lda pal_fade,x
    and #$0F00
    asl a
    asl a
    asl a
    sta op_t
    lda pal_fade,x
    and #$4000
    lsr a
    lsr a
    lsr a
    lsr a
    ora op_t
    sta pal_fade+6,x        ; d2
    sta op_t+2
    lda pal_fade+4,x
    and #$0F00
    asl a
    asl a
    asl a
    sta op_t
    lda pal_fade+4,x
    and #$4000
    lsr a
    lsr a
    lsr a
    lsr a
    ora op_t
    sec
    sbc op_t+2
    jsr Asr7
    sta pal_fade+12,x
    ; green
    lda pal_fade,x
    and #$00F0
    xba
    lsr a                   ; << 7
    sta op_t
    lda pal_fade,x
    and #$2000
    lsr a
    lsr a
    lsr a
    ora op_t
    sta pal_fade+8,x
    sta op_t+2
    lda pal_fade+4,x
    and #$00F0
    xba
    lsr a
    sta op_t
    lda pal_fade+4,x
    and #$2000
    lsr a
    lsr a
    lsr a
    ora op_t
    sec
    sbc op_t+2
    jsr Asr7
    sta pal_fade+14,x
    ; red
    lda pal_fade,x
    and #$000F
    xba
    asl a
    asl a
    asl a                   ; << 11
    sta op_t
    lda pal_fade,x
    and #$1000
    lsr a
    lsr a
    ora op_t
    sta pal_fade+10,x
    sta op_t+2
    lda pal_fade+4,x
    and #$000F
    xba
    asl a
    asl a
    asl a
    sta op_t
    lda pal_fade+4,x
    and #$1000
    lsr a
    lsr a
    ora op_t
    sec
    sbc op_t+2
    jsr Asr7
    sta pal_fade+16,x
    txa
    clc
    adc #18
    tax
    ply
    dey
    beq :+
    jmp @l
:   lda pal_manip_ctrl
    and #4
    beq :+
    lda #3
    sta pal_manip_ctrl
    lda #$80
    sta fade_counter
    rts
:   lda pal_manip_ctrl
    ora #4
    sta pal_manip_ctrl
    rts

Asr7:
    jsr Asr5
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    rts

; road colour 1 ($400-$407) and ground 1 ($420-$42F) -> pal_fade +0
WriteCurrentPalToRam:
    ldx #0
    ldy #0
:   phx
    tya
    asl a
    tax
    lda f:PALAR,x
    plx
    sta pal_fade,x
    txa
    clc
    adc #18
    tax
    iny
    cpy #8
    bne :-
    ldy #0
:   phx
    tya
    asl a
    tax
    lda f:PALAR+$20*2,x
    plx
    sta pal_fade,x
    txa
    clc
    adc #18
    tax
    iny
    cpy #16
    bne :-
    rts

; next stage's road 1 colours and ground -> pal_fade +4
WriteNextPalToRam:
    lda stage_lookup_off
    ldx end_stage_props
    pha
    txa
    and #$0002
    bne :+
    pla
    clc
    adc #8
    pha
:   lda end_stage_props
    and #$FFFD
    sta end_stage_props
    pla
    jsr LevelPalPtr
    stx op_t+4
    ldy #0
    ldx #4
:   phx
    tya
    asl a
    clc
    adc op_t+4
    tax
    lda f:ArcLevelPals+ARCPAL_ROAD,x
    plx
    sta pal_fade,x
    txa
    clc
    adc #18
    tax
    iny
    cpy #8
    bne :-
    ldy #0
:   phx
    tya
    asl a
    clc
    adc op_t+4
    tax
    lda f:ArcLevelPals+ARCPAL_GND,x
    plx
    sta pal_fade,x
    txa
    clc
    adc #18
    tax
    iny
    cpy #16
    bne :-
    rts

; write_fade_to_palram: road 1 + 2, ground 1 + 2
WriteFadeToPalram:
    ldy #0
@r: phy
    tya
    asl a
    sta op_t
    asl a
    asl a
    asl a
    clc
    adc op_t                ; * 18
    tax
    lda pal_fade+2,x
    sta op_t+2
    tya
    clc
    adc #$0400
    tax
    lda op_t+2
    jsr PalSet
    ply
    phy
    tya
    clc
    adc #$0408
    tax
    lda op_t+2
    jsr PalSet
    ply
    iny
    cpy #8
    bne @r
    ldy #0
@g: phy
    tya
    clc
    adc #8
    asl a
    sta op_t
    asl a
    asl a
    asl a
    clc
    adc op_t
    tax
    lda pal_fade+2,x
    sta op_t+2
    tya
    clc
    adc #$0420
    tax
    lda op_t+2
    jsr PalSet
    ply
    phy
    tya
    clc
    adc #$0430
    tax
    lda op_t+2
    jsr PalSet
    ply
    iny
    cpy #16
    bne @g
    rts

.segment "RODATA"
LpBase: .word 0, 1, 3, 6, 10, 10, 10, 10
