; OMap: end of game course map - port of the original CannonBall
; engine/omap.cpp (classic).  The map is 61 sprite pieces (jump table
; entries 0-$3C, loaded from rom0 SPRITE_COURSEMAP); the route driven is
; highlighted piece by piece while the mini car (entry 25) moves over it.
; blit() (omap.cpp 150) only runs when frame skipping: omitted.
; position_ferrari() (omap.cpp 203) is only used by time trial: omitted.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import FC_ClearPaletteData, FC_DisableSprites, FC_DoSprOrderShadows, FC_FillTilemapColor, FC_MapPalette, FC_OutrunInitBestOutrunners, FC_R0Byte, FC_R0Long, FC_R0Set, FC_R0Word, FC_SDiv32_16, FC_SMul16, FC_TrafficDisable, FC_VidClearTextRam   ; (farbank.py)
.import scn_page
.import DoSprOrderShadows, MapPalette, DisableSprites, ClearPaletteData
.import spr_cnt_main, spr_cnt_shadow
.import TrafficDisable, FillTilemapColor, OutrunInitBestOutrunners
.import VidClearTextRam
.import car_ctrl_active, car_inc_old, car_increment, rd_split_state
.import road_ctrl, horizon_base, road_pos
.import routes, cur_stage
.import R0Set, R0Byte, R0Word, R0Long, SMul16, SDiv32_16
.importzp rp0, mres, dvd

.export MapInit, MapTick

MAP_PIECES      = $3C       ; sprite pieces of the course map (0-$3C)
MAP_SPR_FERRARI = 25        ; omap.cpp SPRITE_FERRARI: the mini car entry
; map_state
MAP_INIT        = $00
MAP_ROUTE       = $04
MAP_ROUTE_FINAL = $08
MAP_ROUTE_DONE  = $0C
MAP_INIT_DELAY  = $10
MAP_DISPLAY     = $14
MAP_CLEAR       = $18
ROAD_BOTH_P0    = 3         ; ORoad::ROAD_BOTH_P0
HORIZON_OFF     = -$3FF     ; ORoad::HORIZON_OFF
REC_SIZE        = 20        ; SPRITE_COURSEMAP record size (+4 unused bytes)

.segment "BSS"
init_sprites:   .res 2      ; bool
map_state:      .res 2      ; uint8
map_route:      .res 2      ; uint8
map_pos:        .res 2      ; int16
map_pos_final:  .res 2      ; int16
map_delay:      .res 2      ; int16
map_stage1:     .res 2      ; int16
map_stage2:     .res 2      ; int16
minicar_enable: .res 2      ; uint8
mp_i:           .res 2
mp_n:           .res 2
mp_e:           .res 2      ; entry offset
mp_b:           .res 2      ; backdrop entry offset
mp_adr:         .res 4      ; rom0 address (32-bit)
mp_t:           .res 4
mp_u:           .res 4
mp_yc:          .res 2      ; y_change

.segment "SA1CODE2"
.a16
.i16

;============================================================================
; init (omap.cpp 35)
;============================================================================
MapInit:
    sep #$20
    .a8
    stz car_ctrl_active         ; oferrari.car_ctrl_active = false
    rep #$20
    .a16
    jsl $C10000+FC_VidClearTextRam   
    jsl $C10000+FC_DisableSprites   
    jsl $C10000+FC_TrafficDisable   
    jsl $C10000+FC_ClearPaletteData   
    stz car_increment           ; (uint32)
    stz car_increment+2
    stz car_inc_old
    stz spr_cnt_main
    stz spr_cnt_shadow
    lda #ROAD_BOTH_P0
    sta road_ctrl
    lda #.loword(HORIZON_OFF)
    sta horizon_base
    lda #$0ABD                  ; paint pinkish colour on tilemap 16
    jsl $C10000+FC_FillTilemapColor   
    lda #2                      ; SNES: the course map page (the fill and the
    sta scn_page                ; backdrop pieces 26-60, tools/mkpages2.py)
    lda #1
    sta init_sprites
    rts

;============================================================================
; tick (omap.cpp 55, source $345E): route through the levels, end position
;============================================================================
MapTick:
    lda init_sprites
    beq @state
    jsr LoadSprites             ; initialise the course map sprites
    stz init_sprites
    rts
@state:
    lda map_state
    cmp #MAP_INIT
    beq @init
    cmp #MAP_ROUTE
    beq @route
    cmp #MAP_ROUTE_FINAL
    beq @final
    cmp #MAP_ROUTE_DONE
    beq @done
    cmp #MAP_INIT_DELAY
    beq @delay
    cmp #MAP_DISPLAY
    beq @display
    cmp #MAP_CLEAR
    beq @clear
    jmp DrawCourseMap
