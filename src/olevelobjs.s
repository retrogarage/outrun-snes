; OLevelObjs: level objects (scenery sprites) - port of the original
; CannonBall engine/olevelobjs.cpp (classic): spawning from the level
; scenery tables, the 15 sprite routines (placement on the road, collision
; checks, spray triggers, start lights, clouds, strips, mini trees...).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"
.include "road.inc"

.import DoSprOrderShadows, MapPalette, MoveSprite, seg_spr_addr, seg_spr_offset1
.import R0Set, R0Byte, R0Word, R0Long, SMul16, UMul16
.importzp rp0, mres
.import RoadYRaw, HEval, RD_Y, RD_X, road_p0, rd_co, rd_inv, MARK
.importzp RDB
.import game_state, cur_stage, checkpoint_marker

.export LevelObjSetupSprites, LevelObjDoSpriteRoutine, LevelObjHideSprite
.export LevelObjInitStartlineSprites, LevelObjInitHiscoreSprites
.export collision_sprite, spray_counter, spray_type, sprite_collision_counter

DEF_SPRITE_ENTRIES   = $44
HISCORE_SPRITE_ENTRIES = $40
COLLISION_RESET      = 4
SPRAY_RESET          = $C

.segment "IRAMBSS"          ; (hot: SA-1 I-RAM is twice as fast as BW-RAM)
collision_sprite:         .res 2    ; (uint8)
spray_counter:            .res 2
spray_type:               .res 2
sprite_collision_counter: .res 2
lo_x:       .res 2          ; entry offset being processed
lo_i:       .res 2
lo_z16:     .res 2
lo_zs:      .res 2          ; zoom shift
lo_t:       .res 4
lo_u:       .res 4
lo_x1:      .res 2
lo_x2:      .res 2
lo_a4:      .res 4
lo_n:       .res 2
lo_tab:     .res 4          ; thickness frame table
lo_fn:      .res 2          ; OE_FUNC of the entry do_sprite_routine runs
lo_h:       .res 2          ; (road0_h scratch)

.segment "BSS"
.export arch_group, arch_root, grid_people, grid_decor
grid_decor: .res 128*2     ; do not introduce new decorations after grid reveal
grid_people: .res 128*2    ; start-line residents; cleared when an engine slot is reused
arch_root: .res 128*2       ; fixed first pillar owns the complete renderer object
arch_group: .res 128*2      ; common identity for the four original collision parts
arch_phase: .res 2          ; console: retain one complete stone arch in two

; RDY223: A = 223 - (road_y[road_p0 + lo_z16] >> 4) (get_road_y), for
; 4 <= lo_z16 < $200 (after MoveZ16); X clobbered
.macro RDY223
    lda lo_z16
    asl a                   ; (C = 0)
    adc road_p0
    tax
    lda f:RDB*$10000+RD_Y,x
    eor #$8000              ; y >> 4 (arithmetic) = ((y ^ $8000) >> 4) - $800
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #223 + $800
.endmacro

.segment "SA1CODE"
.a16
.i16

;============================================================================
; hide_sprite (X = entry)
;============================================================================
LevelObjHideSprite:
    lda #0
    STE OE_Z
    STE OE_Z+2
    STEB OE_ZOOM
    LDEB OE_CONTROL
    and #$FFFF-C_ENABLE
    STEB OE_CONTROL
    rts

;============================================================================
; setup_sprites: A = z low word, X = z high word (32-bit default zoom)
;============================================================================
LevelObjSetupSprites:
    sta lo_u
    stx lo_u+2
    ldx #0
@f: LDEB OE_CONTROL
    and #C_ENABLE
    beq SetupSprite
    txa
    clc
    adc #OE_SIZE
    tax
    cpx #EOFS(NO_SPRITES)
    bne @f
    rts                     ; (no free entry)

; setup_sprite: X = entry, lo_u = z (source $3CDE)
SetupSprite:
    stx lo_x
    txa
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    stz arch_group,x
    stz arch_root,x
    stz grid_people,x
    stz grid_decor,x
    .ifndef LOCKSTEP
    .import SprForgetObject, SceneKeep, SceneInit
    jsr SprForgetObject
    .endif
    ldx lo_x
    LDEB OE_CONTROL
    ora #C_ENABLE
    STEB OE_CONTROL
    ; addr = seg_spr_addr + seg_spr_offset1
    lda seg_spr_offset1
    clc
    adc seg_spr_addr
    sta lo_a4
    lda seg_spr_addr+2
    adc #0
    sta lo_a4+2
    ; x world = READ8(+1) << 4 (trackloader read8 is int8_t: sign extended)
    ldy #1
    jsr A4Byte
    cmp #$0080
    bcc :+
    ora #$FF00
