; OLogo: attract mode animated OutRun logo - port of the original CannonBall
; engine/ologo.cpp (classic).  The logo is seven sprite components in jump
; table entries entry_start .. entry_start+6 (entry_start =
; SPRITE_ENTRIES - $10): background oval, car, two birds, road base, palm
; tree, logo text.
; blit() (ologo.cpp 278) only runs when frame skipping (!tick_frame): omitted.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import FC_DoSprOrderShadows, FC_MapPalette, FC_Random   ; (farbank.py)
.import DoSprOrderShadows, MapPalette, Random

.export LogoEnable, LogoDisable, LogoTick

BIT_3 = $08

.segment "BSS"
palm_frames:    .res 8*4        ; uint32 palm_frames[8] (little endian longs)
entry_start:    .res 2          ; uint8 (0 until the first enable)
y_off:          .res 2          ; int16
lg_e:           .res 2          ; entry offset being processed
lg_i:           .res 2
lg_t:           .res 2
lg_u:           .res 2
lg_bx:          .res 2          ; bird x adjust (+8 / -2)
lg_by:          .res 2          ; bird y base ($4E / $52)

.segment "SA1CODE2"
.a16
.i16

; EntryInit: oentry::init(i) (oentry.hpp 156): X = entry offset, A = i
EntryInit:
    pha
    phx
    ldy #OE_SIZE/2
    lda #0
:   sta f:JT,x
    inx
    inx
    dey
    bne :-
    plx
    pla
    sep #$20
    .a8
    sta f:JT+OE_JUMP_INDEX,x
    lda #$FF
    sta f:JT+OE_FUNC,x          ; function_holder = -1
    lda #3
    sta f:JT+OE_SHADOW,x
    rep #$20
    .a16
    rts

; EOfs: A = k -> X = offset of jump_table[entry_start + k]
EOfs:
    clc
    adc entry_start
    xba                         ; (index < $100)
    lsr a
    lsr a
    tax
    rts

;----------------------------------------------------------------------------
; enable (ologo.cpp 27): A = y (int16)
;----------------------------------------------------------------------------
LogoEnable:
    eor #$FFFF
    inc a
    sta y_off                   ; y_off = -y
    lda #SPRITE_ENTRIES - $10
    sta entry_start
    ; enable block of sprites: init(i) for i = entry_start .. entry_start+6
    sta lg_i
@init:
    lda lg_i
    xba
    lsr a
    lsr a
    tax
    lda lg_i
    jsr EntryInit
    inc lg_i
    lda lg_i
    sec
    sbc entry_start
    cmp #7
    bcc @init
    ; palm_frames[0..7] = palm1, palm2, palm3, palm2, palm1, palm2, palm3, palm2
    ldx #0
:   lda f:PalmFramesInit,x
    sta palm_frames,x
    inx
    inx
    cpx #8*4
    bne :-
    jsr SetupSprite1
    jsr SetupSprite2
    jsr SetupSprite3
    jsr SetupSprite4
    jsr SetupSprite5
    jsr SetupSprite6
    jmp SetupSprite7

;----------------------------------------------------------------------------
; disable (ologo.cpp 57)
;----------------------------------------------------------------------------
LogoDisable:
    stz lg_i
:   lda lg_i
    jsr EOfs
    LDEB OE_CONTROL
    and #$FFFF-C_ENABLE
    STEB OE_CONTROL
    inc lg_i
    lda lg_i
    cmp #7
    bcc :-
    rts

;----------------------------------------------------------------------------
; tick (ologo.cpp 66)
;----------------------------------------------------------------------------
LogoTick:
    jsr SpriteLogoBg
    jsr SpriteLogoCar
    jsr SpriteLogoBird1
    jsr SpriteLogoBird2
    jsr SpriteLogoRoad
    jsr SpriteLogoPalm
    jmp SpriteLogoText