@clear:
    jsl $C10000+FC_OutrunInitBestOutrunners   ; (return: no draw)
    rts
@final:
    jsr DoRouteFinal
    jmp DrawCourseMap
@done:
    jsr EndRoute
    jmp DrawCourseMap
@delay:
    jsr InitMapDelay
    jmp DrawCourseMap
@display:
    jsr MapDisplay
    jmp DrawCourseMap

@init:
    ; video.sprite_layer->set_x_clip(false): widescreen only, omitted
    lda f:routes+2              ; routes[1]
    ldx #0
    jsr RouteRead
    sta map_route
    stz map_pos
    stz map_stage1
    lda cur_stage               ; map_stage2 = cur_stage (int8)
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
    sta map_stage2
    beq @tofinal
    bmi @tofinal
    lda #MAP_ROUTE              ; map_stage2 > 0
    sta map_state
    bra @route                  ; (fall through to MAP_ROUTE)
@tofinal:
    lda #MAP_ROUTE_FINAL
    sta map_state
    jsr DoRouteFinal
    jmp DrawCourseMap

@route:
    inc map_pos                 ; ++map_pos > 0x1B (int16)
    lda map_pos
    sec
    sbc #$1C
    bvc :+
    eor #$8000
:   bpl :+
    jmp DrawCourseMap
:   dec map_stage2              ; --map_stage2 <= 0
    beq @endroute
    bmi @endroute
    stz map_pos
    inc map_stage1
    lda map_stage1              ; map_route = read8(MAP_ROUTE_LOOKUP +
    inc a                       ;   routes[1 + map_stage1])
    asl a
    tax
    lda f:routes,x
    ldx #0
    jsr RouteRead
    sta map_route
    jmp DrawCourseMap
@endroute:                      ; map_end_route
    stz map_pos
    inc map_stage1
    lda map_stage1
    inc a
    asl a
    tax
    lda f:routes,x              ; route_info = routes[1 + map_stage1]
    beq @last
    ldx #0
    jsr RouteRead               ; read8(MAP_ROUTE_LOOKUP + route_info)
    bra @setr
@last:
    lda map_stage1
    asl a
    tax
    lda f:routes,x
    ldx #$10
    jsr RouteRead               ; read8(MAP_ROUTE_LOOKUP + routes[map_stage1] + 0x10)
@setr:
    sta map_route
    lda #MAP_ROUTE_FINAL
    sta map_state
    jsr DoRouteFinal
    jmp DrawCourseMap

; RouteRead: A = route value (uint16), X = extra -> A = rom0.read8(
; MAP_ROUTE_LOOKUP + A + X) (32-bit address)
RouteRead:
    stx mp_t
    ldy #.hiword(MAP_ROUTE_LOOKUP)
    clc
    adc #.loword(MAP_ROUTE_LOOKUP)
    bcc :+
    iny
:   clc
    adc mp_t
    bcc :+
    iny
:   jsl $C10000+FC_R0Byte
    rts

;============================================================================
; draw_course_map (omap.cpp 160)
;============================================================================
DrawCourseMap:
    ; road components: entries 0-19 alternate bottom / top
    stz mp_i
@vert:
    lda mp_i
    xba
    lsr a
    lsr a
    tax
    lda mp_i
    and #1
    bne :+
    jsr DrawVertBottom
    bra :++
:   jsr DrawVertTop
:   inc mp_i
    lda mp_i
    cmp #20
    bcc @vert
    ; entries 20-24: horizontal ends
@horiz:
    lda mp_i
    xba
    lsr a
    lsr a
    tax
    jsr DrawHorizEnd
    inc mp_i
    lda mp_i
    cmp #25
    bcc @horiz
    ; mini car
    ldx #EOFS(MAP_SPR_FERRARI)
    jsr MoveMiniCar
    ; backdrop map pieces: 35 iterations from entry 26; the entry pointer
    ; only advances past enabled entries
    lda #EOFS(26)
    sta mp_b
    lda #MAP_PIECES - 26 + 1
    sta mp_n
@bd:
    ldx mp_b
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @nx
    jsl $C10000+FC_DoSprOrderShadows   
    lda mp_b
    clc
    adc #OE_SIZE
    sta mp_b
@nx:
    dec mp_n
    bne @bd
    rts

;============================================================================
; load_sprites (omap.cpp 215, source $33F4): course map sprites
;============================================================================
LoadSprites:
    lda #.loword(ADR_sprite_coursemap)
    sta mp_adr
    lda #.hiword(ADR_sprite_coursemap)
    sta mp_adr+2
    stz mp_i