:   asl a
    asl a
    asl a
    asl a
    ldx lo_x
    STE OE_XW1
    STE OE_XW2
    ; y world = READ16(+2) << 7
    ldy #2
    jsr A4Word
    ldx #7
:   asl a
    dex
    bne :-
    ldx lo_x
    STE OE_YW
    ; type = READ8(+5) << 2, frame = rom0.read32(type table + type)
    ldy #5
    jsr A4Byte
    asl a
    asl a
    ldx lo_x
    STE OE_TYPE
    jsr TypeFrame
    .ifndef LOCKSTEP
    jsr KeepArch
    bcs @omit
    ldy #0
    jsr A4Byte              ; routine flags, before OE_FUNC has been filled
    ldx lo_x
    jsl $CF0000+SceneKeep
    bcc :+
@omit:
    ldx lo_x
    jmp LevelObjHideSprite
:
    .endif
    ; palette
    ldy #7
    jsr A4Byte
    ldx lo_x
    STE OE_PAL_SRC
    jsr MapPalette
    ldx lo_x
    lda #0
    STE OE_WIDTH
    STE OE_RELOAD
    lda lo_u
    STE OE_Z
    lda lo_u+2
    STE OE_Z+2
    ; flags from READ8(+0)
    ldy #0
    jsr A4Byte
    sta lo_t
    ldx lo_x
    LDEB OE_CONTROL
    and #$FFFF-C_HFLIP-C_SHADOW-C_WIDE_ROAD
    sta lo_t+2
    lda lo_t
    and #1
    beq :+
    lda lo_t+2
    ora #C_HFLIP
    sta lo_t+2
:   lda lo_t
    and #2
    beq :+
    lda lo_t+2
    ora #C_SHADOW
    sta lo_t+2
:   lda road_width+2        ; (int16)(road_width >> 16) > $118
    sec
    sbc #$0119
    bvc :+
    eor #$8000
:   bmi :+
    lda lo_t+2
    ora #C_WIDE_ROAD
    sta lo_t+2
:   lda lo_t+2
    STEB OE_CONTROL
    lda lo_t
    and #$00F0
    STEB OE_DRAW_PROPS
    lsr a
    lsr a
    lsr a
    lsr a
    STEB OE_FUNC
    ; fall into SetupSpriteRoutine

; setup_sprite_routine: X = entry
SetupSpriteRoutine:
    LDEB OE_FUNC
    asl a
    phx
    tax
    lda f:SsrTab,x
    plx
    sta lo_t
    jmp (lo_t)

; Gateway patterns are four records: two beam halves, then two pillars,
; spawned in reverse order. Cull whole groups, including their collisions.
; Some patterns end with unpaired pillars: omit these as well.
KeepArch:
    ldx lo_x
    LDE OE_TYPE
    cmp #47*4
    beq @arch
    cmp #48*4
    bne @keep
@arch:
    lda seg_spr_offset1
    and #31
    cmp #24
    bne :+
    inc arch_phase
:   lda arch_phase
    and #1
    cmp #1
    bne @drop
    lda seg_spr_offset1
    and #$FFE0
    clc
    adc seg_spr_addr
    sta lo_tab
    lda seg_spr_addr+2
    adc #0
    sta lo_tab+2
    lda lo_tab
    clc
    adc #5
    ldy lo_tab+2
    jsr R0Byte
    cmp #47
    bne @drop
    lda lo_tab
    clc
    adc #13
    ldy lo_tab+2
    jsr R0Byte
    cmp #47
    bne @drop
    lda lo_x
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    lda arch_phase
    sta arch_group,x
    lda seg_spr_offset1
    and #31
    cmp #24
    bne @keep
    lda #1
    sta arch_root,x
@keep:
    clc
    rts
@drop:
    sec
    rts

; A4Byte / A4Word: Y = offset -> byte / big endian word at lo_a4 + Y
A4Byte:
    tya
    clc
    adc lo_a4
    pha
    lda lo_a4+2
    adc #0
    tay
    pla
    jmp R0Byte
A4Word:
    tya
    clc
    adc lo_a4
    pha
    lda lo_a4+2
    adc #0
    tay
    pla
    jmp R0Word

; TypeFrame: X = entry, A = type -> addr = rom0.read32(SPRITE_TYPE_TABLE + A)
TypeFrame:
    clc
    adc #.loword(SPRITE_TYPE_TABLE)
    ldy #^SPRITE_TYPE_TABLE
    bcc :+
    iny
:   phx
    jsr R0Long
    stx lo_t
    plx
    STE OE_ADDR+2
    lda lo_t
    STE OE_ADDR
    rts

; the flip-dependent anchor helpers: A = value if HFLIP, Y = value if not
OrProps:
    sta lo_t
    LDEB OE_CONTROL
    and #C_HFLIP
    bne :+
    sty lo_t
