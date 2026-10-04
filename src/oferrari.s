; OFerrari: the player car - port of the original CannonBall engine
; (engine/oferrari.cpp, classic arcade): engine revs / torque / gears and the
; speed model, steering and road bounds, wheels on/off road, skid and slip,
; the Ferrari / passenger / shadow sprite entries, engine pitch, slip and
; safety zone sounds, speed score.
;
; spr_ferrari / spr_pass1 / spr_pass2 / spr_shadow hold the entry offsets
; EOFS(SPRITE_FERRARI / PASS1 / PASS2 / SHADOW), set by FerInit; the C++
; pointers never change afterwards, so the code addresses these entries with
; the constants FER / PS1 / PS2 / SHD.
; 1-byte members are words here (uint8/bool zero-extended, int8
; sign-extended).  1-byte variables of other modules are read masked
; (and #$FF) and written with 8-bit stores.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import MapPalette, DoSprOrderShadows
.import AnimFerrariSeq, AnimSeqIntro, AnimTickEndSeq
.import anim_ferrari, anim_pass1, anim_pass2
.import AiCheckRoadBonus, AiSetSteeringBonus, AiTick
.import HudDrawRevCounter
.import StatsConvertSpeedScore, cur_stage, time_counter
.import SndQueueSound, SndSetEngineData
.import Random, R0Word
.import SMul16, UMul16, SDiv32_16, UDiv32_16, SDiv16u
.importzp mres, dvd, dvs
.import RoadYRaw, RoadXRaw
.import road_pos, road_width, road_ctrl, car_x_bak, road_width_bak, road_pos_change
.import car_increment, car_x_pos, car_x_old, ingame_engine, ingame_counter
.import rd_split_state, road_curve, road_type
.import acc_adjust, brake_adjust, steering_adjust, gear
.import coll_count1, coll_count2, crash_state, crash_counter, skid_counter
.import spin_control1, spin_control2
.import collision_sprite, spray_counter
.import bonus_control, game_state

.export FerInit, FerResetCar, FerTick, FerInitIngame, FerSetX, FerSetBounds
.export FerCheckWheels, FerSetCurveAdjust, FerDrawShadow, FerMove
.export FerDoSoundScoreSlip, FerShake, FerDoSkid
.export spr_ferrari, spr_pass1, spr_pass2, spr_shadow, ferrari_pal, fer_state
.export car_ctrl_active, car_state, auto_brake, revs, wheel_state, is_slipping
.export car_inc_old, car_x_diff, rev_stop_flag, revs_post_stop
.export rev_pitch1, rev_pitch2, sprite_ai_counter, sprite_ai_curve
.export sprite_ai_x, sprite_ai_steer, sprite_car_x_bak

FER = EOFS(SPRITE_FERRARI)
PS1 = EOFS(SPRITE_PASS1)
PS2 = EOFS(SPRITE_PASS2)
SHD = EOFS(SPRITE_SHADOW)
R0B0 = R0BANK * $10000          ; rom0 $00000-$0FFFF (index = arcade address)

; state
FERRARI_SEQ1    = 0
FERRARI_SEQ2    = 1
FERRARI_INIT    = 2
FERRARI_LOGIC   = 3
FERRARI_END_SEQ = 4
; car_state
CAR_NORMAL = 0
CAR_SMOKE  = 1
; wheel_state
WHEELS_ON        = 0
WHEELS_LEFT_OFF  = 1
WHEELS_RIGHT_OFF = 2
WHEELS_OFF       = 3
; wheel_traction
TRACTION_ON  = 0
TRACTION_OFF = 2
PAL_RED        = 2
MAX_SPEED      = $1260000
CAR_BASE_INC   = $12F
OFFROAD_BOUNDS = $1F4
BRAKE_DEC      = -$8800         ; set_brake_subtract: DEC
; obonus.bonus_control
BONUS_DISABLE = $00
BONUS_INIT    = $04
BONUS_TICK    = $08
BONUS_SEQ0    = $0C
BONUS_SEQ1    = $10
BONUS_SEQ2    = $14
BONUS_SEQ3    = $18
BONUS_END     = $1C
; OInputs
BRAKE_THRESHOLD1 = $80
BRAKE_THRESHOLD2 = $A0
BRAKE_THRESHOLD3 = $C0
BRAKE_THRESHOLD4 = $E0
; OCrash
SKID_X_ADJ = 24
; oroad.road_ctrl
ROAD_BOTH_P0  = 3
ROAD_R0_SPLIT = 7
ROAD_R1_SPLIT = 8
; oinitengine.road_type
ROAD_STRAIGHT = 1
ROAD_RIGHT    = 2
ROAD_LEFT     = 3

; SCMP op: signed compare of A (16-bit, destroyed) with op:
; N = (A < op), Z = (A == op) (no label: keeps the @ scopes)
.macro SCMP op
    sec
    sbc op
    bvc *+5                 ; skip the eor (3 bytes)
    eor #$8000
.endmacro
; STB8 v: 8-bit store of A (a 1-byte variable of another module)
.macro STB8 v
    sep #$20
    sta v
    rep #$20
.endmacro
; ASR16: A >>= 1 (arithmetic)
.macro ASR16
    cmp #$8000
    ror a
.endmacro
; NEG16: A = -A
.macro NEG16
    eor #$FFFF
    inc a
.endmacro

.segment "BSS"
; ---- public members ----
spr_ferrari:        .res 2      ; oentry* (entry offsets)
spr_pass1:          .res 2
spr_pass2:          .res 2
spr_shadow:         .res 2
ferrari_pal:        .res 2      ; uint16
fer_state:          .res 2      ; uint8 state
counter:            .res 2      ; uint16 (unused counter)
steering_old:       .res 2      ; int16
car_ctrl_active:    .res 2      ; bool
car_state:          .res 2      ; int8
auto_brake:         .res 2      ; bool
torque_index:       .res 2      ; uint8
torque:             .res 2      ; int16
revs:               .res 4      ; int32
rev_shift:          .res 2      ; uint8
wheel_state:        .res 2      ; uint8
wheel_traction:     .res 2      ; uint8
is_slipping:        .res 2      ; uint16
slip_sound:         .res 2      ; uint8
car_inc_old:        .res 2      ; uint16
car_x_diff:         .res 2      ; int16
rev_stop_flag:      .res 2      ; int16
revs_post_stop:     .res 2      ; int16
acc_post_stop:      .res 2      ; int16
rev_pitch1:         .res 2      ; uint16
rev_pitch2:         .res 2      ; uint16
sprite_ai_counter:  .res 2      ; int16
sprite_ai_curve:    .res 2      ; int16
sprite_ai_x:        .res 2      ; int16
sprite_ai_steer:    .res 2      ; int16
sprite_car_x_bak:   .res 2      ; int16
sprite_wheel_state: .res 2      ; int16
sprite_slip_copy:   .res 2      ; int16
wheel_pal:          .res 2      ; int8
sprite_pass_y:      .res 2      ; int16
wheel_frame_reset:  .res 2      ; int16
wheel_counter:      .res 2      ; int16
; ---- private members ----
road_width_old:     .res 2      ; int16
accel_value:        .res 2      ; int16
accel_value_bak:    .res 2      ; int16
brake_value:        .res 2      ; int16
gear_value:         .res 2      ; bool
gear_bak:           .res 2      ; bool
acc_adjust1:        .res 2      ; int16
acc_adjust2:        .res 2
acc_adjust3:        .res 2
brake_adjust1:      .res 2      ; int16
brake_adjust2:      .res 2
brake_adjust3:      .res 2
brake_subtract:     .res 4      ; int32
gear_counter:       .res 2      ; int8
rev_adjust:         .res 4      ; int32
gear_smoke:         .res 2      ; int16
gfx_smoke:          .res 2      ; int16
cornering:          .res 2      ; int8
cornering_old:      .res 2      ; int8
; ---- locals ----
fd2:        .res 4      ; move(): d2 (int32&)
fd1:        .res 2      ; move(): d1 (int16&)
fnt:        .res 2      ; move(): new_torque
fadj:       .res 4      ; move(): rev_adjust_new (int32 results)
mv_diff:    .res 2
mv_adj:     .res 2
sf_d4:      .res 2      ; setup_ferrari_sprite
sf_xoff:    .res 2
sf_t:       .res 2
sf_inc:     .res 2
sf_fr:      .res 2
iy_t:       .res 2      ; InclineY
pl_pal:     .res 2      ; set_ferrari_palette
sx_st:      .res 2      ; set_ferrari_x: steering
sx_rc:      .res 2
sx_t:       .res 2
sb_rw:      .res 2      ; set_ferrari_bounds
sb_d1:      .res 2
cw_rw:      .res 2      ; check_wheels
cw_x:       .res 2
cw_ctrl:    .res 2
ca_t:       .res 2      ; set_curve_adjust
ca_x:       .res 2
sd_n:       .res 2      ; SDivT16
ps_spr:     .res 2      ; set_passenger_sprite
ps_frame:   .res 2
ps_off:     .res 4
pf_spr:     .res 2      ; set_passenger_frame
pf_addr:    .res 2
pf_inc:     .res 2
pf_t:       .res 2
te_lk:      .res 2      ; tick_engine_disabled
ab_acc1:    .res 2      ; car_acc_brake
ab_acc2:    .res 2
ab_t:       .res 2
tg_rem:     .res 2      ; tick_gear_change
rd_s:       .res 4      ; RevAdjustDecay
gi_nt:      .res 2      ; get_speed_inc_value
gi_ra:      .res 2
cr_top:     .res 2      ; convert_revs_speed
cr_d4:      .res 2
cr_d5:      .res 2
ur_ci:      .res 4      ; update_road_pos
ur_x:       .res 4
ur_t:       .res 2
ur_r:       .res 4
ss_pitch:   .res 2      ; do_sound_score_slip
ss_corn:    .res 2
sh_tr:      .res 2      ; shake
sh_rnd:     .res 2
sh_ci:      .res 2

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (oferrari.cpp 52): osprites.s calls it with no arguments, the four
; entries are always SPRITE_FERRARI, SPRITE_PASS1, SPRITE_PASS2, SPRITE_SHADOW
;----------------------------------------------------------------------------
FerInit:
    lda #FER
    sta spr_ferrari
    lda #PS1
    sta spr_pass1
    lda #PS2
    sta spr_pass2
    lda #SHD
    sta spr_shadow
    sep #$20
    .a8
    lda f:JT+FER+OE_CONTROL
    ora #C_ENABLE
    sta f:JT+FER+OE_CONTROL
    lda f:JT+PS1+OE_CONTROL
    ora #C_ENABLE
    sta f:JT+PS1+OE_CONTROL
    lda f:JT+PS2+OE_CONTROL
    ora #C_ENABLE
    sta f:JT+PS2+OE_CONTROL
    lda f:JT+SHD+OE_CONTROL
    ora #C_ENABLE
    sta f:JT+SHD+OE_CONTROL
    rep #$20
    .a16
    stz fer_state           ; FERRARI_SEQ1
    stz counter
    stz steering_old
    stz road_width_old
    stz car_state           ; CAR_NORMAL
    stz auto_brake
    stz torque_index
    stz torque
    stz revs
    stz revs+2
    stz rev_shift
    stz wheel_state         ; WHEELS_ON
    stz wheel_traction      ; TRACTION_ON
    stz is_slipping
    stz slip_sound
    stz car_inc_old
    stz car_x_diff
    stz rev_stop_flag
    stz revs_post_stop
    stz acc_post_stop
    stz rev_pitch1
    stz rev_pitch2
    stz sprite_ai_counter
    stz sprite_ai_curve
    stz sprite_ai_x
    stz sprite_ai_steer
    stz sprite_car_x_bak
    stz sprite_wheel_state
    stz sprite_slip_copy
    stz wheel_pal
    stz sprite_pass_y
    stz wheel_frame_reset
    stz wheel_counter
    stz accel_value
    stz accel_value_bak
    stz brake_value
    stz gear_value
    stz gear_bak
    stz brake_subtract
    stz brake_subtract+2
    stz gear_counter
    stz rev_adjust
    stz rev_adjust+2
    stz gear_smoke
    stz gfx_smoke
    stz cornering
    stz cornering_old
    lda #1
    sta car_ctrl_active
    ; torque_lookup[0x1F] = 0x66C (turbo off): the table's own value
    lda #PAL_RED            ; FERRARI_PALETTES[config.engine.car_pal = 0]
    sta ferrari_pal
    rts

;----------------------------------------------------------------------------
; reset_car (oferrari.cpp 124)
;----------------------------------------------------------------------------
FerResetCar:
    lda #1
    sta rev_shift
    lda #0
    STB8 spin_control2      ; ocrash.spin_control2 = 0
    stz revs
    stz revs+2
    stz car_increment
    stz car_increment+2
    stz gear_value
    stz gear_bak
    stz rev_adjust
    stz rev_adjust+2
    stz car_inc_old
    lda #$1000
    sta torque
    lda #$1F
    sta torque_index
    stz rev_stop_flag
    lda #0
    STB8 ingame_engine      ; false
    lda #$1E
    sta ingame_counter
    lda #S_STOP_SLIP
    sta slip_sound
    stz acc_adjust1
    stz acc_adjust2
    stz acc_adjust3
    stz brake_adjust1
    stz brake_adjust2
    stz brake_adjust3
    stz auto_brake
    stz counter
    stz is_slipping
    rts

;----------------------------------------------------------------------------
; tick (oferrari.cpp 151) (tick_frame is always true)
;----------------------------------------------------------------------------
FerTick:
    lda fer_state
    and #$00FF
    cmp #FERRARI_SEQ1
    bne @s2
    jsr AnimFerrariSeq
    ldy #anim_pass1
    jsr AnimSeqIntro
    ldy #anim_pass2
    jmp AnimSeqIntro
@s2:
    cmp #FERRARI_SEQ2
    bne @s3
    ldy #anim_ferrari
    jsr AnimSeqIntro
    ldy #anim_pass1
    jsr AnimSeqIntro
    ldy #anim_pass2
    jmp AnimSeqIntro
@s3:
    cmp #FERRARI_INIT
    bne @s4
    lda f:JT+FER+OE_CONTROL
    and #C_ENABLE
    beq @r
    jmp FerInitIngame
@s4:
    cmp #FERRARI_LOGIC
    bne @s5
    lda f:JT+FER+OE_CONTROL
    and #C_ENABLE
    beq :+
    jsr Logic
:   lda f:JT+PS1+OE_CONTROL
    and #C_ENABLE
    beq :+
    ldx #PS1
    jsr SetPassengerSprite
:   lda f:JT+PS2+OE_CONTROL
    and #C_ENABLE
    beq @r
    ldx #PS2
    jmp SetPassengerSprite
@s5:
    cmp #FERRARI_END_SEQ
    bne @r
    jmp AnimTickEndSeq
@r: rts

;----------------------------------------------------------------------------
; init_ingame (oferrari.cpp 210)
;----------------------------------------------------------------------------
FerInitIngame:
    stz car_state           ; CAR_NORMAL
    lda #FERRARI_LOGIC
    sta fer_state
    lda #0
    sta f:JT+FER+OE_RELOAD
    sta f:JT+FER+OE_COUNTER
    stz sprite_ai_counter
    stz sprite_ai_curve
    stz sprite_ai_x
    stz sprite_ai_steer
    stz sprite_car_x_bak
    stz sprite_wheel_state
    sta f:JT+PS1+OE_RELOAD
    sta f:JT+PS1+OE_COUNTER
    sta f:JT+PS1+OE_XW1
    sta f:JT+PS2+OE_RELOAD
    sta f:JT+PS2+OE_COUNTER
    sta f:JT+PS2+OE_XW1
    rts

;----------------------------------------------------------------------------
; logic (oferrari.cpp 236)
;----------------------------------------------------------------------------
Logic:
    lda bonus_control
    and #$00FF
    cmp #BONUS_DISABLE
    bne :+
    jmp FerrariNormal
:   cmp #BONUS_INIT
    beq @init
    cmp #BONUS_TICK
    beq @tick
    cmp #BONUS_SEQ0
    beq @seq0
    cmp #BONUS_SEQ1
    beq @seq1
    cmp #BONUS_SEQ2
    beq @seq2
    cmp #BONUS_SEQ3
    bne :+
    jmp @seq3
:   cmp #BONUS_END
    bne :+
    jmp @end
:   rts
@init:
    lda #2                  ; double rev shift
    sta rev_shift
    lda #BONUS_TICK
    STB8 bonus_control
@tick:
    jsr AiCheckRoadBonus
    jsr AiSetSteeringBonus
    lda rd_split_state
    beq @acc
    lda road_pos+2
    cmp #$0164              ; (road_pos >> 16) <= 0x163
    bcs @endanim
@acc:
    lda #$FF
    sta acc_adjust
    stz brake_adjust
    jmp SetupFerrariBonusSprite
@endanim:
    lda #1
    sta rev_shift
    lda #BONUS_SEQ0
    STB8 bonus_control
@seq0:
    lda road_pos+2
    cmp #$018E
    bcs :+
    jmp InitEndSeq
:   lda #BONUS_SEQ1
    STB8 bonus_control
@seq1:
    lda road_pos+2
    cmp #$018F
    bcs :+
    jmp InitEndSeq
:   lda #BONUS_SEQ2
    STB8 bonus_control
@seq2:
    lda road_pos+2
    cmp #$0190
    bcs :+
    jmp InitEndSeq
:   lda #BONUS_SEQ3
    STB8 bonus_control
@seq3:
    lda road_pos+2
    cmp #$0191
    bcs :+
    jmp InitEndSeq
:   stz car_ctrl_active     ; false
    stz car_increment
    stz car_increment+2
    lda #BONUS_END
    STB8 bonus_control
@end:
    stz acc_adjust
    lda #$FF
    sta brake_adjust
    jmp DoEndSeq

;----------------------------------------------------------------------------
; ferrari_normal (oferrari.cpp 317) (FORCE_AI false, new_attract off)
;----------------------------------------------------------------------------
FerrariNormal:
    .ifdef AUTOPILOT
    ; debug build: the attract AI drives the race (as CannonBall FORCE_AI)
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    bne :+
    jsr AiTick
    jmp SetupFerrariSprite
:
    .endif
    lda game_state
    and #$00FF
    cmp #GS_INIT_BEST1      ; GS_INIT, GS_ATTRACT
    bcs :+
    jsr AiTick
    jmp SetupFerrariSprite
:   cmp #GS_INIT_MUSIC      ; INIT_BEST1, BEST1, INIT_LOGO, LOGO
    bcc @brake
    cmp #GS_INIT_GAME       ; INIT_MUSIC, MUSIC: return
    bcc @r
    beq @brake              ; INIT_GAME
    cmp #GS_INGAME          ; START1-3
    bcc @steer
    cmp #GS_INIT_GAMEOVER   ; INGAME, INIT_BONUS, BONUS
    bcc @setup
    cmp #GS_INIT_MAP        ; INIT_GAMEOVER, GAMEOVER
    bcc @brake
    cmp #GS_INIT_BEST2      ; INIT_MAP, MAP
    bcc @setup
@r: rts                     ; other states: no case
@brake:
    stz brake_adjust
@steer:
    stz steering_adjust
@setup:
    jmp SetupFerrariSprite

;----------------------------------------------------------------------------
; setup_ferrari_sprite (oferrari.cpp 367)
;----------------------------------------------------------------------------
SetupFerrariSprite:
    lda #221
    sta f:JT+FER+OE_Y
    ; collision with another sprite object
    lda collision_sprite
    and #$00FF
    beq @nocoll
    lda coll_count1
    cmp coll_count2
    bne @nocoll
    inc a
    sta coll_count1
    lda #0
    STB8 collision_sprite
    STB8 crash_state
@nocoll:
    lda #0
    sta f:JT+FER+OE_X
    sta f:JT+FER+OE_WIDTH
    sep #$20
    .a8
    lda #$7F
    sta f:JT+FER+OE_ZOOM
    lda #DP_BOTTOM
    sta f:JT+FER+OE_DRAW_PROPS
    lda #3
    sta f:JT+FER+OE_SHADOW
    rep #$20
    .a16
    lda #$1FD
    sta f:JT+FER+OE_ROAD_PRIORITY
    sta f:JT+FER+OE_PRIORITY
    ; d4 = steering, 0 when close to the centre or too slow; then >> 2
    lda steering_adjust
    sta sf_d4
    SCMP #$FFF8             ; d4 >= -8
    bmi @d4
    lda sf_d4
    SCMP #8                 ; && d4 <= 7
    bpl @d4
    stz sf_d4
@d4:
    lda car_increment+2
    cmp #$14
    bcs :+
    stz sf_d4
:   lda sf_d4
    ASR16
    ASR16
    sta sf_d4
    stz sf_xoff
    lda skid_counter
    beq @notskid
    jmp @skid
@notskid:
    sep #$20
    .a8
    lda f:JT+FER+OE_CONTROL
    ora #C_HFLIP
    bit sf_d4+1             ; d4 < 0: h-flip
    bmi :+
    and #$FF-C_HFLIP
:   sta f:JT+FER+OE_CONTROL
    rep #$20
    .a16
    ; incline frame offset from the change in road y
    jsr InclineY
    ldx #0
    sta sf_t
    SCMP #$12
    bmi :+
    ldx #8
    lda sf_t
    SCMP #$13
    bmi :+
    ldx #16
:   stx sf_inc
    ; turn frame offset from abs(d4)
    lda sf_d4
    bpl :+
    NEG16
:   ldx #0
    cmp #$12
    bcc :+
    ldx #$18
    cmp #$1E
    bcc :+
    ldx #$30
:   txa
    clc
    adc sf_inc
    clc
    adc #.loword(ADR_sprite_ferrari_frames)
    tax
    jsr FrameRead
    ldy sf_d4
    bpl :+
    NEG16                   ; d4 < 0: x_off = -x_off
:   sta sf_xoff
    jmp @cont
@skid:
    ; A = ocrash.skid_counter
    sta sf_t
    sep #$20
    .a8
    lda f:JT+FER+OE_CONTROL
    ora #C_HFLIP
    bit sf_t+1              ; skid_counter < 0: h-flip
    bmi :+
    and #$FF-C_HFLIP
:   sta f:JT+FER+OE_CONTROL
    rep #$20
    .a16
    lda sf_t
    bpl :+
    NEG16
    sta sf_t
:   ldx #0
    lda sf_t
    SCMP #3
    bmi :+
    ldx #8
    lda sf_t
    SCMP #6
    bmi :+
    ldx #16
    lda sf_t
    SCMP #12
    bmi :+
    ldx #24
:   stx sf_fr
    jsr InclineY
    ldx #0
    sta sf_t
    SCMP #$12
    bmi :+
    ldx #$20
    lda sf_t
    SCMP #$13
    bmi :+
    ldx #$40
:   txa
    clc
    adc sf_fr
    clc
    adc #.loword(ADR_sprite_skid_frames)
    tax
    jsr FrameRead
    sta sf_xoff
    lda #TRACTION_OFF       ; both wheels lost traction
    sta wheel_traction
    lda skid_counter
    bmi @cont
    lda sf_xoff             ; skid_counter >= 0: x_off = -x_off
    NEG16
    sta sf_xoff
@cont:
    lda f:JT+FER+OE_X
    clc
    adc sf_xoff
    sta f:JT+FER+OE_X
    jsr FerShake
    jsr SetFerrariPalette
    ldx #FER
    jmp DrawSprite

; InclineY: A = road_y[road_p0 + 0x3D0/2] - road_y[road_p0 + 0x3E0/2] (int16)
InclineY:
    lda #$3D0/2
    jsr RoadYRaw
    sta iy_t
    lda #$3E0/2
    jsr RoadYRaw
    eor #$FFFF
    sec
    adc iy_t
    rts

; FrameRead: X = rom0 address (bank 0) of a Ferrari frame record:
; spr_ferrari->addr = read32(X), sprite_pass_y = read16(X + 4),
; -> A = read16(X + 6) (x offset)
FrameRead:
    lda f:R0B0,x
    xba
    sta f:JT+FER+OE_ADDR+2
    lda f:R0B0+2,x
    xba
    sta f:JT+FER+OE_ADDR
    lda f:R0B0+4,x
    xba
    sta sprite_pass_y
    lda f:R0B0+6,x
    xba
    rts

;----------------------------------------------------------------------------
; setup_ferrari_bonus_sprite (oferrari.cpp 487)
;----------------------------------------------------------------------------
SetupFerrariBonusSprite:
    lda #221
    sta f:JT+FER+OE_Y
    lda #$1FD
    sta f:JT+FER+OE_ROAD_PRIORITY
    sta f:JT+FER+OE_PRIORITY
    sep #$20
    .a8
    lda f:JT+FER+OE_CONTROL
    ora #C_HFLIP
    ldx steering_adjust     ; > 0: no h-flip
    beq :+
    bmi :+
    and #$FF-C_HFLIP
:   sta f:JT+FER+OE_CONTROL
    rep #$20
    .a16
    ; turn frame offset from abs(steering_adjust >> 2)
    lda steering_adjust
    ASR16
    ASR16
    bpl :+
    NEG16
:   ldx #0
    cmp #4
    bcc :+
    ldx #$18
    cmp #8
    bcc :+
    ldx #$30
:   txa
    clc
    adc #.loword(ADR_sprite_ferrari_frames) + 8   ; level frames, no slope
    tax
    jsr FrameRead
    ldy steering_adjust
    bpl :+
    NEG16
:   sta f:JT+FER+OE_X
    jsr SetFerrariPalette
    ldx #FER
    jmp DrawSprite

;----------------------------------------------------------------------------
; init_end_seq (oferrari.cpp 520)
;----------------------------------------------------------------------------
InitEndSeq:
    jsr AiCheckRoadBonus
    jsr AiSetSteeringBonus
    stz acc_adjust
    lda #$FF
    sta brake_adjust
    ; fall into DoEndSeq

;----------------------------------------------------------------------------
; do_end_seq (oferrari.cpp 534)
;----------------------------------------------------------------------------
DoEndSeq:
    lda #221
    sta f:JT+FER+OE_Y
    lda #$1FD
    sta f:JT+FER+OE_ROAD_PRIORITY
    sta f:JT+FER+OE_PRIORITY
    ; addr = anim_ferrari_frames + ((bonus_control - 0xC) << 1) (bank 0)
    lda bonus_control
    and #$00FF
    eor #$0080              ; (int8)
    sec
    sbc #$0080
    sec
    sbc #$0C
    asl a
    clc
    adc #.loword(ADR_anim_ferrari_frames)
    tax
    lda f:R0B0,x
    xba
    sta f:JT+FER+OE_ADDR+2
    lda f:R0B0+2,x
    xba
    sta f:JT+FER+OE_ADDR
    lda f:R0B0+4,x          ; read8: passenger y offset
    and #$00FF
    sta sprite_pass_y
    lda f:R0B0+5,x          ; read8: x
    and #$00FF
    sta f:JT+FER+OE_X
    lda ferrari_pal
    sta f:JT+FER+OE_PAL_SRC
    sep #$20
    .a8
    lda f:JT+FER+OE_CONTROL
    and #$FE
    ora f:R0B0+7,x          ; h-flip
    sta f:JT+FER+OE_CONTROL
    rep #$20
    .a16
    ldx #FER
    jsr MapPalette
    ldx #FER
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; set_ferrari_palette (oferrari.cpp 562) (brake lamp output omitted)
;----------------------------------------------------------------------------
SetFerrariPalette:
    ldy #0
    lda brake_adjust
    SCMP #BRAKE_THRESHOLD1
    bmi :+
    ldy #2
:   sty pl_pal
    lda car_increment+2
    beq @set
    ; car_increment = 5 - (car_increment >> 21), min 0
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #5
    bpl :+
    lda #0
:   sta wheel_frame_reset
    lda wheel_counter
    beq @inc
    bmi @inc
    dec a
    sta wheel_counter
    bra @set
@inc:
    lda wheel_frame_reset
    sta wheel_counter
    lda wheel_pal           ; wheel_pal++ (int8)
    inc a
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
    sta wheel_pal
@set:
    lda wheel_pal
    and #1
    clc
    adc ferrari_pal
    clc
    adc pl_pal
    sta f:JT+FER+OE_PAL_SRC
    rts

;----------------------------------------------------------------------------
; set_ferrari_x (oferrari.cpp 609)
;----------------------------------------------------------------------------
FerSetX:
    lda steering_adjust
    sta sx_st
    ; start of stage 1: less steering until road position 0x7F
    lda cur_stage
    and #$00FF
    bne @s1
    lda rd_split_state
    bne @s1
    lda road_pos+2
    cmp #$0080
    bcs @s1
    tax
    lda sx_st
    jsr SMul16
    jsr Mres7
    sta sx_st
@s1:
    ; steering -= steering_old, clamped to +-0x40
    lda sx_st
    sec
    sbc steering_old
    sta sx_st
    SCMP #$41
    bmi :+
    lda #$40
    sta sx_st
    bra @old
:   lda sx_st
    SCMP #$FFC0
    bpl @old
    lda #$FFC0
    sta sx_st
@old:
    lda steering_old
    clc
    adc sx_st
    sta steering_old
    sta sx_st
    ; less steering below a speed
    lda wheel_state
    and #$00FF
    bne @curve
    lda car_increment+2
    cmp #$0080
    bcs @curve
    tax
    lda sx_st
    jsr SMul16
    jsr Mres7
    sta sx_st
@curve:
    ; harder to steer into sharp corners
    lda road_curve
    bne :+
    jmp @shift
:   sec
    sbc #$40
    bmi :+
    jmp @shift
:   sta sx_rc               ; road_curve - 0x40 (< 0)
    lda #MAX_SPEED >> 17
    sec
    sbc car_increment+2     ; diff_from_max
    bmi :+
    jmp @shift
:   ldx sx_rc
    jsr SMul16
    lda mres                ; curve (int16)
    sta sx_t
    lda #$24C0              ; 0x24C0 - curve: V set when it is >= 0x8000
    sec
    sbc sx_t
    sta sx_t
    php
    lda sx_st
    ldx sx_t
    jsr SMul16              ; (int32) steering * (0x24C0 - curve)
    plp
    bvc :+
    lda mres+2              ; the multiplier was sx_t + 0x10000
    clc
    adc sx_st
    sta mres+2
:   lda mres
    sta dvd
    lda mres+2
    sta dvd+2
    lda #$24C0
    jsr SDiv32_16
    lda dvd
    sta sx_st
@shift:
    ; steering = -((steering >> 3) + (steering >> 5))
    lda sx_st
    ASR16
    ASR16
    ASR16
    sta sx_t
    ASR16
    ASR16
    clc
    adc sx_t
    NEG16
    sta sx_st
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    bne @move
    lda car_increment+2
    beq @width              ; car not moving: only the road width change
@move:
    lda car_x_pos
    clc
    adc sx_st
    sta car_x_pos
@width:
    lda road_width+2
    sec
    sbc road_width_old
    tax                     ; road_width_change
    lda road_width+2
    sta road_width_old
    lda car_x_pos
    bpl :+
    txa
    NEG16
    tax
:   txa
    clc
    adc car_x_pos
    sta car_x_pos
    rts

; Mres7: A = (mres >> 7) & $FFFF
Mres7:
    asl mres
    rol mres+2
    lda mres+1
    rts

;----------------------------------------------------------------------------
; set_ferrari_bounds (oferrari.cpp 686)
;----------------------------------------------------------------------------
FerSetBounds:
    lda road_width+2
    sta sb_rw               ; road_width16
    lda rd_split_state
    cmp #4
    bne @one
    ; road split, both lanes
    lda car_x_pos
    bpl :+
    lda sb_rw
    NEG16
    sta sb_rw
:   lda sb_rw
    clc
    adc #$140
    sta sb_d1
    lda sb_rw
    sec
    sbc #$140
    sta sb_rw
    bra @set
@one:
    lda sb_rw
    SCMP #$100              ; one lane: road_width16 <= 0xFF
    bpl @two
    lda sb_rw
    clc
    adc #OFFROAD_BOUNDS
    sta sb_d1
    NEG16
    sta sb_rw
    bra @set
@two:
    lda car_x_pos
    bpl :+
    lda sb_rw
    NEG16
    sta sb_rw
:   lda sb_rw
    clc
    adc #OFFROAD_BOUNDS
    sta sb_d1
    lda sb_rw
    sec
    sbc #OFFROAD_BOUNDS
    sta sb_rw
@set:
    lda car_x_pos
    SCMP sb_rw
    bpl :+
    lda sb_rw               ; car_x_pos < road_width16
    sta car_x_pos
    bra @bak
:   lda sb_d1
    SCMP car_x_pos
    bpl @bak
    lda sb_d1               ; car_x_pos > d1
    sta car_x_pos
@bak:
    lda car_x_pos
    sta car_x_bak
    lda road_width+2
    sta road_width_bak
    rts

;----------------------------------------------------------------------------
; check_wheels (oferrari.cpp 731)
;----------------------------------------------------------------------------
FerCheckWheels:
    stz wheel_state         ; WHEELS_ON
    stz wheel_traction      ; TRACTION_ON
    lda road_width+2
    sta cw_rw               ; uint16 road_width
    lda road_ctrl
    and #$00FF
    beq @r                  ; ROAD_OFF
    cmp #ROAD_BOTH_P0
    bcc @single             ; ROAD_R0, ROAD_R1
    cmp #ROAD_R0_SPLIT
    bcs :+
    jmp @both               ; ROAD_BOTH_P0/P1/P0_INV/P1_INV
:   cmp #ROAD_R1_SPLIT+1
    bcc @single             ; ROAD_R0_SPLIT, ROAD_R1_SPLIT
@r: rts
@single:
    sta cw_ctrl
    cmp #ROAD_R0_SPLIT
    bne :+
    lda car_x_pos
    sec
    sbc cw_rw
    bra :++
:   lda car_x_pos
    clc
    adc cw_rw
:   sta cw_x
    SCMP #$FF2D             ; x > -0xD4
    bmi :+
    lda cw_x
    SCMP #$00D5             ; && x <= 0xD4: on road
    bmi @r
:   lda cw_x
    SCMP #$FEFC             ; x < -0x104
    bmi @off
    lda cw_x
    SCMP #$0105             ; x > 0x104
    bpl @off
    lda cw_x
    SCMP #$00D5             ; x > 0xD4 (&& x <= 0x104)
    bmi @neg
    lda #WHEELS_RIGHT_OFF
    ldx cw_ctrl
    cpx #ROAD_R0_SPLIT
    bcc @sw
    lda #WHEELS_LEFT_OFF    ; split roads: left / right swapped
    bra @sw
@neg:                       ; x in [-0x104, -0xD4]
    lda #WHEELS_LEFT_OFF
    ldx cw_ctrl
    cpx #ROAD_R0_SPLIT
    bcc @sw
    lda #WHEELS_RIGHT_OFF
    bra @sw
@off:
    lda #WHEELS_OFF
@sw:
    jmp SetWheels
@both:
    lda cw_rw
    cmp #$0100              ; road_width > 0xFF (unsigned)
    bcc @narrow
    lda car_x_pos
    bpl :+
    clc
    adc cw_rw
    bra :++
:   sec
    sbc cw_rw
:   sta cw_x
    SCMP #$FEFC             ; x < -0x104
    bmi @off2
    lda cw_x
    SCMP #$0105             ; x > 0x104
    bpl @off2
    lda cw_x
    SCMP #$FF2C             ; x < -0xD4
    bpl :+
    lda #WHEELS_RIGHT_OFF
    bra SetWheels
:   lda cw_x
    SCMP #$00D5             ; x > 0xD4
    bmi @r2
    lda #WHEELS_LEFT_OFF
    bra SetWheels
@narrow:
    clc
    adc #$104
    sta cw_rw               ; road_width += 0x104
    lda car_x_pos
    sta cw_x
    bpl :+
    NEG16
    sta cw_x                ; x = -x
:   lda cw_rw
    SCMP cw_x               ; x > road_width
    bmi @off2
    lda cw_rw
    sec
    sbc #$30
    SCMP cw_x               ; x > road_width - 0x30
    bpl @r2
    lda #WHEELS_LEFT_OFF
    ldx car_x_pos
    bpl SetWheels
    lda #WHEELS_RIGHT_OFF
    bra SetWheels
@off2:
    lda #WHEELS_OFF
    bra SetWheels
@r2:
    rts

;----------------------------------------------------------------------------
; set_wheels (oferrari.cpp 812): A = new state
;----------------------------------------------------------------------------
SetWheels:
    sta wheel_state
    ldx #2
    cmp #WHEELS_OFF
    beq :+
    ldx #1
:   stx wheel_traction
    rts

;----------------------------------------------------------------------------
; set_curve_adjust (oferrari.cpp 823) (grippy_tyres off: / 0xDC)
;----------------------------------------------------------------------------
FerSetCurveAdjust:
    lda #170
    jsr RoadXRaw
    sta ca_t
    lda #511
    jsr RoadXRaw
    eor #$FFFF
    sec
    adc ca_t
    sta ca_x                ; x_diff = road_x[170] - road_x[511]
    lda rd_split_state
    beq :+
    lda car_x_pos
    bpl :+
    lda ca_x
    NEG16
    sta ca_x
:   lda ca_x
    ASR16
    ASR16
    ASR16
    ASR16
    ASR16
    ASR16
    beq @r
    ldx car_increment+2
    jsr SMul16              ; x_diff *= car_increment >> 16 (low 16 bits)
    lda mres
    ldx #$DC
    jsr SDivT16             ; x_diff /= 0xDC
    asl a                   ; x_diff <<= 1
    clc
    adc car_x_pos
    sta car_x_pos
@r: rts

; SDivT16: A = int16 dividend, X = divisor (1-$7FFF) -> A = quotient
; truncated toward zero (C++ '/'; SDiv16u floors)
SDivT16:
    sta sd_n
    jsr SDiv16u
    ldy sd_n
    bpl :+
    cpx #0
    beq :+
    inc a
:   rts

;----------------------------------------------------------------------------
; draw_shadow (oferrari.cpp 845)
;----------------------------------------------------------------------------
FerDrawShadow:
    lda f:JT+SHD+OE_CONTROL
    and #C_ENABLE
    beq @r
    lda game_state
    and #$00FF
    cmp #GS_MUSIC
    beq @r
    lda f:JT+FER+OE_ROAD_PRIORITY
    dec a
    sta f:JT+SHD+OE_ROAD_PRIORITY
    lda f:JT+FER+OE_X
    sta f:JT+SHD+OE_X
    lda #222
    sta f:JT+SHD+OE_Y
    sep #$20
    .a8
    lda #$99
    sta f:JT+SHD+OE_ZOOM
    lda #8
    sta f:JT+SHD+OE_DRAW_PROPS
    rep #$20
    .a16
    lda #.loword(ADR_shadow_data)
    sta f:JT+SHD+OE_ADDR
    lda #.hiword(ADR_shadow_data)
    sta f:JT+SHD+OE_ADDR+2
    ldx #SHD
    jmp DoSprOrderShadows
@r: rts

;----------------------------------------------------------------------------
; set_passenger_sprite (oferrari.cpp 881): X = passenger entry
;----------------------------------------------------------------------------
SetPassengerSprite:
    stx ps_spr
    lda f:JT+FER+OE_ROAD_PRIORITY
    STE OE_ROAD_PRIORITY
    lda f:JT+FER+OE_PRIORITY
    inc a
    STE OE_PRIORITY
    lda sprite_pass_y
    asl a
    asl a
    asl a
    sta ps_frame            ; frame = sprite_pass_y << 3
    lda car_increment+2
    cmp #$14
    bcc :+
    lda f:JT+FER+OE_CONTROL
    and #C_HFLIP
    bne :+
    lda ps_frame
    clc
    adc #4
    sta ps_frame
:   ; palette: collision frame (9) or normal, man or woman
    lda sprite_pass_y
    cmp #9
    bne @norm
    lda #$A
    cpx #PS1
    beq @pal
    lda #$8
    bra @pal
@norm:
    lda #$2D
    cpx #PS1
    beq @pal
    lda #$2E
@pal:
    STE OE_PAL_SRC
    ; offset_table = PASSn_OFFSET + frame (uint32)
    lda #.loword(PASS1_OFFSET)
    cpx #PS1
    beq :+
    lda #.loword(PASS2_OFFSET)
:   clc
    adc ps_frame
    sta ps_off
    lda #0
    adc #0
    sta ps_off+2
    ; x = spr_ferrari->x + read16(&offset_table)
    lda ps_off
    ldy ps_off+2
    jsr R0Word
    clc
    adc f:JT+FER+OE_X
    ldx ps_spr
    STE OE_X
    ; y = spr_ferrari->y + read16(offset_table + 2)
    lda ps_off
    clc
    adc #2
    pha
    lda ps_off+2
    adc #0
    tay
    pla
    jsr R0Word
    clc
    adc f:JT+FER+OE_Y
    ldx ps_spr
    STE OE_Y
    sep #$20
    .a8
    lda #$7F
    STE OE_ZOOM
    lda #8
    STE OE_DRAW_PROPS
    lda #3
    STE OE_SHADOW
    rep #$20
    .a16
    lda #0
    STE OE_WIDTH
    jsr SetPassengerFrame
    ldx ps_spr
    jmp DrawSprite

;----------------------------------------------------------------------------
; set_passenger_frame (oferrari.cpp 936): X = passenger entry
;----------------------------------------------------------------------------
SetPassengerFrame:
    stx pf_spr
    lda #.loword(ADR_sprite_pass_frames)
    cpx #PS2
    bne :+
    lda #.loword(ADR_sprite_pass_frames) + 4    ; female frames
:   sta pf_addr
    lda car_increment+2     ; inc (uint16)
    sta pf_inc
    beq @props
    ; moving: speed -> hair frame counter reload
    cmp #$0100
    bcc :+
    lda #$FF
:   lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta pf_t
    lda #9
    sec
    sbc pf_t
    bpl :+
    lda #0
:   STE OE_RELOAD
    LDE OE_COUNTER
    bne @dec                ; uint16 counter <= 0
    LDE OE_RELOAD
    STE OE_COUNTER
    LDE OE_XW1
    inc a
    STE OE_XW1
    bra @hair
@dec:
    dec a
    STE OE_COUNTER
@hair:
    LDE OE_XW1
    and #1
    asl a
    asl a
    asl a
    sta pf_inc              ; inc = (xw1 & 1) << 3
@props:
    LDE OE_PASS_PROPS
    SCMP #9
    bmi @frame
    lda skid_counter
    beq @right
    bmi @right
    lda #.loword(ADR_sprite_pass1_skidl)    ; skid left
    ldy #.hiword(ADR_sprite_pass1_skidl)
    cpx #PS1
    beq @set
    lda #.loword(ADR_sprite_pass2_skidl)
    ldy #.hiword(ADR_sprite_pass2_skidl)
    bra @set
@right:
    lda #.loword(ADR_sprite_pass1_skidr)
    ldy #.hiword(ADR_sprite_pass1_skidr)
    cpx #PS1
    beq @set
    lda #.loword(ADR_sprite_pass2_skidr)
    ldy #.hiword(ADR_sprite_pass2_skidr)
@set:
    STE OE_ADDR
    tya
    STE OE_ADDR+2
    rts
@frame:
    lda pf_addr             ; addr = read32(addr + inc) (bank 0)
    clc
    adc pf_inc
    tax
    lda f:R0B0,x
    xba
    tay
    lda f:R0B0+2,x
    xba
    ldx pf_spr
    STE OE_ADDR
    tya
    STE OE_ADDR+2
    rts

;----------------------------------------------------------------------------
; move (oferrari.cpp 989)
;----------------------------------------------------------------------------
FerMove:
    lda car_ctrl_active
    and #$00FF
    bne :+
    jmp @check_slip
:   ; auto braking
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq :+
    lda auto_brake
    and #$00FF
    beq :+
    stz acc_adjust
:   ; demo mode gear (gear button config: attract and bonus only)
    .ifndef AUTOPILOT               ; (debug autopilot = FORCE_AI: always)
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq :+
    cmp #GS_BONUS
    bne @gfx
    .endif
:   ldx #0
    lda car_increment+2
    cmp #$00A1
    bcc :+
    inx
:   txa
    STB8 gear
@gfx:
    stz gfx_smoke
    ; crash: slow the car
    lda crash_counter
    beq @nocrash
    lda spin_control1
    and #$00FF
    bne @nocrash
    lda car_increment+2     ; ((car_increment >> 16) * 31) >> 5
    ldx #31
    jsr UMul16
    ldx #5
:   lsr mres+2
    ror mres
    dex
    bne :-
    lda mres
    sta car_increment+2
    stz revs
    stz revs+2
    stz gear_value
    stz gear_bak
    stz gear_smoke
    lda #$1000
    sta torque
    jmp @move_car_rev
@nocrash:
    lda car_state
    and #$0080              ; car_state >= 0 (int8)
    bne :+
    stz car_state           ; CAR_NORMAL: clear smoke from wheels
:   lda time_counter        ; time out: clear acceleration
    and #$00FF
    bne :+
    stz acc_adjust
:   jsr CarAccBrake
    ; d2 = revs / torque
    lda revs
    sta dvd
    lda revs+2
    sta dvd+2
    lda torque
    jsr SDiv32_16
    lda dvd
    sta fd2
    lda dvd+2
    sta fd2+2
    lda ingame_engine
    and #$00FF
    bne :+
    jsr TickEngineDisabled
    bra @set_torque
:   lda torque_index
    sta fd1                 ; d1 = torque_index
    lda gear_counter
    bne @set_torque
    jsr DoGearTorque
@set_torque:
    lda torque_index
    asl a
    tax
    lda f:torque_lookup,x
    sta torque
    sta fnt                 ; new_torque
    ldx fd2
    jsr UMul16              ; d2 = (d2 & 0xFFFF) * new_torque
    lda mres
    sta fd2
    lda mres+2
    sta fd2+2
    stz fadj                ; rev_adjust_new = 0
    stz fadj+2
    lda gear_counter
    beq @cmp_acc
    lda fd2+2
    jsr TickGearChange      ; (d2 >> 16)
    bra @test_smoke
@cmp_acc:
    ; accel_copy = accel_value << 16: compare with d2
    lda fd2
    bne :+
    lda fd2+2
    cmp accel_value
    beq @test_smoke
:   lda #0
    sec
    sbc fd2
    lda accel_value
    sbc fd2+2
    bvc :+
    eor #$8000
:   bmi :+
    lda fnt                 ; accel_copy >= d2
    jsr GetSpeedIncValue
    bra @test_smoke
:   lda fnt
    jsr GetSpeedDecValue
@test_smoke:
    lda gear_smoke
    beq :+
    jsr TickSmoke
:   jsr SetBrakeSubtract
    jsr FinaliseRevs
    jsr ConvertRevsSpeed
    lda ingame_engine
    and #$00FF
    bne :+
    stz car_increment       ; in-game control not active: no speed
    stz car_increment+2
    stz car_inc_old
    bra @move_car_rev
:   lda game_state
    and #$00FF
    cmp #GS_BONUS
    beq @set_inc
    ; diff = car_inc_old - (d2 >> 16)
    lda car_inc_old
    sec
    sbc fd2+2
    beq @set_inc
    bmi @faster
    sta mv_diff             ; slowing down
    ldx #2
    lda brake_subtract
    ora brake_subtract+2
    beq :+
    ldx #8
:   stx mv_adj
    txa
    cmp mv_diff             ; diff > adjust
    bcs @set_inc
    lda car_inc_old
    sec
    sbc mv_adj
    sta fd2+2
    stz fd2
    bra @set_inc
@faster:
    NEG16
    sta mv_diff
    ldx #2
    lda car_increment+2
    cmp #$0029              ; <= 0x28: adjust >>= 1
    bcs :+
    ldx #1
:   stx mv_adj
    lda mv_diff
    SCMP #3                 ; diff > 2
    bmi @set_inc
    lda car_inc_old
    clc
    adc mv_adj
    sta fd2+2
    stz fd2
@set_inc:
    lda fd2
    sta car_increment
    lda fd2+2
    sta car_increment+2
@move_car_rev:
    jsr UpdateRoadPos
    jsr HudDrawRevCounter
@check_slip:
    lda gfx_smoke
    beq @no_smoke
    lda #CAR_SMOKE          ; smoke from the wheels
    sta car_state
    lda car_increment+2
    beq :+
    lda slip_sound
    cmp #S_STOP_SLIP
    bne @move_car
    lda #S_INIT_SLIP
    bra @snd
:   lda #S_STOP_SLIP
    bra @snd
@no_smoke:
    lda slip_sound
    cmp #S_STOP_SLIP
    beq @move_car
    lda #S_STOP_SLIP
@snd:
    sta slip_sound
    jsr SndQueueSound
@move_car:
    lda car_increment+2
    sta car_inc_old
    inc counter
    lda game_state          ; countdown: no speed
    and #$00FF
    cmp #GS_START1
    bcc @r
    cmp #GS_INGAME
    bcs @r
    stz car_increment
    stz car_increment+2
    stz car_inc_old
@r: rts

;----------------------------------------------------------------------------
; tick_engine_disabled (oferrari.cpp 1167): d2 = fd2
;----------------------------------------------------------------------------
TickEngineDisabled:
    stz torque_index
    lda coll_count1
    beq @nocoll
    stz spray_counter       ; crash: count down to the in-game engine
    lda ingame_counter
    dec a
    sta ingame_counter
    beq @switch
    rts
@nocoll:
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq @switch
    cmp #GS_INGAME
    beq @switch
    rts
@switch:
    lda #1
    STB8 ingame_engine      ; true
    lda #$1000
    sta torque
    lda revs+2              ; lookup = revs >> 16, max 0xFF
    sta te_lk
    SCMP #$0100
    bmi :+
    lda #$FF
    sta te_lk
:   ldx te_lk
    lda f:rev_inc_lookup,x
    and #$00FF
    eor #$FFFF
    sec
    adc #$30
    ASR16
    ASR16
    and #$00FF
    sta torque_index        ; (0x30 - rev_inc_lookup[lookup]) >> 2
    lda accel_value
    sec
    sbc #$10
    bpl :+
    lda #0
:   sta acc_post_stop
    lda te_lk
    sta revs_post_stop
    lda fd2                 ; d2 <<= 16
    sta fd2+2
    stz fd2
    lda #14
    sta rev_stop_flag
    rts

;----------------------------------------------------------------------------
; car_acc_brake (oferrari.cpp 1210) (offroad off)
;----------------------------------------------------------------------------
CarAccBrake:
    lda acc_adjust
    sta ab_acc2
    clc
    adc acc_adjust1
    clc
    adc acc_adjust2
    clc
    adc acc_adjust3
    ASR16
    ASR16
    sta ab_acc1
    lda acc_adjust2
    sta acc_adjust3
    lda acc_adjust1
    sta acc_adjust2
    lda ab_acc2
    sta acc_adjust1
    lda ingame_engine
    and #$00FF
    bne @skid
    lda ab_acc2
    sec
    sbc accel_value_bak
    bpl :+
    NEG16
:   SCMP #8
    bpl @skid
    lda accel_value_bak
    sta ab_acc1
@skid:
    ; no acceleration while skidding or spinning
    lda spin_control1
    and #$00FF
    bne @zero
    lda skid_counter
    bne @zero
    lda wheel_state
    and #$00FF
    beq @final
    ; off road
    ldx #6
    lda gear_value
    beq :+
    ldx #3
:   lda ab_acc1
    jsr SMul16              ; acc1 * 3 (high gear) or * 6
    lda mres
    sta dvd
    lda mres+2
    sta dvd+2
    lda #10
    jsr SDiv32_16
    lda dvd
    sta ab_acc1
    lda wheel_state
    and #$00FF
    cmp #WHEELS_OFF
    beq @final
    lda ab_acc1             ; one wheel off road: acc1 * 2.5
    ASR16
    sta ab_t
    lda ab_acc1
    asl a
    clc
    adc ab_t
    sta ab_acc1
    bra @final
@zero:
    stz ab_acc1
@final:
    lda ab_acc1
    sta accel_value
    sta accel_value_bak
    ; brake
    lda brake_adjust
    sta ab_t
    clc
    adc brake_adjust1
    clc
    adc brake_adjust2
    clc
    adc brake_adjust3
    ASR16
    ASR16
    sta brake_value
    lda brake_adjust2
    sta brake_adjust3
    lda brake_adjust1
    sta brake_adjust2
    lda ab_t
    sta brake_adjust1
    ; gears
    lda gear_value
    sta gear_bak
    lda gear
    and #$00FF
    beq :+
    lda #1
:   sta gear_value
    rts

;----------------------------------------------------------------------------
; do_gear_torque (oferrari.cpp 1279): d1 = fd1
;----------------------------------------------------------------------------
DoGearTorque:
    lda ingame_engine
    and #$00FF
    beq @set
    lda torque_index
    sta fd1
    lda gear_value
    beq :+
    jsr DoGearHigh
    bra @set
:   jsr DoGearLow
@set:
    lda fd1
    and #$00FF
    sta torque_index
    lda gear_value
    sta gear_bak
    rts

;----------------------------------------------------------------------------
; do_gear_low (oferrari.cpp 1294): d1 = fd1
;----------------------------------------------------------------------------
DoGearLow:
    lda gear_bak
    beq :+
    stz gear_value          ; recent shift from high to low
    lda #4
    sta gear_counter
    rts
:   lda car_increment+2     ; smoke when accelerating from standstill
    cmp #$50
    bcs :+
    lda accel_value
    SCMP #$E0
    bmi :+
    inc gfx_smoke
:   lda fd1
    SCMP #$10
    beq @r
    bpl @down
    inc fd1                 ; d1 < 0x10
@r: rts
@down:
    lda fd1
    sec
    sbc #4
    sta fd1
    SCMP #$10
    bpl @r
    lda #$10
    sta fd1
    rts

;----------------------------------------------------------------------------
; do_gear_high (oferrari.cpp 1320): d1 = fd1
;----------------------------------------------------------------------------
DoGearHigh:
    lda gear_bak
    bne :+
    lda #1                  ; change from low to high gear
    sta gear_value
    lda #4
    sta gear_counter
    rts
:   lda fd1
    cmp #$1F
    beq :+
    inc fd1
:   rts

;----------------------------------------------------------------------------
; tick_gear_change (oferrari.cpp 1336): A = rem -> fadj
;----------------------------------------------------------------------------
TickGearChange:
    sta tg_rem
    lda gear_counter        ; gear_counter-- (int8)
    dec a
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
    sta gear_counter
    jsr RevAdjustDecay
    lda fadj
    sta rev_adjust
    lda fadj+2
    sta rev_adjust+2
    lda gear_counter
    bne @r
    lda tg_rem              ; smoke when the gear counter hits zero
    sec
    sbc #$E0
    bmi @r
    lda accel_value
    sec
    sbc #$E0
    bmi @r
    sta gear_smoke
@r: rts

; RevAdjustDecay: fadj = rev_adjust - (rev_adjust >> 4)
RevAdjustDecay:
    lda rev_adjust
    sta rd_s
    lda rev_adjust+2
    sta rd_s+2
    ldx #4
:   lda rd_s+2
    cmp #$8000
    ror rd_s+2
    ror rd_s
    dex
    bne :-
    lda rev_adjust
    sec
    sbc rd_s
    sta fadj
    lda rev_adjust+2
    sbc rd_s+2
    sta fadj+2
    rts

;----------------------------------------------------------------------------
; get_speed_inc_value (oferrari.cpp 1365): A = new_torque, new_rev = fd2
; -> fadj
;----------------------------------------------------------------------------
GetSpeedIncValue:
    sta gi_nt
    lda fd2+2               ; lookup = new_rev >> 16, max 0xFF
    cmp #$0100
    bcc :+
    lda #$FF
:   tax
    lda f:rev_inc_lookup,x
    and #$00FF
    sta gi_ra
    lda car_increment+2     ; slow: double adjustment
    cmp #$0015
    bcs :+
    asl gi_ra
:   lda gi_nt
    tax
    jsr UMul16              ; new_torque * new_torque
    ldx #4
:   lsr mres+2
    ror mres
    dex
    bne :-
    lda mres+1              ; >> 12 (< $10000 for every torque_lookup value)
    ldx gi_ra
    jsr UMul16
    lda mres
    sta fadj
    lda mres+2
    sta fadj+2
    lda ingame_engine
    and #$00FF
    beq @r
    ldx rev_shift
    beq @r
:   asl fadj
    rol fadj+2
    dex
    bne :-
@r: rts

;----------------------------------------------------------------------------
; get_speed_dec_value (oferrari.cpp 1392): A = new_torque -> fadj
;----------------------------------------------------------------------------
GetSpeedDecValue:
    ldx #$440
    jsr UMul16
    ldx #4
:   lsr mres+2
    ror mres
    dex
    bne :-
    lda #0                  ; -((0x440 * new_torque) >> 4)
    sec
    sbc mres
    sta fadj
    lda #0
    sbc mres+2
    sta fadj+2
    lda wheel_state
    and #$00FF
    beq @r
    asl fadj                ; << 2 off road
    rol fadj+2
    asl fadj
    rol fadj+2
@r: rts

;----------------------------------------------------------------------------
; set_brake_subtract (oferrari.cpp 1403)
;----------------------------------------------------------------------------
SetBrakeSubtract:
    lda skid_counter
    bne @smoke
    lda spin_control1
    and #$00FF
    bne @smoke
    lda brake_value
    SCMP #BRAKE_THRESHOLD1
    bpl :+
    lda #0
    ldx #0
    bra @set
:   lda brake_value
    SCMP #BRAKE_THRESHOLD2
    bpl :+
    lda #.loword(BRAKE_DEC)
    ldx #.hiword(BRAKE_DEC)
    bra @set
:   lda brake_value
    SCMP #BRAKE_THRESHOLD3
    bpl :+
    lda #.loword(BRAKE_DEC * 3)
    ldx #.hiword(BRAKE_DEC * 3)
    bra @set
:   lda brake_value
    SCMP #BRAKE_THRESHOLD4
    bpl @smoke
    lda #.loword(BRAKE_DEC * 5)
    ldx #.hiword(BRAKE_DEC * 5)
    bra @set
@smoke:
    lda car_increment+2
    cmp #$0029
    bcc :+
    inc gfx_smoke
:   lda #.loword(BRAKE_DEC * 9)
    ldx #.hiword(BRAKE_DEC * 9)
@set:
    sta brake_subtract
    stx brake_subtract+2
    rts

;----------------------------------------------------------------------------
; finalise_revs (oferrari.cpp 1453): d2 = fd2, rev_adjust_new = fadj
;----------------------------------------------------------------------------
FinaliseRevs:
    lda fadj
    clc
    adc brake_subtract
    sta fadj
    lda fadj+2
    adc brake_subtract+2
    sta fadj+2
    lda fadj                ; < -0x44000
    cmp #.loword(-$44000)
    lda fadj+2
    sbc #.hiword(-$44000)
    bvc :+
    eor #$8000
:   bpl :+
    lda #.loword(-$44000)
    sta fadj
    lda #.hiword(-$44000)
    sta fadj+2
:   lda fd2
    clc
    adc fadj
    sta fd2
    lda fd2+2
    adc fadj+2
    sta fd2+2
    lda fadj
    sta rev_adjust
    lda fadj+2
    sta rev_adjust+2
    lda fd2+2
    bmi @zero               ; d2 < 0
    lda #.loword($13C0000)  ; d2 > 0x13C0000
    cmp fd2
    lda #.hiword($13C0000)
    sbc fd2+2
    bpl @r
    lda #.loword($13C0000)
    sta fd2
    lda #.hiword($13C0000)
    sta fd2+2
    rts
@zero:
    stz fd2
    stz fd2+2
@r: rts

;----------------------------------------------------------------------------
; convert_revs_speed (oferrari.cpp 1471): new_torque = fnt, d2 = fd2
;----------------------------------------------------------------------------
ConvertRevsSpeed:
    lda fd2
    sta revs
    lda fd2+2
    sta revs+2
    SCMP #$001F             ; d3 = max(d2, 0x1F0000): revs_top = d3 >> 16
    bpl :+
    lda #$001F
    bra :++
:   lda fd2+2
:   sta cr_top
    ; switching back to the in-game engine
    lda rev_stop_flag
    bne :+
    jmp @pitch
:   lda cr_top
    SCMP revs_post_stop
    bmi :+
    stz rev_stop_flag
    jmp @pitch
:   lda accel_value
    SCMP acc_post_stop
    bpl :+
    lda revs_post_stop
    sec
    sbc rev_stop_flag
    sta revs_post_stop
:   lda revs_post_stop
    ASR16
    sta cr_d5               ; d5 = revs_post_stop >> 1
    lda rev_stop_flag
    sta cr_d4               ; d4 = rev_stop_flag
    lda cr_top
    SCMP cr_d5
    bmi @sub
    lda cr_d5
    ASR16
    sta cr_d5
    lda cr_d4
    ASR16
    sta cr_d4
    lda cr_top
    SCMP cr_d5
    bmi @sub
    lda cr_d4
    ASR16
    sta cr_d4
@sub:
    lda revs_post_stop
    sec
    sbc cr_d4
    sta revs_post_stop
    SCMP #$1F
    bpl :+
    lda #$1F
    sta revs_post_stop
:   lda revs_post_stop
    sta cr_top
@pitch:
    lda cr_top              ; rev_pitch1 = (revs_top * 0x1A90) >> 8
    ldx #$1A90
    jsr SMul16
    lda mres+1
    sta rev_pitch1
    ; car increment speed: d2 = ((d2 >> 16) * 0x1A90) >> 8, (d2 << 16) >> 4
    lda fd2+2
    ldx #$1A90
    jsr SMul16
    lda mres+1
    sta fd2+2
    stz fd2
    ldx #4
:   lda fd2+2
    cmp #$8000
    ror fd2+2
    ror fd2
    dex
    bne :-
    ; d2 = (d2 / new_torque) * 0x480
    lda fd2
    sta dvd
    lda fd2+2
    sta dvd+2
    lda fnt
    jsr SDiv32_16
    ldx #7
:   asl dvd
    rol dvd+2
    dex
    bne :-
    lda dvd                 ; q << 7
    sta fd2
    lda dvd+2
    sta fd2+2
    ldx #3
:   asl dvd
    rol dvd+2
    dex
    bne :-
    lda fd2                 ; + q << 10
    clc
    adc dvd
    sta fd2
    lda fd2+2
    adc dvd+2
    sta fd2+2
    bmi @zero               ; d2 < 0
    lda #.loword(MAX_SPEED) ; d2 > max_speed
    cmp fd2
    lda #.hiword(MAX_SPEED)
    sbc fd2+2
    bpl @r
    lda #.loword(MAX_SPEED)
    sta fd2
    lda #.hiword(MAX_SPEED)
    sta fd2+2
    rts
@zero:
    stz fd2
    stz fd2+2
@r: rts

;----------------------------------------------------------------------------
; update_road_pos (oferrari.cpp 1530)
;----------------------------------------------------------------------------
UpdateRoadPos:
    lda #CAR_BASE_INC
    sta ur_ci
    stz ur_ci+2
    lda road_type
    SCMP #ROAD_STRAIGHT+1   ; bendy road: road_type > ROAD_STRAIGHT
    bpl :+
    jmp @mul
:   lda car_x_pos           ; x = car_x_pos (int32)
    sta dvd
    and #$8000
    beq :+
    lda #$FFFF
:   sta dvd+2
    lda road_type
    cmp #ROAD_RIGHT
    bne :+
    lda #0
    sec
    sbc dvd
    sta dvd
    lda #0
    sbc dvd+2
    sta dvd+2
:   lda #$28
    jsr SDiv32_16           ; x / 0x28
    lda road_curve
    and #$8000
    beq :+
    lda #$FFFF
:   sta ur_t
    lda dvd                 ; + road_curve
    clc
    adc road_curve
    sta ur_x
    lda dvd+2
    adc ur_t
    sta ur_x+2
    ; car_inc = car_inc * x (uint32)
    lda ur_x
    ldx #CAR_BASE_INC
    jsr UMul16
    lda mres
    sta ur_ci
    lda mres+2
    sta ur_ci+2
    lda ur_x+2
    ldx #CAR_BASE_INC
    jsr UMul16
    lda ur_ci+2
    clc
    adc mres
    sta ur_ci+2
    ; car_inc /= road_curve (unsigned: road_curve converted to uint32)
    lda road_curve
    bmi @bigdiv
    sta dvs
    lda ur_ci
    sta dvd
    lda ur_ci+2
    sta dvd+2
    jsr UDiv32_16
    lda dvd
    sta ur_ci
    lda dvd+2
    sta ur_ci+2
    bra @mul
@bigdiv:
    ldx #0                  ; divisor >= $FFFF8000: quotient 0 or 1
    lda ur_ci
    cmp road_curve
    lda ur_ci+2
    sbc #$FFFF
    bcc :+
    inx
:   stx ur_ci
    stz ur_ci+2
@mul:
    ; car_inc *= car_increment >> 16 (uint32)
    lda ur_ci
    ldx car_increment+2
    jsr UMul16
    lda mres
    sta ur_r
    lda mres+2
    sta ur_r+2
    lda ur_ci+2
    ldx car_increment+2
    jsr UMul16
    lda ur_r+2
    clc
    adc mres
    sta ur_r+2
    lda ur_r
    sta road_pos_change
    clc
    adc road_pos
    sta road_pos
    lda ur_r+2
    sta road_pos_change+2
    adc road_pos+2
    sta road_pos+2
    rts

;----------------------------------------------------------------------------
; tick_smoke (oferrari.cpp 1554) -> fadj
;----------------------------------------------------------------------------
TickSmoke:
    dec gear_smoke
    jsr RevAdjustDecay
    lda gear_smoke
    SCMP #8
    bmi :+
    inc gfx_smoke           ; trigger smoke
:   rts

;----------------------------------------------------------------------------
; do_sound_score_slip (oferrari.cpp 1565)
;----------------------------------------------------------------------------
FerDoSoundScoreSlip:
    ; engine pitch
    stz ss_pitch
    lda game_state
    and #$00FF
    cmp #GS_START1
    bcc :+
    cmp #GS_INGAME+1
    bcs :+
    lda rev_pitch2
    lsr a
    clc
    adc rev_pitch2
    sta ss_pitch
:   lda ss_pitch
    xba
    and #$00FF
    ldx #S_ENGINE_PITCH_H
    jsr SndSetEngineData
    lda ss_pitch
    and #$00FF
    ldx #S_ENGINE_PITCH_L
    jsr SndSetEngineData
    ; cornering: hard turn on a curved road
    stz ss_corn
    lda road_type
    cmp #ROAD_STRAIGHT
    beq @corn
    lda steering_adjust
    bpl :+
    NEG16
:   SCMP #$70
    bmi @corn
    lda car_x_pos
    SCMP car_x_old
    beq @corn               ; straight
    bmi @right
    lda road_type           ; move left
    cmp #ROAD_LEFT
    beq @corn
    dec ss_corn
    bra @corn
@right:
    lda road_type           ; move right
    cmp #ROAD_RIGHT
    beq @corn
    dec ss_corn
@corn:
    lda ss_corn
    sta cornering
    ; update_score
    lda car_x_pos
    sec
    sbc car_x_old
    sta car_x_diff
    lda car_x_pos
    sta car_x_old
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    bne :+
    rts
:   lda wheel_state         ; wheels on road: speed to score
    and #$00FF
    bne :+
    lda car_increment+2
    jsr StatsConvertSpeedScore
:   lda sprite_slip_copy
    bne :+
    lda skid_counter
    beq @copy
    lda #$FFFF
    sta is_slipping
    lda #S_INIT_SLIP
    jsr SndQueueSound
    bra @copy
:   lda skid_counter
    bne @copy
    stz is_slipping
    lda #S_STOP_SLIP
    jsr SndQueueSound
@copy:
    lda skid_counter
    sta sprite_slip_copy
    ; cornering: slip sound
    lda skid_counter
    bne @cold
    lda cornering_old
    bne :+
    lda cornering
    beq @cold
    lda #$FFFF              ; initialise slip
    sta is_slipping
    lda #S_INIT_SLIP
    jsr SndQueueSound
    bra @cold
:   lda cornering
    bne @cold
    stz is_slipping         ; stop cornering
    lda #S_STOP_SLIP
    jsr SndQueueSound
@cold:
    lda cornering
    sta cornering_old
    ; safety zone sound
    lda sprite_wheel_state
    beq :+
    lda wheel_state
    and #$00FF
    bne @ws
    lda #S_STOP_SAFETYZONE
    jsr SndQueueSound
    bra @ws
:   lda wheel_state
    and #$00FF
    beq @ws
    lda #S_INIT_SAFETYZONE
    jsr SndQueueSound
@ws:
    lda wheel_state
    and #$00FF
    sta sprite_wheel_state
    rts

;----------------------------------------------------------------------------
; shake (oferrari.cpp 1685)
;----------------------------------------------------------------------------
FerShake:
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    beq :+
    cmp #GS_ATTRACT
    beq :+
    rts
:   lda wheel_traction
    bne :+
    rts                     ; both wheels have traction
:   dec a
    sta sh_tr               ; traction = wheel_traction - 1
    jsr Random
    sta sh_rnd              ; (int16) random()
    lda f:JT+FER+OE_COUNTER
    inc a
    sta f:JT+FER+OE_COUNTER
    lda car_increment+2
    sta sh_ci
    cmp #$000B              ; no shake at low speeds
    bcs :+
    rts
:   lda #$3C
    ldx sh_tr
    beq @c3c
:   lsr a
    dex
    bne :-
@c3c:
    cmp sh_ci               ; car_inc <= 0x3C >> traction
    bcc @c78
    lda sh_rnd
    and #3
    sta sh_rnd
    beq @shake
    rts
@c78:
    lda #$78
    ldx sh_tr
    beq :++
:   lsr a
    dex
    bne :-
:   cmp sh_ci               ; car_inc <= 0x78 >> traction
    bcc @shake
    lda sh_rnd
    and #1
    sta sh_rnd
    beq @shake
    rts
@shake:
    lda f:JT+FER+OE_Y
    ldx sh_rnd
    bmi :+
    inc a
    inc a
:   dec a
    sta f:JT+FER+OE_Y
    lda sh_rnd
    and #1
    tax
    lda f:JT+FER+OE_COUNTER
    and #2                  ; BIT_1
    bne :+
    txa
    NEG16
    tax
:   txa
    clc
    adc f:JT+FER+OE_X
    sta f:JT+FER+OE_X
    rts

;----------------------------------------------------------------------------
; do_skid (oferrari.cpp 1724)
;----------------------------------------------------------------------------
FerDoSkid:
    lda skid_counter
    beq @r
    bmi :+
    dec a
    sta skid_counter
    lda car_x_pos
    clc
    adc #SKID_X_ADJ
    sta car_x_pos
    rts
:   inc a
    sta skid_counter
    lda car_x_pos
    sec
    sbc #SKID_X_ADJ
    sta car_x_pos
@r: rts

;----------------------------------------------------------------------------
; draw_sprite (oferrari.cpp 1740): X = entry (view mode is always original)
;----------------------------------------------------------------------------
DrawSprite:
    phx
    jsr MapPalette
    plx
    jmp DoSprOrderShadows

.segment "RODATA"
; rev_inc_lookup (oferrari.cpp 1751)
rev_inc_lookup:
    .include "asset_rev_inc_lookup.inc"

; torque_lookup (oferrari.cpp 1772) ([0x1F] = 0x66C: turbo off)
torque_lookup:
    .include "asset_torque_lookup.inc"
.endif
