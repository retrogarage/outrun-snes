; OTraffic: traffic cars - port of the original CannonBall engine
; (engine/otraffic.cpp, classic arcade): spawning on the horizon, lane
; changes and speed control between cars, collisions with the Ferrari,
; passing traffic sound (pan / volume of up to four cars).
;
; Classic configuration: new_attract = 0, bumper = 0, tick_fps = 30 (no
; z_adjust scaling), tick_frame always true, MODE_ORIGINAL (no time trial
; overtake counter / vehicle_cols), dip_traffic = 1, sound.advertise = 1.
; oentry* values (traffic_adr[], the current sprite) are entry byte offsets.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import DoSprOrderShadows, MapPalette, sprite_count, spr_cnt_shadow
.import sprite_order2: far
.import LevelObjHideSprite
.import R0Byte, R0Long, Random
.import SMul16, UMul16, SDiv32_16
.importzp mres, dvd
.import RoadYRaw, RoadXRaw, HEval, RD_Y, RD_UNK
.importzp RDB
.import SndQueueSound, SndSetEngineData, StatsUpdateScore
.import game_state, bonus_control, road_pos, road_width, road_p0, stage_lookup_off
.import car_increment, car_x_pos, road_remove_split, route_selected
.import skid_counter, car_inc_old

.export TrafficInit, TrafficInitStage1, TrafficTick, TrafficDisable
.export TrafficSetMax, TrafficLogic, TrafficSound
.export ai_traffic, bonus_lhs, traffic_split, collision_traffic, collision_mask
.export traffic_adr, max_traffic, traffic_speed_total, traffic_speed_avg
.export traffic_pal_cycle, traffic_count, spawn_counter, spawn_location
.export wheel_reset, wheel_counter

; function holders
TRAFFIC_INIT  = $10         ; initialise traffic object
TRAFFIC_ENTRY = $11         ; first $80 positions of the road
TRAFFIC_TICK  = $12         ; tick normally
SKID_RESET    = 20          ; OCrash::SKID_RESET
SKID_MAX      = 30          ; OCrash::SKID_MAX
DIP_TRAFFIC   = 1           ; config.engine.dip_traffic (classic)

; SEXT: A (int16) -> A = its sign extension ($0000 / $FFFF)
; ORDER_ENTRY: X = main sprite index -> X = entry offset (sprite_order2[X])
.macro ORDER_ENTRY
    lda f:sprite_order2-1,x ; (high byte: sprite_order2[X])
    and #$FF00
    lsr a
    lsr a
    tax
.endmacro

.macro SEXT
    .local pos
    and #$8000
    beq pos
    lda #$FFFF
pos:
.endmacro

.segment "IRAMBSS"          ; (hot: SA-1 I-RAM is twice as fast as BW-RAM)
ai_traffic:          .res 2 ; uint8: enemy traffic close to the car (AI)
bonus_lhs:           .res 2 ; uint8: go to the LHS of the road on bonus
traffic_split:       .res 2 ; int8: traffic logic on a road split
collision_traffic:   .res 2 ; uint16: 0 none, 1 init collision, 2 in progress
collision_mask:      .res 2 ; uint16
traffic_adr:         .res 9 * 2 ; oentry* traffic_adr[9] (on screen traffic)
max_traffic:         .res 2 ; uint8: maximum number of on screen enemies
traffic_speed_total: .res 2 ; int16
traffic_speed_avg:   .res 2 ; int16
traffic_pal_cycle:   .res 2 ; uint8: wheel palette 0 / 1
traffic_count:       .res 2 ; int16: number of traffic spawned
spawn_counter:       .res 2 ; int16
spawn_location:      .res 2 ; int16
wheel_reset:         .res 2 ; int16
wheel_counter:       .res 2 ; int16
; locals
tr_i:       .res 2          ; tick loop entry
tr_spr:     .res 2          ; oentry* sprite
tr_t:       .res 4
tr_u:       .res 4
tr_d:       .res 4          ; update_props: (car_increment >> 16) - traffic_speed
tr_p:       .res 4          ; z_adjust
tr_x:       .res 4          ; update_props x (int32)
tr_w:       .res 4          ; road_width >> 16 (int32)
tr_c:       .res 2          ; z >> 16
tr_z16:     .res 2
tr_inc:     .res 2          ; incline
tr_fr:      .res 2          ; traffic_frame
tr_rp:      .res 2          ; set_zoom_lookup road_priority
tr_d0:      .res 2          ; check_collision d0
tl_n:       .res 2          ; traffic_logic: number of main sprites
tl_idx:     .res 2          ; index / index2 (uint8)
tl_spawned: .res 2
tl_first:   .res 2
tl_next:    .res 2
ts_n:       .res 2          ; traffic_sound: sounds
ts_i:       .res 2
ts_v:       .res 2

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (otraffic.cpp 33)
;----------------------------------------------------------------------------
TrafficInit:
    stz ai_traffic
    stz bonus_lhs
    stz traffic_split
    stz collision_traffic
    stz collision_mask
    stz traffic_speed_total
    stz traffic_speed_avg
    stz traffic_pal_cycle
    stz traffic_count
    stz spawn_counter
    stz spawn_location
    lda #12                 ; wheel animation reset value
    sta wheel_reset
    sta wheel_counter
    rts