; setup_sprite1 (ologo.cpp 78): animated background oval
SetupSprite1:
    lda #0
    jsr EOfs
    lda #0
    STE OE_X
    lda #$70
    sec
    sbc y_off
    STE OE_Y
    lda #$FF
    STE OE_ROAD_PRIORITY
    lda #$1FA
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$99
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_BG)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_BG)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite2 (ologo.cpp 92): car
SetupSprite2:
    lda #1
    jsr EOfs
    lda #$FFFD                  ; -3
    STE OE_X
    lda #$88
    sec
    sbc y_off
    STE OE_Y
    lda #$100
    STE OE_ROAD_PRIORITY
    lda #$1FB
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$6E
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_CAR)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_CAR)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite3 (ologo.cpp 106): flying bird #1
SetupSprite3:
    lda #2
    jsr EOfs
    lda #8
    STE OE_X
    lda #$4E
    sec
    sbc y_off
    STE OE_Y
    lda #$102
    STE OE_ROAD_PRIORITY
    lda #$1FD
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #0
    STE OE_COUNTER
    lda #$8B
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_BIRD1)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_BIRD1)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite4 (ologo.cpp 121): flying bird #2
SetupSprite4:
    lda #3
    jsr EOfs
    lda #8
    STE OE_X
    lda #$4E
    sec
    sbc y_off
    STE OE_Y
    lda #$102
    STE OE_ROAD_PRIORITY
    lda #$1FD
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$20
    STE OE_COUNTER
    lda #$8C
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_BIRD2)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_BIRD2)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite5 (ologo.cpp 136): road base section
SetupSprite5:
    lda #4
    jsr EOfs
    lda #$FFE0                  ; -$20
    STE OE_X
    lda #$8F
    sec
    sbc y_off
    STE OE_Y
    lda #$101
    STE OE_ROAD_PRIORITY
    lda #$1FC
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$6E
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_BASE)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_BASE)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite6 (ologo.cpp 150): palm tree
SetupSprite6:
    lda #5
    jsr EOfs
    lda #$FFC0                  ; -$40
    STE OE_X
    lda #$6D
    sec
    sbc y_off
    STE OE_Y
    lda #$102
    STE OE_ROAD_PRIORITY
    lda #$1FD
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$65
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_PALM1)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_PALM1)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite7 (ologo.cpp 164): OutRun logo text
SetupSprite7:
    lda #6
    jsr EOfs
    lda #$11
    STE OE_X
    lda #$65
    sec
    sbc y_off
    STE OE_Y
    lda #$103
    STE OE_ROAD_PRIORITY
    lda #$1FE
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #0
    STE OE_COUNTER
    lda #$65
    STE OE_PAL_SRC
    lda #.loword(SPRITE_LOGO_TEXT)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_TEXT)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; sprite_logo_bg (ologo.cpp 179): new random palette when bit 3 of reload
; changes
SpriteLogoBg:
    lda #0
    jsr EOfs
    stx lg_e
    LDE OE_RELOAD
    inc a
    STE OE_RELOAD               ; e->reload++
    sta lg_t                    ; d0
    dec a                       ; d1 = d0 - 1
    eor lg_t                    ; d1 ^= d0
    and #BIT_3
    beq @draw
    jsl $C10000+FC_Random   
    and #7
    tax
    lda f:bg_pal,x
    and #$00FF
    ldx lg_e
    STE OE_PAL_SRC              ; bg_pal[random() & 7]
    jsl $C10000+FC_MapPalette   
@draw:
    ldx lg_e
    jsl $C10000+FC_DoSprOrderShadows
    rts

; sprite_logo_car (ologo.cpp 197): flicker the car's background palette
SpriteLogoCar:
    lda #1
    jsr EOfs
    stx lg_e
    LDE OE_RELOAD
    inc a
    STE OE_RELOAD
    and #2
    beq :+
    lda #$8A
    bra :++
:   lda #$6E
:   STE OE_PAL_SRC
    jsl $C10000+FC_MapPalette   
    ldx lg_e
    jsl $C10000+FC_DoSprOrderShadows
    rts