:   LDEB OE_DRAW_PROPS
    ora lo_t
    STEB OE_DRAW_PROPS
    rts
SetShadow:
    STEB OE_SHADOW
    rts

Ssr0:                       ; normal sprite
    lda #7
    jsr SetShadow
    LDEB OE_DRAW_PROPS
    ora #8
    STEB OE_DRAW_PROPS
    rts
Ssr1:                       ; grass (1), stone strips (11)
    lda #7
    jsr SetShadow
    lda #2
    ldy #1
    jmp OrProps
Ssr2:                       ; overhead clouds
    lda #3
    jsr SetShadow
    lda #$A
    ldy #9
    jsr OrProps
    LDEB OE_DRAW_PROPS
    and #1
    beq :+
    lda #$FFE0
    bra :++
:   lda #$20
:   STE OE_RELOAD
    lda #0
    STE OE_XW2
    rts
Ssr3:                       ; water; sand (10, 14)
    lda #3
    jsr SetShadow
    lda #2
    ldy #1
    jmp OrProps
Ssr4:                       ; lights, checkpoints, no collision, wide rocks
    lda #7
    jsr SetShadow
    LDEB OE_DRAW_PROPS
    ora #8
    STEB OE_DRAW_PROPS
    rts
Ssr7:                       ; draw from top left, collision
    lda #7
    jsr SetShadow
    lda #9
    ldy #$A
    jmp OrProps
Ssr12:                      ; mini tree
    lda #7
    jsr SetShadow
    lda #$A
    ldy #9
    jmp OrProps
Ssr13:                      ; spray
    lda #3
    jmp SetShadow
SsrNone:
    rts

;============================================================================
; do_sprite_routine
;============================================================================
LevelObjDoSpriteRoutine:
    ; control bytes read 8-bit (C_ENABLE = bit 7), four entries per round;
    ; X = offset of the round's first entry, Y = offset within the round
    ldx #0
    sep #$20
    .a8
@l: lda f:JT+OE_CONTROL,x
    bpl @n0
    ldy #0
    jsr @one
@n0:
    lda f:JT+OE_CONTROL+OE_SIZE,x
    bpl @n1
    ldy #OE_SIZE
    jsr @one
@n1:
    lda f:JT+OE_CONTROL+OE_SIZE*2,x
    bpl @n2
    ldy #OE_SIZE*2
    jsr @one
@n2:
    cpx #EOFS(NO_SPRITES - 3)
    bcs @end                ; (NO_SPRITES = 4k + 3: the last round has 3)
    lda f:JT+OE_CONTROL+OE_SIZE*3,x
    bpl @n3
    ldy #OE_SIZE*3
    jsr @one
@n3:
    rep #$20
    .a16
    txa
    clc
    adc #OE_SIZE*4
    tax
    sep #$20
    .a8
    bra @l
@end:
    rep #$20
    .a16
    lda #NO_SPRITES
    sta lo_i                ; (as the index loop left it)
    rts
; @one: entry X + Y enabled (A8 in and out, X kept)
@one:
    rep #$20
    .a16
    phx
    tya
    clc
    adc 1,s
    tax
    stx lo_x
    LDEB OE_FUNC
    sta lo_fn
    cmp #15
    bcs :+
    asl a
    tax
    jsr (DsrJmp,x)          ; (the routines start with X = lo_x)
:   plx
    sep #$20
    .a8
    rts
    .a16
DsrJmp:
    .addr Dsr0, Dsr1, Dsr2, Dsr3, Dsr4, Dsr5, Dsr6, Dsr7, Dsr8, Dsr9
    .addr Dsr10, Dsr11, Dsr12, Dsr13, Dsr14

Dsr0:                       ; normal sprite (collision if yw == 0), zoom 1
    ldx lo_x
    LDE OE_YW
    bne :+
    lda #1
    jmp SpriteNormal
:   lda #1
    jmp SetSprZoomPriority
Dsr1:
    ldx lo_x
    jmp SpriteGrass
Dsr2:
    ldx lo_x
    jmp SpriteClouds
Dsr3:
    ldx lo_x
    jmp SpriteWater
Dsr4:
    ldx lo_x
    jmp SpriteLights
Dsr5:                       ; checkpoint bottom
    ldx lo_x
    lda #1
    jmp SetSprZoomPriority
Dsr6:                       ; checkpoint top: passed -> checkpoint marker
    ldx lo_x
    lda #1
    jsr SetSprZoomPriority
    ldx lo_x
    LDEB OE_CONTROL
    and #C_ENABLE
    bne :+
    lda #$FFFF
    sta checkpoint_marker
:   rts
Dsr7:
    ldx lo_x
    jmp SpriteCollisionZ1c