;----------------------------------------------------------------------------
; init_stage1_traffic (otraffic.cpp 52): traffic in the right hand lane
;----------------------------------------------------------------------------
TrafficInitStage1:
    ldx #EOFS(SPRITE_TRAFF1)
    jsr S1Car
    lda #$F520              ; z = $140F520
    STE OE_Z
    lda #$0140
    STE OE_Z+2
    lda #$0140              ; z = $14004E0
    sta tr_t
    ldx #EOFS(SPRITE_TRAFF1 + 1)
    lda #$0070
    ldy #$18
    jsr S1CarXZ
    ldx #EOFS(SPRITE_TRAFF1 + 2)
    lda #.loword(-$70)
    ldy #$20
    jsr S1CarXZ
    lda #$01D0              ; z = $1D004E0
    sta tr_t
    ldx #EOFS(SPRITE_TRAFF1 + 3)
    lda #$0070
    ldy #$28
    jsr S1CarXZ
    ldx #EOFS(SPRITE_TRAFF1 + 4)
    lda #.loword(-$70)
    ldy #$30
    ; fall through
; S1CarXZ: X = entry, A = xw1 = xw2, Y = type, z = tr_t : $04E0
S1CarXZ:
    pha
    jsr S1Car
    pla
    STE OE_XW1
    STE OE_XW2
    tya
    STE OE_TYPE
    lda #$04E0
    STE OE_Z
    lda tr_t
    STE OE_Z+2
    rts
; S1Car: X = entry: function_holder = TRAFFIC_INIT, control |= flags,
; draw_props |= BOTTOM (X, Y kept)
S1Car:
    lda #TRAFFIC_INIT
    STEB OE_FUNC
    LDEB OE_CONTROL
    ora #C_TRAFFIC_SPRITE | C_TRAFFIC_RHS | C_ENABLE
    STEB OE_CONTROL
    LDEB OE_DRAW_PROPS
    ora #DP_BOTTOM
    STEB OE_DRAW_PROPS
    rts

;----------------------------------------------------------------------------
; tick (otraffic.cpp 102): tick spawned traffic objects (source $521A)
;----------------------------------------------------------------------------
TrafficTick:
    jsr SpawnTraffic        ; (tick_frame)
    lda #EOFS(SPRITE_TRAFF1)
    sta tr_i
@loop:
    ldx tr_i
    LDEB OE_FUNC
    cmp #TRAFFIC_TICK
    beq @tickgo             ; (the other states re-read OE_FUNC below)
    cmp #TRAFFIC_INIT
    bne @entry
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    beq @start
    cmp #GS_ATTRACT
    beq @start
    lda #0
    STEB OE_TRAFFIC_PROXIMITY
    jsr MoveSpawnedSprite   ; skip collision code
    bra @next
@start:
    lda #$00D4
    STE OE_TRAFFIC_ORIG_SPEED
    lda #TRAFFIC_ENTRY
    STEB OE_FUNC
@entry:
    ; skip collision code in the first section of the level
    ldx tr_i
    LDEB OE_FUNC
    cmp #TRAFFIC_ENTRY
    bne @tick
    lda road_pos+2          ; road_pos >> 16 >= $80 (unsigned)
    cmp #$0080
    bcc @move
    lda #TRAFFIC_TICK
    STEB OE_FUNC
    bra @tick
@move:
    jsr MoveSpawnedSprite
@tick:
    ldx tr_i
    LDEB OE_FUNC
    cmp #TRAFFIC_TICK
    bne @next
@tickgo:
    jsr TickSpawnedSprite
@next:
    lda tr_i
    clc
    adc #OE_SIZE
    sta tr_i
    cmp #EOFS(SPRITE_TRAFF8 + 1)
    bcs :+
    jmp @loop
:   rts

;----------------------------------------------------------------------------
; disable_traffic (otraffic.cpp 140): (source $4A78)
;----------------------------------------------------------------------------
TrafficDisable:
    ldx #EOFS(SPRITE_TRAFF1)
:   LDEB OE_CONTROL
    and #$FF - C_ENABLE
    STEB OE_CONTROL
    txa
    clc
    adc #OE_SIZE
    tax
    cpx #EOFS(SPRITE_TRAFF8 + 1)
    bne :-
    rts

;----------------------------------------------------------------------------
; spawn_traffic (otraffic.cpp 152): wheel animation of the traffic, spawn
; when appropriate (source $4AC8)
;----------------------------------------------------------------------------
SpawnTraffic:
    lda bonus_control       ; (int8)
    and #$00FF
    bne @r0
    lda game_state
    and #$00FF
    cmp #GS_MAP
    beq @r0
    cmp #GS_MUSIC
    beq @r0
    cmp #GS_BEST2
    bne :+
@r0:
    rts