; sprite_logo_bird1 (ologo.cpp 207)
SpriteLogoBird1:
    lda #8
    sta lg_bx
    lda #$4E
    sta lg_by
    lda #2
    bra SpriteLogoBird

; sprite_logo_bird2 (ologo.cpp 233): x = (bird_x >> 3) - 2, y base $52
SpriteLogoBird2:
    lda #$FFFE                  ; -2
    sta lg_bx
    lda #$52
    sta lg_by
    lda #3
    ; fall through

; SpriteLogoBird: A = k (entry_start + k), lg_bx / lg_by = the differences
SpriteLogoBird:
    jsr EOfs
    stx lg_e
    LDE OE_COUNTER
    inc a
    STE OE_COUNTER              ; e->counter++
    asl a
    and #$00FF
    sta lg_t                    ; index = (counter << 1) & 0xFF
    tax
    lda f:R0(DATA_MOVEMENT),x
    and #$00FF
    eor #$0080
    sec
    sbc #$0080                  ; bird_x = (int8) read8(DATA_MOVEMENT + index)
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a                       ; zoom = bird_x >> 3 (-16..15)
    sta lg_u
    clc
    adc lg_bx
    ldx lg_e
    STE OE_X                    ; x = (bird_x >> 3) + 8 (bird 2: - 2)
    lda lg_u
    clc
    adc #$70
    STEB OE_ZOOM                ; zoom = (uint8)(zoom + 0x70)
    lda lg_t
    asl a
    and #$00FF                  ; index = (index << 1) & 0xFF
    tax
    lda f:R0(DATA_MOVEMENT),x
    and #$00FF
    eor #$0080
    sec
    sbc #$0080                  ; bird_y (int8)
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a                       ; bird_y >> 5
    clc
    adc lg_by
    sec
    sbc y_off
    ldx lg_e
    STE OE_Y                    ; y = (bird_y >> 5) + 0x4E (0x52) - y_off
    LDE OE_RELOAD
    inc a
    STE OE_RELOAD               ; e->reload++
    and #4                      ; frame = (reload & 4) >> 2
    beq @b1
    lda #.loword(SPRITE_LOGO_BIRD2)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_BIRD2)
    STE OE_ADDR+2
    jsl $C10000+FC_DoSprOrderShadows
    rts
@b1:
    lda #.loword(SPRITE_LOGO_BIRD1)
    STE OE_ADDR
    lda #.hiword(SPRITE_LOGO_BIRD1)
    STE OE_ADDR+2
    jsl $C10000+FC_DoSprOrderShadows
    rts

; sprite_logo_road (ologo.cpp 259)
SpriteLogoRoad:
    lda #4
    jsr EOfs
    jsl $C10000+FC_DoSprOrderShadows
    rts

; sprite_logo_palm (ologo.cpp 264): animated palm tree
SpriteLogoPalm:
    lda #5
    jsr EOfs
    LDE OE_RELOAD
    inc a
    STE OE_RELOAD               ; e->reload++ (frame number)
    and #$E                     ; ((reload & 0xE) >> 1) * 4
    asl a
    tay
    lda palm_frames,y
    STE OE_ADDR
    lda palm_frames+2,y
    STE OE_ADDR+2
    jsl $C10000+FC_DoSprOrderShadows
    rts

; sprite_logo_text (ologo.cpp 272)
SpriteLogoText:
    lda #6
    jsr EOfs
    jsl $C10000+FC_DoSprOrderShadows
    rts

.segment "RODATA"
; bg_pal (ologo.cpp 17): background palette entries
bg_pal:
    .byte $9A, $9B, $9C, $9D, $9E, $9A, $9B, $9C
PalmFramesInit:
    .dword SPRITE_LOGO_PALM1, SPRITE_LOGO_PALM2, SPRITE_LOGO_PALM3, SPRITE_LOGO_PALM2
    .dword SPRITE_LOGO_PALM1, SPRITE_LOGO_PALM2, SPRITE_LOGO_PALM3, SPRITE_LOGO_PALM2
.endif