Dsr8:
    ldx lo_x
    lda #2
    jmp SpriteNormal
Dsr9:
    ldx lo_x
    jmp SpriteRocks
Dsr10:
Dsr14:
    ldx lo_x
    lda #.loword(SPRITE_SAND_FRAMES)
    jmp DoThicknessSprite
Dsr11:
    ldx lo_x
    lda #.loword(SPRITE_STONE_FRAMES)
    jmp DoThicknessSprite
Dsr12:
    ldx lo_x
    jmp SpriteMinitree
Dsr13:
    ldx lo_x
    jmp SpriteDebris

;----------------------------------------------------------------------------
; collision helpers
;----------------------------------------------------------------------------
; NoCollide: X = entry -> C set when the collision test is skipped
; (counter running or z >> 16 < $1B0)
NoCollide:
    lda sprite_collision_counter
    bne NcYes
NoCollideZ:
    LDE OE_Z+2              ; (z >> 16) < $1B0, signed int
    sec
    sbc #$01B0
    bvc :+
    eor #$8000
:   bmi NcYes
    clc
    rts
NcYes:
    sec
    rts

; XOffs: X = entry -> lo_x1, lo_x2 (collision x offsets, flipped for HFLIP)
XOffs:
    LDE OE_TYPE
    clc
    adc #.loword(SPRITE_X_OFFS)
    ldy #^SPRITE_X_OFFS
    phx
    jsr R0Set
    lda [rp0]
    xba
    sta lo_t
    ldy #2
    lda [rp0],y
    xba
    sta lo_t+2
    plx
    LDEB OE_CONTROL
    and #C_HFLIP
    beq :+
    lda lo_t                ; x2 = -first, x1 = -second
    eor #$FFFF
    inc a
    sta lo_x2
    lda lo_t+2
    eor #$FFFF
    inc a
    sta lo_x1
    rts
:   lda lo_t
    sta lo_x1
    lda lo_t+2
    sta lo_x2
    rts

; XHit: X = entry -> C set if (x + x1 <= 0 && x + x2 >= 0) (int arithmetic)
XHit:
    LDE OE_X
    clc
    adc lo_x1
    bvc :+
    eor #$8000
:   beq :+
    bpl @no                 ; x + x1 > 0
:   LDE OE_X
    clc
    adc lo_x2
    bvc :+
    eor #$8000
:   bmi @no                 ; x + x2 < 0
    sec
    rts
@no:
    clc
    rts

; Collided: collision with a level object
Collided:
    lda collision_sprite
    inc a
    and #$00FF
    sta collision_sprite
    lda #COLLISION_RESET
    sta sprite_collision_counter
    rts

;----------------------------------------------------------------------------
; sprite_normal: X = entry, A = zoom shift (source $4048)
;----------------------------------------------------------------------------
SpriteNormal:
    ; (NoCollide inline: X = entry is kept on the no-collision paths)
    ldy sprite_collision_counter
    bne @nc
    pha
    LDE OE_Z+2              ; (z >> 16) < $1B0, signed int
    sec
    sbc #$01B0
    bvc :+
    eor #$8000
:   bmi @nc1
    pla
    sta lo_zs
    jsr XOffs
    jsr XHit
    bcc @set
    jsr Collided
@set:
    ldx lo_x
    lda lo_zs
    jmp SetSprZoomPriority
@nc1:
    pla
@nc:
    jmp SetSprZoomPriority  ; (X = entry, A = zoom shift)

; sprite_lights (source $4658)
SpriteLights:
    jsr NoCollide
    bcs @cd
    jsr XOffs
    jsr XHit
    bcc @cd
    jsr Collided
@cd:
    ; countdown palette: game_state - 9 in 0..3
    ldx lo_x
    lda game_state
    sec
    sbc #9
    cmp #4
    bcs :+
    clc
    adc #$7A
    clc
    adc cur_stage
    and #$00FF
    STE OE_PAL_SRC
    jsr MapPalette
:   ldx lo_x
    lda #1
    jmp SetSprZoomPriority

;----------------------------------------------------------------------------
; set_spr_zoom_priority: X = entry, A = zoom shift (source $404A)
;----------------------------------------------------------------------------
SetSprZoomPriority:
    sta lo_zs
    ; MoveZ16
    lda #0
    jsr MoveSprite
    ldx lo_x
    LDE OE_Z+2
    sta lo_z16
    cmp #4
    bcc @rts
    cmp #$0200
    bcc @ok
    jmp LevelObjHideSprite
@rts:
    rts
@ok:
    ; SetPrioZoom
    STE OE_ROAD_PRIORITY
    STE OE_PRIORITY
    ldy lo_zs
