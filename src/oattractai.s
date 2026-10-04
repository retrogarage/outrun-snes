; OAttractAI: attract mode autopilot and end of game bonus steering - port
; of the original CannonBall engine/oattractai.cpp (classic arcade: the
; original AI tick_ai; tick_ai_enhanced is a CannonBall enhancement, omitted).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import car_increment, car_x_pos, rd_split_state, route_selected
.import road_type, road_type_next, road_curve_next, road_width, cur_stage
.import sprite_ai_counter, sprite_ai_curve, sprite_ai_x, sprite_ai_steer
.import sprite_car_x_bak, wheel_state
.import steering_adjust, acc_adjust, brake_adjust, ai_traffic

.export AiInit, AiTick, AiCheckRoadBonus, AiSetSteeringBonus, last_stage

AI_NOCHANGE = 0             ; OInitEngine road types
AI_STRAIGHT = 1
AI_RIGHT    = 2
AI_LEFT     = 3
AI_BRAKE2   = $A0           ; OInputs::BRAKE_THRESHOLD2
AI_BRAKE3   = $C0           ; OInputs::BRAKE_THRESHOLD3
AI_STEER    = $B4           ; check_road STEER

.segment "BSS"
last_stage: .res 2          ; int8 (used by tick_ai_enhanced only)
ai_carx:    .res 2          ; set_steering car_x (d4)
ai_x:       .res 2          ; x (d3)
ai_xc:      .res 2          ; x_change (d2)
ai_d:       .res 2          ; car_x_diff (d1)
ai_s:       .res 2          ; steering (d0)
ai_c:       .res 2          ; Clamp7F

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (oattractai.cpp 60)
;----------------------------------------------------------------------------
AiInit:
    lda #$FFFF
    sta last_stage
    rts

;----------------------------------------------------------------------------
; tick_ai (oattractai.cpp 173): attract mode AI (source $A084)
;----------------------------------------------------------------------------
AiTick:
    jsr AiCheckRoad         ; upcoming road segment, route at a road split
    jsr AiSetSteering       ; steering from the upcoming road segment
    stz brake_adjust
    lda car_increment+2     ; below a certain speed just accelerate
    cmp #$00FA
    bcs :+
    lda #$00FF
    sta acc_adjust
    rts
:   lda ai_traffic          ; AI traffic close: brake on
    and #$00FF
    beq :+
    stz ai_traffic
    lda #AI_BRAKE3
    sta brake_adjust
    bra @curve
:   lda wheel_state         ; a wheel off-road: brake on
    and #$00FF
    beq @curve
    lda #AI_BRAKE3
    sta brake_adjust
@curve:
    lda road_curve_next
    bne :+
    stz sprite_ai_counter   ; upcoming road straight: clear AI curve counter
    bra @acc
:   inc sprite_ai_counter   ; upcoming road curved
    lda sprite_ai_counter
    cmp #1
    bne @toggle
    lda #$0096              ; curve value from the road data (int16)
    sec
    sbc road_curve_next
    bmi @acc
    sta sprite_ai_curve
    bra @acc
@toggle:
    ; curve: toggle the brake (the brake flickers in attract mode)
    lda sprite_ai_curve
    beq @acc
    sec                     ; sprite_ai_curve <= $A (int16)
    sbc #$000B
    bvc :+
    eor #$8000
:   bmi @brake
    lda sprite_ai_curve
    and #$0008              ; BIT_3
    beq @dec
@brake:
    lda #AI_BRAKE2
    sta brake_adjust
@dec:
    dec sprite_ai_curve
@acc:
    lda #$00FF              ; accelerator to max value
    sta acc_adjust
    rts

;----------------------------------------------------------------------------
; check_road (oattractai.cpp 240): upcoming road segment straight / curve,
; road split (source $A318)
;----------------------------------------------------------------------------
AiCheckRoad:
    lda road_type_next      ; road_type_next <= ROAD_STRAIGHT (int16)
    sec
    sbc #AI_STRAIGHT + 1
    bvc :+
    eor #$8000
:   bpl @curve
    lda road_type_next
    cmp #AI_STRAIGHT
    bne @nochange
    lda road_type           ; straight
    cmp #AI_RIGHT
    beq @pos
    bra @neg
@nochange:
    lda road_type
    cmp #AI_LEFT
    beq @pos
    cmp #AI_RIGHT
    beq @neg
    stz sprite_ai_x
    rts
@curve:
    lda road_type_next
    cmp #AI_LEFT
    beq @pos
@neg:
    lda #.loword(-AI_STEER)
    bra @set
@pos:
    lda #AI_STEER
@set:
    sta sprite_ai_x
    ; road split: 0 < rd_split_state < 4 (uint16)
    lda rd_split_state
    beq @ret
    cmp #4
    bcs @ret
    lda cur_stage           ; (int8) route information: 0 left, 1 right
    and #$00FF
    tax
    lda f:RouteInfo,x
    and #$00FF
    beq @ret
    lda sprite_ai_x
    eor #$FFFF
    inc a
    sta sprite_ai_x
@ret:
    rts