:   inc spawn_counter
    stz ai_traffic          ; clear AI traffic marker
    ; average traffic speed -> wheel animation counter reset value
    lda traffic_speed_avg
    beq @count
    cmp #$8000              ; wheel_reset = -((avg >> 5) - 11)
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    eor #$FFFF
    sec
    adc #11
    sta wheel_reset
    dec wheel_counter
    bne @half
    sta wheel_counter       ; = wheel_reset
    stz traffic_pal_cycle
    bra @count
@half:
    cmp #$8000              ; (wheel_reset >> 1) == wheel_counter
    ror a
    cmp wheel_counter
    bne @count
    lda #1
    sta traffic_pal_cycle
@count:
    ; check_traffic_count: traffic_count >= max_traffic (int compare)
    lda max_traffic
    and #$00FF
    sta tr_t
    lda traffic_count
    sec
    sbc tr_t
    bvc :+
    eor #$8000
:   bpl @ret
    ; use the counter as a spawning delay
    lda spawn_counter
    dec a
    eor spawn_counter
    and #$0020              ; BIT_5
    beq @ret
    ; spawn traffic in the first free slot
    ldx #EOFS(SPRITE_TRAFF1)
@find:
    LDEB OE_CONTROL
    and #C_ENABLE
    bne :+
    jmp SpawnCar
:   txa
    clc
    adc #OE_SIZE
    tax
    cpx #EOFS(SPRITE_TRAFF8 + 1)
    bne @find
@ret:
    rts

;----------------------------------------------------------------------------
; spawn_car (otraffic.cpp 201): X = entry; cars spawn on the horizon
; (source $4BAC)
;----------------------------------------------------------------------------
SpawnCar:
    stx tr_spr
    LDEB OE_CONTROL
    ora #C_ENABLE | C_TRAFFIC_SPRITE
    STEB OE_CONTROL
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    lda #7                  ; used as priority
    STEB OE_SHADOW
    lda #0
    STE OE_WIDTH
    STE OE_TRAFFIC_PROXIMITY ; traffic_proximity = traffic_fx = 0 (bytes 42-43)
    STE OE_Z
    lda #1                  ; z = $10000: starts on the horizon
    STE OE_Z+2
    jsr Random
    sta tr_t                ; int16 rnd
    inc spawn_location
    lda tr_t
    and #6                  ; TABLE[(rnd & 6) >> 1] (word tables)
    tax
    lda spawn_location
    and #1
    beq @rhs
    lda f:LhsLane,x         ; spawn on the left hand side of the road
    ldx tr_spr
    STE OE_XW2
    STE OE_XW1
    LDEB OE_CONTROL
    and #$FF - C_TRAFFIC_RHS
    ora #C_HFLIP
    bra @side
@rhs:
    lda f:RhsLane,x         ; spawn on the right hand side of the road
    ldx tr_spr
    STE OE_XW2
    STE OE_XW1
    LDEB OE_CONTROL
    ora #C_TRAFFIC_RHS
    and #$FF - C_HFLIP
@side:
    STEB OE_CONTROL
    lda tr_t                ; rnd = (int8) rnd
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   cmp #$8000              ; rnd >> 2
    ror a
    cmp #$8000
    ror a
    sta tr_t
    clc
    adc #200
    STE OE_TRAFFIC_ORIG_SPEED
    lda traffic_speed_avg
    STE OE_TRAFFIC_SPEED
    ; type of traffic: TYPE[(uint8)((rnd >> 2) + $20)] << 3
    lda tr_t
    clc
    adc #$20
    and #$00FF
    tax
    lda f:TrafficType,x
    and #$00FF              ; (int8 table, all entries positive)
    asl a
    asl a
    asl a
    ldx tr_spr
    STE OE_TYPE
    lda #TRAFFIC_TICK
    STEB OE_FUNC
    rts

;----------------------------------------------------------------------------
; tick_spawned_sprite (otraffic.cpp 260): X = entry (source $4DAA)
;----------------------------------------------------------------------------
TickSpawnedSprite:
    stx tr_spr
    ; force the side of the road in bonus mode, or on a road split
    lda bonus_lhs
    and #$00FF
    beq @split
    LDEB OE_CONTROL
    ora #C_TRAFFIC_RHS
    STEB OE_CONTROL
    bra @coll
@split:
    lda traffic_split
    and #$00FF
    beq @coll
    LDEB OE_CONTROL
    eor #C_TRAFFIC_RHS
    STEB OE_CONTROL
@coll:
    jsr CheckCollision      ; collision with the player's car
    ldx tr_spr
    LDE OE_Z+2              ; z >> 16 <= $100 (signed, rev. A value)
    sec
    sbc #$0101
    bvc :+
    eor #$8000
:   bmi @move
    ; x difference between the player's car and the traffic
    LDE OE_XW1
    clc
    adc car_x_pos
    sec
    sbc road_width+2
    sta tr_t                ; int16 x_diff
    bpl :+
    eor #$FFFF
    inc a
:   sec                     ; x_diff_abs >= $A0 (int16)
    sbc #$00A0
    bvc :+
    eor #$8000
:   bpl @move
    LDEB OE_TRAFFIC_PROXIMITY
    ldy tr_t
    bmi :+
    ora #2                  ; x_diff >= 0: BIT_1
    bra :++