:   lsr a
    dey
    bne :-
    STEB OE_ZOOM
    ; y = 223 - (road_y[p0 + z16] >> 4), minus (yw * z16) >> 16
    RDY223
    sta lo_t
    ldx lo_x
    LDE OE_YW
    beq :+
    ldx lo_z16
    jsr UMul16
    lda lo_t
    sec
    sbc mres+2
    sta lo_t
    ldx lo_x
:   lda lo_t
    STE OE_Y
    ; x = road0_h[z16] + (xw1 * z16) >> 9
    LDE OE_XW1
    bmi @mul
    sta lo_t
    lda lo_fn               ; (OE_FUNC, read by the dispatcher)
    cmp #4
    bcc @wide
    cmp #7
    bcc @add                ; routines 4-6: always the road width
@wide:
    LDEB OE_CONTROL
    and #C_WIDE_ROAD
    bne @mul0
@add:
    lda road_width+2
    asl a
    clc
    adc lo_t
    bra @mul
@mul0:
    lda lo_t
@mul:
    ; (XFromRoad and HEval for road 0, inline)
    sta MAL
    lda lo_z16
    sta MBL
    nop
    lda MR+3
    lsr a                   ; C = bit 24
    lda MR+1
    ror a                   ; >> 9
    sta lo_t
    lda lo_z16
    sta MAL                 ; i
    asl a
    tax
    lda rd_co
    beq @centred
    sta MBL                 ; i * car_offset
    lda f:RDB*$10000+RD_X,x
    cmp #MARK
    beq @mark
    eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta lo_h                ; (x >> 6) + $200
    lda MR+3
    lsr a                   ; C = bit 24
    lda MR+1
    ror a
    ldx rd_inv
    bne @inv
    clc
    adc lo_h
    sec
    sbc #$0200
    bra @hx
@inv:
    sec
    sbc lo_h
    clc
    adc #$0200
    bra @hx
@mark:
    lda rd_inv
    bne :+
    lda #MARK >> 6
    bra @hx
:   lda #.loword(0 - (MARK >> 6))
    bra @hx
@centred:
    lda f:RDB*$10000+RD_X,x
    ldx rd_inv
    beq :+
    eor #$FFFF
    inc a
:   eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sec
    sbc #$0200
@hx:
    clc
    adc lo_t
    ldx lo_x
    STE OE_X
    jmp DoSprOrderShadows

; MoveZ16: X = entry: move_sprite(0), lo_z16 = z >> 16; C set: done (z16 < 4
; nothing, >= $200 hidden)
MoveZ16:
    lda #0
    jsr MoveSprite
    ldx lo_x
    LDE OE_Z+2
    sta lo_z16
    cmp #4
    bcc @skip
    cmp #$0200
    bcc @ok
    jsr LevelObjHideSprite
@skip:
    sec
    rts
@ok:
    clc
    rts

; SetPrioZoom: road_priority = priority = z16, zoom = z16 >> lo_zs
SetPrioZoom:
    ldx lo_x
    lda lo_z16
    STE OE_ROAD_PRIORITY
    STE OE_PRIORITY
    ldy lo_zs
:   lsr a
    dey
    bne :-
    STEB OE_ZOOM
    rts

; XFromRoad: lo_t = xw1 (adjusted) -> A = road0_h[z16] + (xw1 * z16) >> 9
XFromRoad:
    lda lo_t
    sta MAL
    lda lo_z16
    sta MBL
    nop
    lda MR+3
    lsr a                   ; C = bit 24
    lda MR+1
    ror a                   ; >> 9
    sta lo_t
    lda lo_z16
    ldx #0
    jsr HEval               ; road0_h[z16]
    clc
    adc lo_t
    rts

; Asr4: A >> 4 (arithmetic)
Asr4:
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    rts

;----------------------------------------------------------------------------
; sprite_collision_z1c (source $4828) + set_spr_zoom_priority2
;----------------------------------------------------------------------------
SpriteCollisionZ1c:
    jsr NoCollide
    bcs @set
    jsr XOffs
    lda lo_x2               ; centre = (x2 - x1) >> 1
    sec
    sbc lo_x1
    cmp #$8000
    ror a
    sta lo_t
    lda lo_x1
    sec
    sbc lo_t
    sta lo_x1
    lda lo_x2
    sec
    sbc lo_t
    sta lo_x2
    jsr XHit
    bcc @set
    jsr Collided
@set:
    ldx lo_x
    lda #1
    sta lo_zs
    jsr MoveZ16
    bcc :+
    rts
:   jsr SetPrioZoom
    ldx lo_x
    LDE OE_XW1
    sta lo_t
    bmi :+
    LDEB OE_CONTROL
    and #C_WIDE_ROAD
    bne :+
    lda road_width+2
    asl a
    clc
    adc lo_t
    sta lo_t