@l:
    lda mp_i
    xba
    lsr a
    lsr a
    tax
    stx mp_e
    lda mp_i
    inc a
    STEB OE_ID                  ; id = i + 1
    lda mp_adr
    ldy mp_adr+2
    jsl $C10000+FC_R0Set   ; rp0 -> the record
    ldx mp_e
    lda [rp0]
    STEB OE_CONTROL             ; +0
    xba
    STEB OE_DRAW_PROPS          ; +1
    ldy #2
    lda [rp0],y
    STEB OE_SHADOW              ; +2
    xba
    STEB OE_ZOOM                ; +3
    ldy #4
    lda [rp0],y
    xba
    and #$00FF
    STE OE_PAL_SRC              ; (uint8) read16
    ldy #6
    lda [rp0],y
    xba
    STE OE_PRIORITY
    STE OE_ROAD_PRIORITY
    ldy #8
    lda [rp0],y
    xba
    STE OE_X
    ldy #10
    lda [rp0],y
    xba
    STE OE_Y
    lda mp_adr                  ; addr = read32 (+12; may cross a bank)
    clc
    adc #12
    pha
    lda mp_adr+2
    adc #0
    tay
    pla
    jsl $C10000+FC_R0Long   
    stx mp_t
    ldx mp_e
    STE OE_ADDR+2
    lda mp_t
    STE OE_ADDR
    lda #0
    STE OE_COUNTER
    lda mp_adr                  ; adr += 16 + 4 (throw the last long away)
    clc
    adc #REC_SIZE
    sta mp_adr
    lda mp_adr+2
    adc #0
    sta mp_adr+2
    jsl $C10000+FC_MapPalette   
    inc mp_i
    lda mp_i
    cmp #MAP_PIECES + 1
    bcs :+
    jmp @l
:   ; wide-screen sea hack (s16_x_off != 0 || fix_bugs): omitted (classic)
    stz minicar_enable
    lda #$FF80                  ; -0x80 (EOFS() must end an expression)
    sta f:JT+MAP_SPR_FERRARI*OE_SIZE+OE_X
    lda #$78
    sta f:JT+MAP_SPR_FERRARI*OE_SIZE+OE_Y
    lda #MAP_INIT
    sta map_state
    rts

;============================================================================
; do_route_final (omap.cpp 270, source $355A)
;============================================================================
DoRouteFinal:
    lda road_pos+2              ; pos = (int16)(road_pos >> 16)
    ldx rd_split_state
    beq :+
    clc
    adc #$079C                  ; pos += 0x79C
:   ldx #$1B
    jsl $C10000+FC_SMul16   ; pos * 0x1B (int)
    lda mres
    sta dvd
    lda mres+2
    sta dvd+2
    lda #$094D
    jsl $C10000+FC_SDiv32_16   ; / 0x94D (truncating)
    lda dvd
    sta map_pos_final           ; (int16)
    lda #MAP_ROUTE_DONE
    sta map_state
    ; fall into EndRoute

;============================================================================
; end_route (omap.cpp 284, source $3584)
;============================================================================
EndRoute:
    inc map_pos
    lda map_pos_final           ; map_pos_final < map_pos (int16)
    sec
    sbc map_pos
    bvc :+
    eor #$8000
:   bmi :+
    rts
:   lda map_pos_final
    sta map_pos
    lda #1
    sta minicar_enable
    lda #MAP_INIT_DELAY
    sta map_state
    ; fall into InitMapDelay

;============================================================================
; init_map_delay (omap.cpp 299, source $35B6)
;============================================================================
InitMapDelay:
    stz map_route
    lda #$80
    sta map_delay
    lda #MAP_DISPLAY
    sta map_state
    ; fall into MapDisplay

;============================================================================
; map_display (omap.cpp 308, source $35CC)
;============================================================================
MapDisplay:
    dec map_delay               ; --map_delay <= 0
    beq :+
    bmi :+
    rts
:   lda #MAP_CLEAR
    sta map_state
    jsl $C10000+FC_OutrunInitBestOutrunners
    rts

;============================================================================
; colour the sprite road as the car moves over it
;============================================================================
; draw_vert_top (omap.cpp 323, source $3740): X = entry
DrawVertTop:
    lda #.loword(ADR_sprite_coursemap_top)
    ldy #.hiword(ADR_sprite_coursemap_top)
    bra DrawIfEnabled

; draw_vert_bottom (omap.cpp 330, source $3736): X = entry
DrawVertBottom:
    lda #.loword(ADR_sprite_coursemap_bot)
    ldy #.hiword(ADR_sprite_coursemap_bot)
    bra DrawIfEnabled