:   ora #1                  ; BIT_0
:   sta tr_t+2
    ; (block added in rev. A)
    LDE OE_XW1
    cmp #$0070
    bne :+
    lda #1                  ; BIT_0
    bra :++
:   cmp #.loword(-$70)
    bne @prox
    lda #2                  ; BIT_1
:   ora tr_t+2
    sta tr_t+2
@prox:
    lda tr_t+2
    STEB OE_TRAFFIC_PROXIMITY
    ora ai_traffic          ; (new_attract = 0)
    and #$00FF
    sta ai_traffic
@move:
    ldx tr_spr
    ; fall into MoveSpawnedSprite

;----------------------------------------------------------------------------
; move_spawned_sprite (otraffic.cpp 328): X = entry (source $4E3E)
;----------------------------------------------------------------------------
MoveSpawnedSprite:
    stx tr_spr
    ; road splitting: return if the enemy is on the opposite side of the split
    lda road_remove_split   ; (int8)
    and #$00FF
    beq :+
    LDEB OE_CONTROL
    eor route_selected
    and #C_TRAFFIC_RHS
    bne :+
    rts
:   lda game_state
    and #$00FF
    cmp #GS_INGAME
    beq @plan
    cmp #GS_BONUS
    beq @plan
    cmp #GS_ATTRACT
    beq @plan
    jmp DoSprOrderShadows   ; X = entry
@plan:
    ; closeness bits -> lane movement plan (tick_frame)
    LDEB OE_TRAFFIC_PROXIMITY
    and #3
    beq @notclose
    eor #3                  ; 3 -> 0, 2 -> 1, 1 -> 2
    bne @side
    ; use_traffic_speed: hemmed in on left + right
    LDE OE_TRAFFIC_NEAR_SPEED
    sec
    sbc #$0070
    bvc :+
    eor #$8000
:   bpl :+
    lda #$0070              ; near speed < $70
    bra :++
:   LDE OE_TRAFFIC_NEAR_SPEED
:   STE OE_TRAFFIC_SPEED
    jmp UpdateProps
@side:
    and #1
    beq @left
    LDE OE_XW2              ; try_move_right: if (xw2 <= 0) xw2 += $70
    beq :+
    bpl @lane
:   clc
    adc #$0070
    STE OE_XW2
    bra @lane
@left:
    LDE OE_XW2              ; try moving left: if (xw2 >= 0) xw2 -= $70
    bmi @lane
    sec
    sbc #$0070
    STE OE_XW2
    bra @lane
@notclose:
    ; gradually restore the original speed (routine from $50BC)
    LDE OE_TRAFFIC_ORIG_SPEED
    sec
    SBCE OE_TRAFFIC_SPEED   ; int16 speed, capped to -2..2
    bmi @neg
    cmp #3
    bcc @add
    lda #2
    bra @add
@neg:
    cmp #.loword(-2)
    bcs @add
    lda #.loword(-2)
@add:
    clc
    ADCE OE_TRAFFIC_SPEED
    STE OE_TRAFFIC_SPEED
@lane:
    ; try_lane_change: int16 x_diff = xw2 - xw1
    LDE OE_XW2
    sec
    SBCE OE_XW1
    beq UpdateProps
    bmi @xneg
    LDEB OE_TRAFFIC_PROXIMITY
    and #1                  ; BIT_0 clear: xw1 += 4
    bne UpdateProps
    LDE OE_XW1
    clc
    adc #4
    STE OE_XW1
    bra UpdateProps
@xneg:
    LDEB OE_TRAFFIC_PROXIMITY
    and #2                  ; BIT_1 clear: xw1 -= 4
    bne UpdateProps
    LDE OE_XW1
    sec
    sbc #4
    STE OE_XW1
    ; fall into UpdateProps

;----------------------------------------------------------------------------
; update_props (otraffic.cpp 409): tr_spr = entry (source $4F0C)
;----------------------------------------------------------------------------
UpdateProps:
    ; z_adjust = (((car_increment >> 16) - traffic_speed) * (z >> 16)) << 5:
    ; uint32 arithmetic in the C++ -> 32-bit product modulo 2^32
    ldx tr_spr
    LDE OE_TRAFFIC_SPEED
    sta tr_u
    SEXT
    sta tr_u+2
    lda car_increment+2
    sec
    sbc tr_u
    sta tr_d
    lda #0
    sbc tr_u+2
    sta tr_d+2              ; d (32-bit)
    LDE OE_Z+2
    sta tr_c                ; c = z >> 16 (sign extended)
    ; fast path: d fits int16 and |c| < $400: z_adjust = d * (c << 5), one
    ; signed multiply (the exact product fits int32)
    tay
    clc
    adc #$0400
    cmp #$0800
    bcs @slow
    lda tr_d
    cmp #$8000              ; C = d.lo < 0
    lda tr_d+2
    adc #0                  ; 0 when d.hi is the sign extension of d.lo
    bne @slow
    tya
    asl a
    asl a
    asl a
    asl a
    asl a
    sta MAL
    lda tr_d
    sta MBL
    nop
    lda MR
    sta tr_p
    lda MR+2
    sta tr_p+2
    bra @zadd