:   jsr XFromRoad
    jsr XRange160
    bcc :+
    rts
:   ldx lo_x
    STE OE_X
    RDY223
    ldx lo_x
    STE OE_Y
    jmp DoSprOrderShadows

; XRange160: A = x -> C set if x > 160 or x < -160 (A kept)
XRange160:
    pha
    sec
    sbc #161
    bvc :+
    eor #$8000
:   bpl @out
    pla
    pha
    clc
    adc #160
    bvc :+
    eor #$8000
:   bmi @out
    pla
    clc
    rts
@out:
    pla
    sec
    rts
; XRange160b: C set if x >= 160 or x < -160
XRange160b:
    pha
    sec
    sbc #160
    bvc :+
    eor #$8000
:   bpl @out
    pla
    pha
    clc
    adc #160
    bvc :+
    eor #$8000
:   bmi @out
    pla
    clc
    rts
@out:
    pla
    sec
    rts

;----------------------------------------------------------------------------
; water / grass (spray triggers) -> thickness sprites
;----------------------------------------------------------------------------
; SprayTest: X = entry -> C set to start spray
SprayTest:
    lda spray_counter
    bne @no
    jsr NoCollideZ
    bcs @no
    LDEB OE_CONTROL
    and #C_HFLIP
    bne @fl
    LDE OE_X
    bmi @yes
    bra @no
@fl:
    LDE OE_X
    beq @no
    bmi @no
@yes:
    sec
    rts
@no:
    clc
    rts

SpriteWater:
    jsr SprayTest
    bcc :+
    lda #SPRAY_RESET
    sta spray_counter
    stz spray_type
:   ldx lo_x
    lda #.loword(SPRITE_WATER_FRAMES)
    jmp DoThicknessSprite

SpriteGrass:
    jsr SprayTest
    bcc :+
    lda #SPRAY_RESET
    sta spray_counter
    ldx lo_x
    LDE OE_PAL_SRC
    and #$00FF
    cmp #$49
    beq @y
    lda #8                  ; green
    bra @s
@y: lda #4                  ; yellow
@s: sta spray_type
:   ldx lo_x
    lda #.loword(SPRITE_GRASS_FRAMES)
    jmp DoThicknessSprite

;----------------------------------------------------------------------------
; do_thickness_sprite: X = entry, A = frame table (rom0, < $10000)
;----------------------------------------------------------------------------
DoThicknessSprite:
    sta lo_tab
    jsr MoveZ16
    bcc :+
    rts
:   ldx lo_x
    lda lo_z16
    STE OE_ROAD_PRIORITY
    STE OE_PRIORITY
    LDE OE_XW1
    sta lo_t
    bmi @mul
    LDEB OE_ID              ; (id 14: sand used by end sequence 2)
    cmp #14
    bne @add
    LDEB OE_CONTROL
    and #C_WIDE_ROAD
    bne @mul
@add:
    lda road_width+2
    asl a
    clc
    adc lo_t
    sta lo_t
@mul:
    jsr XFromRoad
    jsr XRange160b
    bcc :+
    rts
:   ldx lo_x
    STE OE_X
    RDY223
    ldx lo_x
    STE OE_Y
    ; thickness frame
    lda lo_z16
    lsr a
    cmp #$80
    bcc @custom
    STEB OE_ZOOM
    lda lo_tab
    clc
    adc #$3C
    bra @frame
@custom:
    lsr a
    and #$003C
    pha
    lda #$80
    STEB OE_ZOOM
    pla
    clc
    adc lo_tab
@frame:
    ldy #0
    phx
    jsr R0Long
    stx lo_t
    plx
    STE OE_ADDR+2
    lda lo_t
    STE OE_ADDR
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; sprite_minitree (source $428A)
;----------------------------------------------------------------------------
SpriteMinitree:
    jsr MoveZ16
    bcc :+
    rts
:   ldx lo_x
    lda lo_z16
    STE OE_ROAD_PRIORITY
    STE OE_PRIORITY
    LDE OE_XW1
    sta lo_t
    bmi :+
    lda road_width+2
    asl a
    clc
    adc lo_t
    sta lo_t
:   jsr XFromRoad
    jsr XRange160b
    bcc :+
    rts
:   ldx lo_x
    STE OE_X
    RDY223
    ldx lo_x
    STE OE_Y
    lda lo_z16
    lsr a
    cmp #$80
    bcc @tab
    STEB OE_ZOOM
    lda #.loword(SPRITE_MINITREE_FRAMES)
    bra @frame