;----------------------------------------------------------------------------
; set_steering (oattractai.cpp 292): steering from the road split and the
; curve information (source $A3C2)
;----------------------------------------------------------------------------
AiSetSteering:
    lda rd_split_state      ; mid road split (uint16 >= 4)
    cmp #4
    bcc @nosplit
    lda route_selected      ; (int8) 0: right route
    and #$00FF
    bne :+
    lda car_x_pos
    clc
    adc road_width+2
    bra :++
:   lda car_x_pos
    sec
    sbc road_width+2
:   sta ai_carx
    bra @xc
@nosplit:
    lda car_x_pos
    sta ai_carx
@xc:
    lda sprite_ai_x         ; $A404: x = x_change = sprite_ai_x - car_x
    sec
    sbc ai_carx
    sta ai_x
    bpl :+
    eor #$FFFF
    inc a
:   sta ai_xc               ; int16 |x_change|, capped at 6
    sec
    sbc #7
    bvc :+
    eor #$8000
:   bmi :+
    lda #6
    sta ai_xc
:   lda ai_x
    bmi @lhs
    ; $A414: RHS of road
    lda ai_carx
    sec
    sbc sprite_car_x_bak
    sta ai_d                ; car_x_diff
    ora ai_xc
    beq @keep
    lda ai_d
    sec                     ; car_x_diff < 1
    sbc #1
    bvc :+
    eor #$8000
:   bmi @minus
    lda ai_d
    cmp #1
    beq @keep
    bra @plus               ; car_x_diff > 1
@lhs:
    ; $A43A: LHS of road
    lda sprite_car_x_bak
    sec
    sbc ai_carx
    sta ai_d
    ora ai_xc
    beq @keep
    lda ai_d
    sec                     ; car_x_diff < 1
    sbc #1
    bvc :+
    eor #$8000
:   bmi @plus
    lda ai_d
    cmp #1
    beq @keep
@minus:
    lda #.loword(-1)
    bra @steer
@plus:
    lda #1
@steer:
    ; $A462: steering = steering * (x_change + 1) + sprite_ai_steer (int16)
    sta ai_s
    lda ai_xc
    inc a
    ldy ai_s
    bpl :+
    eor #$FFFF
    inc a
:   clc
    adc sprite_ai_steer
    jsr Clamp7F
    sta sprite_ai_steer
    sta steering_adjust
    lda ai_carx
    sta sprite_car_x_bak
    rts
@keep:
    ; set_steering
    lda ai_carx
    sta sprite_car_x_bak
    lda sprite_ai_steer
    sta steering_adjust
    rts

; Clamp7F: A (int16) -> A capped to -$7F..$7F
Clamp7F:
    sta ai_c
    sec
    sbc #$0080
    bvc :+
    eor #$8000
:   bmi :+
    lda #$007F
    rts
:   lda ai_c
    sec
    sbc #.loword(-$7F)
    bvc :+
    eor #$8000
:   bpl :+
    lda #.loword(-$7F)
    rts
:   lda ai_c
    rts

;----------------------------------------------------------------------------
; check_road_bonus (oattractai.cpp 401): bonus mode x steering adjustment
; from the upcoming road segment (source $A498)
;----------------------------------------------------------------------------
AiCheckRoadBonus:
    lda road_type_next      ; road_type_next <= ROAD_STRAIGHT (int16)
    sec
    sbc #AI_STRAIGHT + 1
    bvc :+
    eor #$8000
:   bpl @curve
    lda road_type_next
    cmp #AI_STRAIGHT
    bne @nochange
    lda road_type           ; straight (different from check_road)
    cmp #AI_RIGHT
    beq @neg
    bra @pos
@nochange:
    lda road_type
    cmp #AI_LEFT
    beq @pos
    cmp #AI_RIGHT
    beq @neg
    stz sprite_ai_x
    rts
@curve:
    lda road_type_next
    cmp #AI_LEFT
    beq @pos
@neg:
    lda #.loword(-$B4)
    sta sprite_ai_x
    rts
@pos:
    lda #$00B4
    sta sprite_ai_x
    rts

;----------------------------------------------------------------------------
; set_steering_bonus (oattractai.cpp 430): steering set by check_road_bonus
; (source $A510)
;----------------------------------------------------------------------------
AiSetSteeringBonus:
    lda car_x_pos
    sta ai_s                ; steering (d4)
    lda rd_split_state      ; road split during bonus mode (uint16 >= $14)
    cmp #$0014
    bcc @check
    lda route_selected      ; (int8) 0: right route
    and #$00FF
    bne :+
    lda ai_s
    clc
    adc road_width+2
    sta ai_s
    bra @check
:   lda ai_s
    sec
    sbc road_width+2
    sta ai_s
@check:
    lda sprite_ai_x         ; steering = sprite_ai_x - steering
    sec
    sbc ai_s
    beq @ret
    eor #$FFFF              ; steering = -steering, capped to -$7F..$7F
    inc a
    jsr Clamp7F
    sta steering_adjust
@ret:
    rts

.segment "RODATA"
; check_road ROUTE_INFO: route per stage at the road split (0 left, 1 right)
RouteInfo:
.ifdef AP_ROUTE                 ; (debug autopilot builds: bit n = fork n right)
    .byte AP_ROUTE & 1, (AP_ROUTE >> 1) & 1, (AP_ROUTE >> 2) & 1, (AP_ROUTE >> 3) & 1, 0
.else
    .byte 0, 1, 1, 0, 0
.endif
.endif