@slow:
    ldx tr_c
    lda tr_d
    jsr UMul16              ; d.lo * c.lo
    lda mres
    sta tr_p
    lda mres+2
    sta tr_p+2
    lda tr_d+2              ; + (d.hi * c.lo) << 16
    beq @dlo
    ldx tr_c
    jsr SMul16
    lda tr_p+2
    clc
    adc mres
    sta tr_p+2
@dlo:
    lda tr_c                ; + (d.lo * c.hi) << 16, c.hi = $FFFF if c < 0
    bpl @shift
    lda tr_p+2
    sec
    sbc tr_d
    sta tr_p+2
@shift:
    ldy #5
:   asl tr_p
    rol tr_p+2
    dey
    bne :-
@zadd:
    ; (config.tick_fps == 30: no adjustment)
    ldx tr_spr
    LDE OE_Z
    clc
    adc tr_p
    STE OE_Z
    LDE OE_Z+2
    adc tr_p+2
    STE OE_Z+2
    sta tr_z16              ; int16 z16 (flags from the adc)
    beq @hide               ; z16 <= 0: disable traffic object
    bmi @hide
    cmp #$0200
    bcc @on
    ; overtake traffic object
    lda #S_RESET
    jsr SndQueueSound
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    bne @hide
    lda #$0000              ; update score on overtake: update_score($20000)
    ldx #$0002
    jsr StatsUpdateScore
@hide:
    ldx tr_spr
    jmp LevelObjHideSprite
@on:
    STE OE_PRIORITY         ; priority = road_priority = z16
    STE OE_ROAD_PRIORITY
    ; screen y = 223 - (road_y[road_p0 + z16] >> 4)
    asl a                   ; (0 < z16 < $200: C = 0)
    adc road_p0
    tax
    lda f:RDB * $10000 + RD_Y,x
    eor #$8000              ; y >> 4 (arithmetic) = ((y ^ $8000) >> 4) - $800
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #223 + $800
    ldx tr_spr
    STE OE_Y
    jsr SetZoomLookup
    ; screen x = ((xw1 * z16) >> 9) + (TRAFFIC_RHS ? road1_h : road0_h)[z16]
    ldx tr_spr
    LDE OE_XW1
    sta MAL
    lda tr_z16
    sta MBL
    nop
    lda MR+3
    lsr a                   ; carry = bit 24
    lda MR+1
    ror a                   ; >> 9 (low 16 bits)
    sta tr_t
    LDEB OE_CONTROL
    and #C_TRAFFIC_RHS
    beq :+
    lda #2
:   tax                     ; 0 = road 0, 2 = road 1
    lda tr_z16
    jsr HEval
    clc
    adc tr_t
    ldx tr_spr
    STE OE_X
    lda tr_z16
    cmp #9
    bcs @incline
    ldx tr_spr              ; z16 <= 8
    jsr MapPalette
    jmp AddSpeedShadows
@incline:
    ; change in road y -> incline frame: y = road_y[road_p0 - 8] - road_y[road_p0]
    ; (road_p0 = 0: the C++ reads road_y[-8] = road_unk[$1F8], the array
    ; just before road_y)
    ldx road_p0
    bne @p0
    lda f:RDB * $10000 + RD_UNK + $1F8 * 2
    bra @dy
@p0:
    lda f:RDB * $10000 + RD_Y - 16,x
@dy:
    sec
    sbc f:RDB * $10000 + RD_Y,x
    sec                     ; incline = (int16 y < $12) ? $10 : 0
    sbc #$0012
    bvc :+
    eor #$8000
:   bpl @flat
    lda #$10
    bra @inc
@flat:
    lda #0
@inc:
    sta tr_inc
    ; cap player x position (int32 until capped)
    ; x = car_x_pos - (road_width >> 16) [+ (road_width >> 16) << 1 on the RHS]
    lda road_width+2
    sta tr_w
    SEXT
    sta tr_w+2
    lda car_x_pos
    SEXT
    sta tr_x+2
    lda car_x_pos
    sec
    sbc tr_w
    sta tr_x
    lda tr_x+2
    sbc tr_w+2
    sta tr_x+2
    ldx tr_spr
    LDEB OE_CONTROL
    and #C_TRAFFIC_RHS
    beq @rdx
    asl tr_w
    rol tr_w+2
    lda tr_x
    clc
    adc tr_w
    sta tr_x
    lda tr_x+2
    adc tr_w+2
    sta tr_x+2
@rdx:
    ; x += road_x[z16] - road_x[z16 - 8]
    lda tr_z16
    sec
    sbc #8
    jsr RoadXRaw
    sta tr_t
    SEXT
    sta tr_t+2
    lda tr_z16
    jsr RoadXRaw
    sta tr_u
    SEXT
    sta tr_u+2
    lda tr_u
    sec
    sbc tr_t
    sta tr_u
    lda tr_u+2
    sbc tr_t+2
    sta tr_u+2
    lda tr_x
    clc
    adc tr_u
    sta tr_x
    lda tr_x+2
    adc tr_u+2
    sta tr_x+2              ; (flags from the adc)
    ; cap to -$190..$190 (only the low word is used afterwards)
    bmi @xneg
    bne @xmax
    lda tr_x
    cmp #$0191
    bcc @xok