@tab:
    asl a                   ; MAP_Y_TO_FRAME + z: frame offset, zoom
    clc
    adc #.loword(MAP_Y_TO_FRAME)
    ldy #^MAP_Y_TO_FRAME
    phx
    jsr R0Word
    plx
    pha
    and #$00FF
    STEB OE_ZOOM
    pla
    xba
    and #$00FF
    clc
    adc #.loword(SPRITE_MINITREE_FRAMES)
@frame:
    ldy #0
    phx
    jsr R0Long
    stx lo_t
    plx
    STE OE_ADDR+2
    lda lo_t
    STE OE_ADDR
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; sprite_debris (stage 3a): spray, zoom 2
;----------------------------------------------------------------------------
SpriteDebris:
    lda spray_counter
    bne @set
    jsr NoCollideZ
    bcs @set
    jsr XOffs
    jsr XHit
    bcc @set
    lda #SPRAY_RESET
    sta spray_counter
    lda #$C
    sta spray_type
@set:
    ldx lo_x
    lda #2
    jmp SetSprZoomPriority

;----------------------------------------------------------------------------
; sprite_clouds (stage 3, rightmost route; source $4144)
;----------------------------------------------------------------------------
SpriteClouds:
    lda #1
    jsr MoveSprite
    ldx lo_x
    LDE OE_Z+2
    sta lo_z16
    cmp #4
    bcs :+
    ldx #0
    jsr HEval               ; type = road0_h[z16]
    ldx lo_x
    STE OE_TYPE
    rts
:   cmp #$0200
    bcc :+
    jmp LevelObjHideSprite
:   STE OE_ROAD_PRIORITY
    STE OE_PRIORITY
    ; y = horizon_y2 - (z16 * horizon_y2) >> 9
    lda horizon_y2
    ldx lo_z16
    jsr SMul16
    sep #$20
    .a8
    lda mres+3
    lsr a
    rep #$20
    .a16
    lda mres+1
    ror a
    eor #$FFFF
    sec
    adc horizon_y2
    ldx lo_x
    STE OE_Y
    ; road_x = road0_h[z16]; d = road_x - old type; type = road_x
    LDE OE_TYPE
    sta lo_t+2              ; d1 = type
    lda lo_z16
    ldx #0
    jsr HEval
    ldx lo_x
    STE OE_TYPE
    sec
    sbc lo_t+2
    sta lo_t                ; road_x -= type (int16)
    lda lo_z16
    lsr a
    lsr a
    sta lo_u                ; type = z16 >> 2
    beq @xset
    lda lo_t
    clc
    ADCE OE_XW2
    bmi @neg
@pos:
    sec
    sbc lo_u
    bpl @pos
    clc
    adc lo_u
    bra @st
@neg:
    clc
    adc lo_u
    bmi @neg
    sec
    sbc lo_u
@st:
    STE OE_XW2
@xset:
    LDE OE_XW2
    clc
    ADCE OE_RELOAD
    STE OE_X
    lda #$CD
    STE OE_PAL_SRC
    lda lo_z16
    lsr a
    cmp #$80
    bcc @tab
    STEB OE_ZOOM
    lda #.loword(SPRITE_CLOUD_FRAMES)
    bra @frame
@tab:
    asl a
    clc
    adc #.loword(MOVEMENT_LOOKUP_Z)
    ldy #^MOVEMENT_LOOKUP_Z
    phx
    jsr R0Word
    plx
    pha
    and #$00FF
    STEB OE_ZOOM
    pla
    xba
    and #$00FF
    clc
    adc #.loword(SPRITE_CLOUD_FRAMES)
@frame:
    ldy #0
    phx
    jsr R0Long
    stx lo_t
    plx
    STE OE_ADDR+2
    lda lo_t
    STE OE_ADDR
    jsr MapPalette
    ldx lo_x
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; sprite_rocks (stage 2 right route; source $492A)
;----------------------------------------------------------------------------
SpriteRocks:
    jsr NoCollide
    bcs @set
    jsr XOffs
    jsr XHit
    bcc @set
    jsr Collided
@set:
    ldx lo_x
    lda #1
    sta lo_zs
    jsr MoveZ16
    bcc :+
    rts
:   jsr SetPrioZoom
    RDY223
    ldx lo_x
    STE OE_Y
    LDE OE_XW1
    sta lo_t
    bmi :+
    LDEB OE_CONTROL
    and #C_WIDE_ROAD
    bne :+
    lda road_width+2
    asl a
    clc
    adc lo_t
    sta lo_t
:   jsr XFromRoad
    ldx lo_x
    STE OE_X
    ; width = (width >> 1) + 160 (uint16): skip if x >= width || x + width < 0
    LDE OE_WIDTH
    lsr a
    clc
    adc #160
    sta lo_t
    LDE OE_X
    sec
    sbc lo_t                ; x >= width (int compare, width positive)
    bvc :+
    eor #$8000