; draw_horiz_end (omap.cpp 337, source $372C): X = entry
DrawHorizEnd:
    lda #.loword(ADR_sprite_coursemap_end)
    ldy #.hiword(ADR_sprite_coursemap_end)
DrawIfEnabled:
    sta mp_adr
    sty mp_adr+2
    LDEB OE_CONTROL
    and #C_ENABLE
    bne DrawPiece
    rts

; draw_piece (omap.cpp 344, source $3746): X = entry, mp_adr = adr
DrawPiece:
    stx mp_e
    LDEB OE_ID
    cmp map_route               ; map_route == sprite->id
    bne @draw
    lda #$102
    STE OE_PRIORITY
    STE OE_ROAD_PRIORITY
    ; adr += map_pos << 3 (int)
    lda map_pos
    sta mp_t
    and #$8000
    beq :+
    lda #$FFFF
:   sta mp_t+2
    asl mp_t
    rol mp_t+2
    asl mp_t
    rol mp_t+2
    asl mp_t
    rol mp_t+2
    lda mp_adr
    clc
    adc mp_t
    sta mp_adr
    lda mp_adr+2
    adc mp_t+2
    sta mp_adr+2
    lda mp_adr
    ldy mp_adr+2
    jsl $C10000+FC_R0Long   ; addr = read32(adr)
    stx mp_t
    ldx mp_e
    STE OE_ADDR+2
    lda mp_t
    STE OE_ADDR
    lda mp_adr                  ; pal_src = read8(4 + adr)
    clc
    adc #4
    ldy mp_adr+2
    bcc :+
    iny
:   jsl $C10000+FC_R0Byte   
    ldx mp_e
    STE OE_PAL_SRC
    jsl $C10000+FC_MapPalette   
@draw:
    ldx mp_e
    jsl $C10000+FC_DoSprOrderShadows
    rts

;============================================================================
; move_mini_car (omap.cpp 364, source $3696): X = entry
;============================================================================
MoveMiniCar:
    stx mp_e
    lda minicar_enable
    beq :+
    jmp @draw
:   ; movement table: bit 0 of map_route = down (right route)
    lda map_route
    and #1
    beq :+
    lda #.loword(MAP_MOVEMENT_RIGHT)
    ldy #.hiword(MAP_MOVEMENT_RIGHT)
    bra :++
:   lda #.loword(MAP_MOVEMENT_LEFT)
    ldy #.hiword(MAP_MOVEMENT_LEFT)
:   sta mp_adr
    sty mp_adr+2
    ; pos = (map_stage1 < 4) ? map_pos : map_pos >> 1; pos <<= 1 (int16)
    lda map_stage1
    sec
    sbc #4
    bvc :+
    eor #$8000
:   bmi @lt4
    lda map_pos
    cmp #$8000
    ror a
    bra :+
@lt4:
    lda map_pos
:   asl a
    sta mp_t
    lda #0
    jsr MvRead
    ldx mp_e
    clc
    ADCE OE_X
    STE OE_X                    ; x += read16(movement_table + pos)
    lda #$40
    jsr MvRead
    sta mp_yc                   ; y_change = (int16) read16(... + 0x40)
    ldx mp_e
    LDE OE_Y
    sec
    sbc mp_yc
    STE OE_Y                    ; y -= y_change
    lda mp_yc
    beq @right
    bmi @down
    lda #.loword(ADR_sprite_minicar_up)
    STE OE_ADDR
    lda #.hiword(ADR_sprite_minicar_up)
    STE OE_ADDR+2
    bra @draw
@right:
    lda #.loword(ADR_sprite_minicar_right)
    STE OE_ADDR
    lda #.hiword(ADR_sprite_minicar_right)
    STE OE_ADDR+2
    bra @draw
@down:
    lda #.loword(ADR_sprite_minicar_down)
    STE OE_ADDR
    lda #.hiword(ADR_sprite_minicar_down)
    STE OE_ADDR+2
@draw:
    ldx mp_e
    jsl $C10000+FC_DoSprOrderShadows
    rts

; MvRead: A = extra -> A = rom0.read16(mp_adr + (int) mp_t + extra)
MvRead:
    sta mp_u
    stz mp_u+2
    lda mp_t
    bpl :+
    dec mp_u+2                  ; sign extension of pos
:   clc
    adc mp_u
    sta mp_u
    lda mp_u+2
    adc #0
    sta mp_u+2
    lda mp_u
    clc
    adc mp_adr
    pha
    lda mp_u+2
    adc mp_adr+2
    tay
    pla
    jsl $C10000+FC_R0Word
    rts
.endif