@xmax:
    lda #$0190
    sta tr_x
    bra @xok
@xneg:
    cmp #$FFFF
    bne @xmin
    lda tr_x
    cmp #.loword(-$190)
    bcs @xok
@xmin:
    lda #.loword(-$190)
    sta tr_x
@xok:
    ; x = (x >> 2) + (xw1 >> 2)  (fits in 16 bits: |x| < $2100)
    lda tr_x
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta tr_x
    ldx tr_spr
    LDE OE_XW1
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    clc
    adc tr_x
    sta tr_x                ; (flags from the adc)
    ; traffic_frame from |x|
    bpl :+
    eor #$FFFF
    inc a
:   ldy #1
    cmp #$0010
    bcc :+
    iny
    cmp #$0030
    bcc :+
    iny
:   sty tr_fr
    ; horizontal flip from the position of the car in relation to the player
    LDEB OE_CONTROL
    ldy tr_x
    bmi :+
    ora #C_HFLIP
    bra :++
:   and #$FF - C_HFLIP
:   STEB OE_CONTROL
    ; palette, sprite data: traffic type, uphill / straight, x position
    ldy #4
    jsr PropByte
    clc
    adc traffic_pal_cycle   ; (uint16 pal_src)
    ldx tr_spr
    STE OE_PAL_SRC
    ldy #7
    jsr PropByte
    asl a
    asl a
    asl a
    asl a
    asl a
    sta tr_t
    lda tr_fr
    asl a
    asl a
    clc
    adc tr_t
    clc
    adc tr_inc              ; traffic_type
    ldy #^ADR_traffic_data
    clc
    adc #.loword(ADR_traffic_data)
    bcc :+
    iny
:   jsr R0Long              ; addr = rom0.read32(traffic_data + traffic_type)
    stx tr_t
    ldx tr_spr
    STE OE_ADDR+2
    lda tr_t
    STE OE_ADDR
    jsr MapPalette
AddSpeedShadows:
    ldx tr_spr
    LDE OE_TRAFFIC_SPEED
    clc
    adc traffic_speed_total
    sta traffic_speed_total
    jmp DoSprOrderShadows   ; X = entry

; PropByte: Y = field -> A = rom0.read8(traffic_props + type + Y) (tr_spr)
; traffic properties: +0 long sprite data, +4 palette, +5 collision mask,
; +6 zoom lookup value for width / height, +7 traffic type
PropByte:
    ldx tr_spr
    tya
    clc
    adc #.loword(ADR_traffic_props)
    ldy #^ADR_traffic_props
    clc
    ADCE OE_TYPE
    bcc :+
    iny
:   jmp R0Byte

;----------------------------------------------------------------------------
; set_zoom_lookup (otraffic.cpp 531): tr_spr = entry
;----------------------------------------------------------------------------
SetZoomLookup:
    ldx tr_spr
    LDE OE_ROAD_PRIORITY    ; (uint16) (road_priority >> 2) + 4, max $7F
    lsr a
    lsr a
    clc
    adc #4
    cmp #$0080
    bcc :+
    lda #$007F
:   sta tr_rp
    ldy #6
    jsr PropByte            ; zoom lookup
    cmp #0
    beq @z0
    cmp #2
    beq @z2
    cmp #4
    beq @z4
    cmp #6
    bne @set
    asl tr_rp               ; 6: road_priority += road_priority
    bra @set
@z0:
    lda tr_rp               ; 0: += road_priority >> 3
    lsr a
    lsr a
    lsr a
    bra @add
@z2:
    lda tr_rp               ; 2: += road_priority >> 2
    lsr a
    lsr a
    bra @add
@z4:
    lda tr_rp               ; 4: += road_priority >> 1
    lsr a
@add:
    clc
    adc tr_rp
    sta tr_rp
@set:
    lda tr_rp
    ldx tr_spr
    STEB OE_ZOOM            ; (uint8)
    rts

;----------------------------------------------------------------------------
; set_max_traffic (otraffic.cpp 584): by difficulty and stage (source $846E)
;----------------------------------------------------------------------------
TrafficSetMax:
    lda stage_lookup_off    ; int16 / 8 (truncated toward zero)
    bpl :+
    clc
    adc #7
:   cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    .ifndef LOCKSTEP
    .import race_diff
    pha
    lda race_diff
    dec a
    bpl :+
    lda #0
:   sta tr_rp
    asl a
    asl a
    clc
    adc tr_rp
    sta tr_rp
    pla
    clc
    adc tr_rp
    .else
    clc
    adc #DIP_TRAFFIC * 5
    .endif
    and #$00FF              ; uint8 index
    tax
    lda f:MaxTraffic,x
    and #$00FF
    sta max_traffic
    rts