:   bpl @r
    LDE OE_X
    clc
    adc lo_t
    bvc :+
    eor #$8000
:   bmi @r
    jmp DoSprOrderShadows
@r: rts

;============================================================================
; init_startline_sprites / init_hiscore_sprites (init_entries)
;============================================================================
LevelObjInitStartlineSprites:
    stz arch_phase
    .ifndef LOCKSTEP
    jsl $CF0000+SceneInit
    .endif
    lda game_state
    cmp #GS_MUSIC
    bne :+
    rts
:   lda #.loword(SPRITE_DEF_PROPS1)
    ldx #DEF_SPRITE_ENTRIES
    bra InitEntries
LevelObjInitHiscoreSprites:
    lda #.loword(SPRITE_DEF_PROPS2)
    ldx #HISCORE_SPRITE_ENTRIES

; InitEntries: A = a4 (rom0 < $10000), X = last entry index
InitEntries:
    sta lo_a4
    stz lo_a4+2
    stx lo_n
    ldx #254
:   stz arch_group,x
    stz arch_root,x
    stz grid_people,x
    stz grid_decor,x
    dex
    dex
    bpl :-
    stz lo_i
@e: lda lo_i
    xba
    lsr a
    lsr a
    sta lo_x
    ldy #0
    jsr A4Word
    ldx lo_x
    pha
    xba
    STEB OE_CONTROL
    pla
    STEB OE_DRAW_PROPS
    ldy #2
    jsr A4Word
    ldx lo_x
    pha
    xba
    STEB OE_SHADOW
    pla
    and #$00FF
    STE OE_PAL_SRC
    ldy #4
    jsr A4Word
    ldx lo_x
    STE OE_TYPE
    jsr TypeFrame
    ldy #6
    jsr A4Word
    ldx lo_x
    STE OE_XW1
    STE OE_XW2
    ldy #8
    jsr A4Word
    ldx lo_x
    STE OE_YW
    ldy #10
    jsr A4Word
    sta lo_z16              ; z_orig
    ldx lo_x
    STE OE_Z+2
    lda #0
    STE OE_Z
    ; x = road0_h[z_orig] + (xw1 * z_orig) >> 9  (the wide road add is a no-op)
    LDE OE_XW1
    sta lo_t
    jsr XFromRoad
    ldx lo_x
    STE OE_X
    lda lo_a4
    clc
    adc #16
    sta lo_a4
    ; routine by index
    lda lo_i
    ldy #0
    cmp #28
    bcc @fh
    ldy #7
    cmp #44
    bcc @fh
    ldy #8
    lda lo_n
    cmp #HISCORE_SPRITE_ENTRIES
    beq @fh
    lda lo_i
    ldy #4
    cmp #44
    beq @fh
    ldy #0
    cmp #48
    bcc @fh                 ; 45-47
    ldy #8
    cmp #68
    bcc @fh
    ldy #$FF                ; (unchanged: entries 68: routine from the entry)
    LDEB OE_FUNC
    tay
@fh:
    pha
    phx
    lda lo_n
    cmp #DEF_SPRITE_ENTRIES
    beq :+
    jmp @restore
:   lda lo_i
    cmp #44
    bcs @crowd
    asl a
    tax
    lda #2                  ; banner supports plus the roadside palm avenue
    sta grid_decor,x
    cpx #19*2               ; right support (the roadside trees are staggered)
    beq @palm
    cpx #20*2               ; left support
    beq @palm
    cpx #12*2
    beq @palm
    cpx #13*2
    beq @palm
    cpx #8*2
    beq @palm
    cpx #9*2
    beq @palm
    cpx #6*2
    beq @palm
    cpx #7*2
    bne :+
@palm:
    lda #1
    sta grid_decor,x
    bra :+
@crowd:
    cmp #48
    bcc :+
    cmp #68
    bcs :+
    asl a
    tax
    lda #2
    sta grid_people,x
    ; Fixed start-line cohort: do not add previously refused spectators
    ; halfway through the car's arrival as its side view frees OBJ lines.
    cpx #48*2
    beq @person
    cpx #58*2
    beq @person
    cpx #62*2
    beq @person
    cpx #67*2
    bne :+
@person:
    lda #1
    sta grid_people,x
:
@restore:
    plx
    pla
    tya
    ldx lo_x
    STEB OE_FUNC
    jsr MapPalette
    inc lo_i
    lda lo_i
    cmp lo_n
    beq :+
    bcc :+
    rts
:   jmp @e

.segment "RODATA"
SsrTab:
    .word Ssr0, Ssr1, Ssr2, Ssr3, Ssr4, Ssr4, Ssr4, Ssr7, Ssr4, Ssr4
    .word Ssr3, Ssr1, Ssr12, Ssr13, Ssr3, SsrNone
.endif