;----------------------------------------------------------------------------
; traffic_logic (otraffic.cpp 627): traffic to traffic behaviour, closeness
; bits, average speed (source $7990).
; The C++ takes the jump index of main hardware sprite i from
; sprite_entries[spr_cnt_shadow + i].scratch, which do_sprite set this frame
; from sprite_order2[i] (osprites.s keeps no scratch): read sprite_order2.
;----------------------------------------------------------------------------
TrafficLogic:
    stz tl_spawned
    lda sprite_count
    sec
    sbc spr_cnt_shadow
    sta tl_n                ; (uint16) sprite_count
    bne :+
    lda #0
    jmp CalcAvgSpeed
    ; find the first traffic entry (Y = index: sprite_count < 256, so the
    ; uint8 index never wraps before the end)
:   ldy #0
@first:
    tyx
    ORDER_ENTRY
    LDE OE_CONTROL          ; (C_TRAFFIC_SPRITE is in the low byte)
    and #C_TRAFFIC_SPRITE
    bne @found
    iny
    cpy tl_n
    bcc @first
    sty tl_idx
    stx tl_first
    lda #0                  ; no traffic found
    jmp CalcAvgSpeed
@found:
    sty tl_idx
    stx tl_first
    txa
    sta traffic_adr
    lda #1
    sta tl_spawned
    ; compare the current traffic entry with the previous one
@next:
    ldy tl_idx
    ldx tl_next
@nl:
    iny                     ; (uint8 index2)
    cpy tl_n
    bcc :+
    sty tl_idx
    stx tl_next
    lda tl_spawned
    jmp CalcAvgSpeed
:   tyx
    ORDER_ENTRY
    LDE OE_CONTROL
    and #C_TRAFFIC_SPRITE
    beq @nl
    sty tl_idx
    stx tl_next
    lda tl_spawned          ; traffic_adr[spawned++] = next
    asl a
    tay
    txa
    sta traffic_adr,y
    inc tl_spawned
    lda #0
    STEB OE_TRAFFIC_PROXIMITY
    ldx tl_first
    LDE OE_Z+2              ; (uint16) z16 = first->z >> 16
    cmp #$0040
    bcs :+
    jmp @adv
:   sta tr_t
    lsr a
    sta tr_t+2
    lsr a
    clc
    adc tr_t+2
    clc
    adc tr_t
    sta tr_t                ; z16 += (z16 >> 1) + (z16 >> 2) (uint16)
    ldx tl_next
    LDE OE_Z+2              ; z16 <= next->z >> 16 (int compare, z16 >= 0)
    bmi @close
    cmp tr_t
    bcc @close
    jmp @adv
@close:
    LDEB OE_TRAFFIC_PROXIMITY
    ora #4                  ; BIT_2: entry 2 close to other traffic (z axis)
    STEB OE_TRAFFIC_PROXIMITY
    ldx tl_first
    LDE OE_XW1
    ldx tl_next
    sec
    SBCE OE_XW1
    sta tr_t                ; int16 x_diff = first->xw1 - next->xw1
    bpl :+
    eor #$FFFF
    inc a
:   sec                     ; x_diff_abs - $80 >= 0 (int)
    sbc #$0080
    bvc :+
    eor #$8000
:   bpl @adv
    lda tr_t
    bmi @lhs
    lda #2                  ; entry 1: traffic on the RHS
    ldy #1                  ; entry 2: traffic on the LHS
    bra @bits
@lhs:
    lda #1                  ; entry 1: traffic on the LHS
    ldy #2                  ; entry 2: traffic on the RHS
@bits:
    sta tr_t
    sty tr_t+2
    ldx tl_first
    LDEB OE_TRAFFIC_PROXIMITY
    ora tr_t
    STEB OE_TRAFFIC_PROXIMITY
    ldx tl_next
    LDEB OE_TRAFFIC_PROXIMITY
    ora tr_t+2
    STEB OE_TRAFFIC_PROXIMITY
    ; copy the car speed into entry 2 to avoid collision
    ldx tl_first
    LDE OE_TRAFFIC_SPEED
    ldx tl_next
    STE OE_TRAFFIC_NEAR_SPEED
@adv:
    lda tl_next             ; first = next
    sta tl_first
    jmp @next

; OrderEntry: X = main sprite index -> X = entry offset (sprite_order2[X])
OrderEntry:
    lda f:sprite_order2,x
    and #$00FF
    xba
    lsr a
    lsr a
    tax
    rts

;----------------------------------------------------------------------------
; calculate_avg_speed (otraffic.cpp 722): A = count (source $7A6A)
;----------------------------------------------------------------------------
CalcAvgSpeed:
    sta traffic_count
    cmp #0
    beq :+
    lda traffic_speed_total ; int16 / int16, truncated toward zero
    sta dvd
    SEXT
    sta dvd+2
    lda traffic_count
    jsr SDiv32_16
    lda dvd
    sta traffic_speed_avg
:   stz traffic_speed_total
    rts

;----------------------------------------------------------------------------
; check_collision (otraffic.cpp 738): tr_spr = entry: collision with the
; player's car, skid counter, Ferrari speed (source $50DE)
;----------------------------------------------------------------------------
CheckCollision:
    stz tr_d0
    ldx tr_spr
    LDE OE_Z+2              ; z >> 16 >= $1D8 (signed)
    sec
    sbc #$01D8
    bvc :+
    eor #$8000
:   bpl :+
    jmp @sound
:   LDE OE_WIDTH            ; w = (width >> 1) + (width >> 3) + (width >> 4)
    lsr a
    sta tr_t
    lsr a
    lsr a
    sta tr_t+2
    lsr a
    clc
    adc tr_t+2
    clc
    adc tr_t
    sta tr_t                ; int16 w
    ; traffic directly in front of the player's car: int16 x1 < 0 && x2 > 0
    LDE OE_X
    sec
    sbc tr_t
    bpl @sound              ; x1 = x - w >= 0
    LDE OE_X
    clc
    adc tr_t
    beq @sound              ; x2 = x + w <= 0
    bmi @sound
    ; collision settings from the property table
    ldy #5
    jsr PropByte
    sta collision_mask
    ldx tr_spr
    LDE OE_X
    bmi :+
    lda #SKID_RESET
    bra :++
:   lda #.loword(-SKID_RESET)
:   clc                     ; (bumper = 0)
    adc skid_counter
    sta tr_d0               ; int16 d0
    sec                     ; d0 <= SKID_MAX && d0 >= -SKID_MAX: skid counter
    sbc #SKID_MAX + 1
    bvc :+
    eor #$8000
:   bpl @speed
    lda tr_d0
    sec
    sbc #.loword(-SKID_MAX)
    bvc :+
    eor #$8000
:   bmi @speed
    lda tr_d0
    sta skid_counter
@speed:
    ; Ferrari speed from the collision speed
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq :+
    cmp #GS_INGAME
    bne @sound
:   ldx tr_spr
    LDE OE_TRAFFIC_SPEED    ; int16 traffic_speed - 80, at least 0
    sec
    sbc #80
    bpl :+
    lda #0
:   sta car_increment+2     ; car_increment = speed << 16 | (car_increment & $FFFF)
    sta car_inc_old
    lda #S_REBOUND          ; rebound sound effect
    sta tr_d0
    inc collision_traffic   ; (ttrial.vehicle_cols: not classic)
@sound:
    ; try_sound
    ldx tr_spr
    LDEB OE_TRAFFIC_FX
    sta tr_t                ; traffic_fx_old
    lda tr_d0
    and #$00FF
    sta tr_t+2
    STEB OE_TRAFFIC_FX
    lda tr_t
    bne @ret
    lda tr_t+2
    beq @ret
    jsr SndQueueSound       ; new sound effect triggered
    jsr Random
    and #1
    beq @ret
    ldx tr_spr
    lda #$FF                ; set all proximity bits on
    STEB OE_TRAFFIC_PROXIMITY
@ret:
    rts

;----------------------------------------------------------------------------
; traffic_sound (otraffic.cpp 796): up to four cars passing (source $7A8C)
;----------------------------------------------------------------------------
TrafficSound:
    ldx #S_TRAFFIC1
    lda #0
    jsr SndSetEngineData
    ldx #S_TRAFFIC2
    lda #0
    jsr SndSetEngineData
    ldx #S_TRAFFIC3
    lda #0
    jsr SndSetEngineData
    ldx #S_TRAFFIC4
    lda #0
    jsr SndSetEngineData
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    beq :+
    cmp #GS_ATTRACT         ; (sound.advertise = 1)
    bne @r0
:   lda traffic_count
    bne :+
@r0:
    rts
:   sec                     ; sounds = traffic_count <= 4 ? traffic_count : 4
    sbc #5
    bvc :+
    eor #$8000
:   bmi :+
    lda #4
    bra :++
:   lda traffic_count
:   sta ts_n
    stz ts_i
@loop:
    lda ts_i                ; i < sounds (int16)
    sec
    sbc ts_n
    bvc :+
    eor #$8000
:   bpl @ret
    lda traffic_count       ; t = traffic_adr[traffic_count - i - 1]
    clc
    sbc ts_i
    asl a
    tax
    lda traffic_adr,x
    tax
    LDE OE_X                ; pan = x >> 5, capped to -3..3, & 7
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
    bmi @pneg
    cmp #4
    bcc @pan
    lda #3
    bra @pan
@pneg:
    cmp #.loword(-3)
    bcs @pan
    lda #.loword(-3)
@pan:
    and #7
    sta ts_v
    LDE OE_ROAD_PRIORITY    ; volume from the position into the screen
    and #$01F0
    lsr a
    ora ts_v
    sta ts_v
    lda ts_i
    clc
    adc #S_TRAFFIC1
    tax
    lda ts_v
    jsr SndSetEngineData
    inc ts_i
    bra @loop
@ret:
    rts

.segment "RODATA"
; spawn_car lane tables (int8, sign extended)
LhsLane: .word 0, .loword(-$70), .loword(-$70), $70
RhsLane: .word 0, .loword(-$70), $70, $70
; spawn_car traffic types (int8 TYPE[])
TrafficType:
    .include "asset_TrafficType.inc"
; set_max_traffic: maximum traffic per stage (S1-S5) and difficulty
MaxTraffic:
    .byte 2, 2, 3, 4, 5     ; easy
    .byte 3, 4, 5, 6, 7     ; normal
    .byte 4, 5, 6, 7, 8     ; hard
    .byte 5, 6, 7, 8, 8     ; very hard
.endif
