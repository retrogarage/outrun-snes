; OCrash: collision & crash code - port of the original CannonBall engine
; engine/ocrash.cpp (classic arcade).  Scenery collisions: low speed bump
; (the car rises and stalls), medium speed spin, high speed flip (slow roll
; into the screen, or fast flight towards the camera); spins after hitting
; traffic (spin_control1 / spin_control2); passengers thrown out of the
; car, girl pointing her finger, camera pan back to the road.
;
; The crash sprites are the fixed jump table entries SPRITE_CRASH ..
; SPRITE_CRASH_PASS2_S (CrashInit stores their offsets in spr_*); the normal
; Ferrari sprites (oferrari.spr_ferrari/shadow/pass1/pass2) are the fixed
; entries SPRITE_FERRARI / SPRITE_SHADOW / SPRITE_PASS1 / SPRITE_PASS2.
; oroad.get_view_mode() is always VIEW_ORIGINAL: the in-car tests fold
; (`view != VIEW_INCAR || crash_type == CRASH_FLIP` is always true).
; Note: EOFS() must be the LAST term of an expression (ca65 C-style macro
; arguments extend to the end: JT+EOFS(i)+OE_X = JT+(i+OE_X)*64).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import MapPalette, DoSprOrderShadows, SndQueueSound, FerResetCar
.import Random, R0Set, SMul16, UMul16
.importzp rp0, mres
.import RD_Y
.importzp RDB
.import game_state
.import car_ctrl_active, car_inc_old, car_state, car_x_diff, ferrari_pal, wheel_state
.import car_increment, car_x_pos, road_type, road_curve
.import steering_adjust, crash_input
.import collision_sprite, spray_counter
.import road_width, road_p0

.export CrashInit, CrashIsFlip, CrashEnable, CrashClearState, CrashTick
.export crash_state, skid_counter, skid_counter_bak, spin_control1, spin_control2
.export coll_count1, coll_count2, crash_counter, crash_spin_count, crash_z

; OCrash::crash_type
CRASH_BUMP = 0
CRASH_SPIN = 1
CRASH_FLIP = 2
; OFerrari (1-byte variables are words: int8 -1 = $FFFF)
CAR_ANIM_SEQ = $FFFF
CAR_NORMAL   = 0
WHEELS_ON    = 0
PAL_RED      = 2
; OInitEngine::road_type
ROAD_STRAIGHT = 1
ROAD_RIGHT    = 2

.segment "IRAMBSS"          ; (hot: SA-1 I-RAM is twice as fast as BW-RAM)
; ---- public ----
crash_state:      .res 2    ; int8 (word)
skid_counter:     .res 2    ; int16
skid_counter_bak: .res 2    ; int16
spin_control1:    .res 2    ; uint8 (word)
spin_control2:    .res 2    ; uint8 (word)
coll_count1:      .res 2    ; int16
coll_count2:      .res 2    ; int16
crash_counter:    .res 2    ; int16
crash_spin_count: .res 2    ; int16
crash_z:          .res 2    ; int16
; oentry* spr_*: entry offsets (not exported: oferrari owns the names)
spr_ferrari:      .res 2
spr_shadow:       .res 2
spr_pass1:        .res 2
spr_pass1s:       .res 2
spr_pass2:        .res 2
spr_pass2s:       .res 2
; ---- private ----
spinflipcount1:   .res 2    ; int16
spinflipcount2:   .res 2    ; int16
slide:            .res 2    ; int16
frame:            .res 2    ; int16
addr:             .res 4    ; uint32 (rom0 address of the animation sequence)
camera_x_target:  .res 2    ; int16
camera_xinc:      .res 2    ; int16
lookup_index:     .res 2    ; int16
frame_restore:    .res 2    ; int16
shift:            .res 2    ; int16
crash_speed:      .res 2    ; int16
crash_zinc:       .res 2    ; int16
crash_side:       .res 2    ; int16
spin_pass_frame:  .res 2    ; int16
crash_type:       .res 2    ; int8 (word)
crash_delay:      .res 2    ; int16
function_pass1:   .res 2    ; member function pointers: routine address
function_pass2:   .res 2
; ---- scratch ----
cr_spr:     .res 2          ; passenger routines: oentry* sprite
cr_done:    .res 2          ; done(): sprite
cr_src:     .res 2          ; do_shadow: src_sprite
cr_dst:     .res 2          ; do_shadow: dst_sprite
cr_base:    .res 4          ; PtIdx8 base address
cr_pt:      .res 4          ; rom0 address (property_table / frames)
cr_t:       .res 4
cr_u:       .res 2
cr_ms:      .res 4          ; MulSU operands
cr_props:   .res 2          ; PassFrame: props, priorities
cr_pa:      .res 2
cr_pb:      .res 2

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (ocrash.cpp 41): the crash entries are fixed jump table slots
;----------------------------------------------------------------------------
CrashInit:
    lda #EOFS(SPRITE_CRASH)
    sta spr_ferrari
    lda #EOFS(SPRITE_CRASH_SHADOW)
    sta spr_shadow
    lda #EOFS(SPRITE_CRASH_PASS1)
    sta spr_pass1
    lda #EOFS(SPRITE_CRASH_PASS1_S)
    sta spr_pass1s
    lda #EOFS(SPRITE_CRASH_PASS2)
    sta spr_pass2
    lda #EOFS(SPRITE_CRASH_PASS2_S)
    sta spr_pass2s
    lda #DoCrashPassengers
    sta function_pass1
    sta function_pass2
    rts

;----------------------------------------------------------------------------
; is_flip (ocrash.cpp 55): -> A = 0/1
;----------------------------------------------------------------------------
CrashIsFlip:
    lda crash_counter
    beq @no
    lda crash_type
    cmp #CRASH_FLIP
    bne @no
    lda #1
    rts
@no:
    lda #0
    rts

;----------------------------------------------------------------------------
; enable (ocrash.cpp 60)
;----------------------------------------------------------------------------
CrashEnable:
    ldx spr_ferrari
    LDEB OE_CONTROL
    bit #C_ENABLE
    beq @en
    rts                     ; (called multiple times)
@en:
    ora #C_ENABLE
    STEB OE_CONTROL
    stz spinflipcount1
    stz spinflipcount2
    stz slide
    stz frame
    stz addr
    stz addr+2
    stz camera_x_target
    stz camera_xinc
    stz lookup_index
    stz frame_restore
    stz shift
    stz crash_speed
    stz crash_zinc
    stz crash_side
    lda #0
    STE OE_COUNTER
    ; outrun.ttrial.crashes++: time trial only (omitted)
    rts

;----------------------------------------------------------------------------
; clear_crash_state (ocrash.cpp 89)
;----------------------------------------------------------------------------
CrashClearState:
    stz spin_control1
    stz coll_count1
    stz coll_count2
    stz collision_sprite
    stz crash_counter
    stz crash_state
    stz crash_z
    stz spin_pass_frame
    stz crash_spin_count
    stz crash_delay
    stz crash_type
    stz skid_counter
    rts

;----------------------------------------------------------------------------
; tick (ocrash.cpp 105) (tick_frame is always true: the !tick_frame
; branches are dead)
;----------------------------------------------------------------------------
CrashTick:
    ; Ferrari
    ldx spr_ferrari
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @shd
    jsr DoCrash
@shd:
    ; car shadow
    ldx spr_shadow
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @p1
    ldx spr_ferrari
    ldy spr_shadow
    jsr DoShadow
@p1:
    ; passenger 1
    ldx spr_pass1
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @p1s
    ldx spr_pass1
    jsr @fp1
@p1s:
    ; passenger 1 shadow
    ldx spr_pass1s
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @p2
    ldx spr_pass1
    ldy spr_pass1s
    jsr DoShadow
@p2:
    ; passenger 2
    ldx spr_pass2
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @p2s
    ldx spr_pass2
    jsr @fp2
@p2s:
    ; passenger 2 shadow
    ldx spr_pass2s
    LDEB OE_CONTROL
    and #C_ENABLE
    beq @end
    ldx spr_pass2
    ldy spr_pass2s
    jmp DoShadow
@end:
    rts
@fp1:
    jmp (function_pass1)    ; (X = sprite)
@fp2:
    jmp (function_pass2)

;----------------------------------------------------------------------------
; do_crash (ocrash.cpp 144, source $1162)
;----------------------------------------------------------------------------
DoCrash:
    lda game_state
    and #$00FF
    cmp #GS_INIT_MUSIC
    beq @endc
    cmp #GS_MUSIC
    beq @endc
    cmp #GS_ATTRACT
    beq @cont
    cmp #GS_INGAME
    beq @cont
    cmp #GS_BONUS
    beq @cont
    ; other modes: render the crashing ferrari if the crash counter is set
    lda crash_counter
    beq @rp
    ldx spr_ferrari
    jsr DoSprOrderShadows
@rp:
    ; distance into screen from the crash counter
    ldx spr_ferrari
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts
@endc:
    jmp EndCollision
@cont:
    ; cont1: adjust steering
    lda steering_adjust
    sta cr_u                ; int16 steering_adjust (copy)
    stz steering_adjust
    lda car_ctrl_active
    and #$00FF
    bne @spin
    lda spin_control1
    and #$00FF
    bne @half
    ; inc = ((car_increment >> 16) * 31) >> 5 (32-bit intermediate)
    lda car_increment+2
    ldx #31
    jsr UMul16
    ldx #5
@sh5:
    lsr mres+2
    ror mres
    dex
    bne @sh5
    lda mres
    sta car_increment+2
    sta car_inc_old
    bra @spin
@half:
    lda cr_u
    cmp #$8000
    ror a
    sta steering_adjust     ; steering_adjust >> 1
@spin:
    ; dec_spin2: spin2_copy = spin_control2 - 2 (int16)
    lda spin_control2
    and #$00FF
    beq @dec1
    sec
    sbc #2
    bpl @sw2
    stz spin_control2
    bra @dec1
@sw2:
    jsr SpinSwitch
@dec1:
    ; dec_spin1
    lda spin_control1
    and #$00FF
    beq @crash
    sec
    sbc #2
    bpl @sw1
    stz spin_control1
    rts
@sw1:
    jmp SpinSwitch
@crash:
    ; not spinning: crash code
    jmp CrashSwitch

;----------------------------------------------------------------------------
; spin_switch (ocrash.cpp 223, source $1224): A = ctrl
;----------------------------------------------------------------------------
SpinSwitch:
    sta cr_u
    inc crash_counter
    stz crash_z
    lda cr_u
    and #3
    beq @init
    cmp #1
    beq @do
    jmp EndCollision        ; 2, 3: spin in progress - end collision
@init:
    jmp InitCollision       ; 0: no spin - init crash / spin routines
@do:
    jmp DoCollision         ; 1: init spin

;----------------------------------------------------------------------------
; crash_switch (ocrash.cpp 249, source $1252)
;----------------------------------------------------------------------------
CrashSwitch:
    inc crash_counter
    stz crash_z
    lda crash_state
    and #7
    asl a
    tax
    jmp (CrashSwitchTab,x)

CrashSwitchTab:
    .word InitCollision     ; 0 no crash: set up the crash routines
    .word CsCollision       ; 1 initial collision
    .word DoCarFlip         ; 2 flip car
    .word TriggerSmoke      ; 3 slide car, trigger smoke cloud
    .word TriggerSmoke      ; 4 horizontally flip car, trigger smoke cloud
    .word PostFlipAnim      ; 5 girl pointing finger / delay before the pan
    .word PanCamera         ; 6 pan camera to the track centre
    .word EndCollision      ; 7 camera repositioned: prepare for restart

CsCollision:
    lda crash_type
    and #3
    bne @col
    jmp DoBump
@col:
    jmp DoCollision

;----------------------------------------------------------------------------
; init_collision (ocrash.cpp 292, source $1962): spin & flip
;----------------------------------------------------------------------------
InitCollision:
    lda #CAR_ANIM_SEQ
    sta car_state           ; car animation sequence
    ; enable the crash sprites
    ldx spr_shadow
    jsr EnableX
    ldx spr_pass1
    jsr EnableX
    ldx spr_pass2
    jsr EnableX
    ; disable the normal sprites
    ldx #EOFS(SPRITE_FERRARI)
    jsr DisableX
    ldx #EOFS(SPRITE_SHADOW)
    jsr DisableX
    ldx #EOFS(SPRITE_PASS1)
    jsr DisableX
    ldx #EOFS(SPRITE_PASS2)
    jsr DisableX
    lda f:JT+OE_X+EOFS(SPRITE_FERRARI)
    ldx spr_ferrari
    STE OE_X
    lda #221
    STE OE_Y
    lda #$1FC
    STE OE_COUNTER
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    ; collided with another vehicle
    lda spin_control2
    and #$00FF
    beq @s1
    jmp InitSpin2
@s1:
    lda spin_control1
    and #$00FF
    beq @scen
    jmp InitSpin1
@scen:
    ; crash into scenery
    stz skid_counter
    lda car_increment+2     ; car_inc (uint16)
    cmp #$64
    bcs @med
    jmp CollideSlow
@med:
    cmp #$C8
    bcs @fast
    jmp CollideMed
@fast:
    jmp CollideFast

;----------------------------------------------------------------------------
; do_collision (ocrash.cpp 333, source $138C): also triggers a flip
;----------------------------------------------------------------------------
DoCollision:
    lda collision_sprite
    and #$00FF
    beq @f13f8
    stz collision_sprite
    lda spin_control1
    and #$00FF
    bne @recol
    lda spin_control2
    and #$00FF
    beq @road
@recol:
    stz spin_control2
    stz spin_control1
    jmp InitCollision       ; init collision with another sprite
@road:
    ; car_x_pos - (road_width >> 16) >= 0 (int): road generator 1
    lda car_x_pos
    sec
    sbc road_width+2
    bvc :+
    eor #$8000
:   bmi @gen2
    lda slide
    bmi @swap               ; generator 1: slide < 0
    bra @f13f8
@gen2:
    lda slide
    bmi @f13f8              ; generator 2: slide >= 0
@swap:
    eor #$FFFF
    inc a
    sta slide               ; slide = -slide
    lda car_x_pos
    sec
    sbc slide
    sta car_x_pos
    lda #S_CRASH2
    jsr SndQueueSound
@f13f8:
    ; property_table = addr + (frame << 3)
    jsr PtAddrFrame
    ldx spr_ferrari
    LDE OE_COUNTER
    sta crash_z
    lda #$80
    STEB OE_ZOOM
    lda #$1FD
    STE OE_PRIORITY
    lda car_x_pos
    sec
    sbc slide
    sta car_x_pos
    ldx spr_ferrari
    jsr PtAddr              ; spr_ferrari->addr = read32(property_table)
    ldy #4
    jsr PtByte
    ldx spr_ferrari
    jsr HflipA
    ; (pal_src = read8(5 + property_table) in the original)
    lda ferrari_pal
    ldx spr_ferrari
    STE OE_PAL_SRC
    ldy #6
    jsr PtByte
    jsr Sext8
    sta spin_pass_frame
    dec spinflipcount2
    beq @expired
    bmi @expired
    jmp @done               ; --spinflipcount2 > 0
@expired:
    lda crash_spin_count
    sta spinflipcount2
    lda spinflipcount1
    bne @adv
    jmp @f14f4
@adv:
    inc frame
    ; 0x1470: initialise the car flip?
    lda spin_control1
    and #$00FF
    bne @dospin
    lda spin_control2
    and #$00FF
    bne @dospin
    lda frame
    cmp #2
    bne @dospin
    lda crash_type
    cmp #CRASH_SPIN
    beq @dospin
    lda #2
    sta crash_state         ; flip
    lda #.loword(SPRITE_CRASH_FLIP)
    sta addr
    lda #.hiword(SPRITE_CRASH_FLIP)
    sta addr+2
    lda #3
    sta spinflipcount1      ; 3 flips remaining
    lda crash_spin_count
    sta spinflipcount2
    stz frame
    ; enable the passenger shadows
    ldx spr_pass1s
    jsr EnableX
    ldx spr_pass2s
    jsr EnableX
    jmp @done
@dospin:
    ; do spin: if (slide > 0) slide -= 2; else if (slide < -2) slide += 2
    lda slide
    beq @neg2
    bmi @neg2
    sec
    sbc #2
    sta slide
    bra @eos
@neg2:
    lda slide
    sec
    sbc #$FFFE
    bvc :+
    eor #$8000
:   bpl @eos
    lda slide
    clc
    adc #2
    sta slide
@eos:
    ; end of the frame sequence?
    ldy #7
    jsr PtByte
    bne @f14f4
    jmp @done
@f14f4:
    stz frame
    ; last spin?
    dec spinflipcount1
    beq @last
    bpl @more
@last:
    lda #S_STOP_SLIP
    jsr SndQueueSound
    lda spin_control2
    and #$00FF
    beq @l1
    inc a
    and #$00FF
    sta spin_control2
    bra @done
@l1:
    lda spin_control1
    and #$00FF
    beq @l2
    inc a
    and #$00FF
    sta spin_control1
    bra @done
@l2:
    ; init smoke
    lda #4
    sta crash_state         ; trigger smoke
    lda #1
    sta crash_spin_count
    ldx spr_ferrari
    LDE OE_X
    clc
    adc slide
    STE OE_X                ; x += slide
    bra @done
@more:
    inc crash_spin_count
@done:
    ldx spr_ferrari
    jmp Done

;----------------------------------------------------------------------------
; end_collision (ocrash.cpp 458, source $1D0C)
;----------------------------------------------------------------------------
EndCollision:
    ; enable the 'normal' Ferrari objects
    ldx #EOFS(SPRITE_FERRARI)
    jsr EnableX
    ldx #EOFS(SPRITE_SHADOW)
    jsr EnableX
    ldx #EOFS(SPRITE_PASS1)
    jsr EnableX
    ldx #EOFS(SPRITE_PASS2)
    jsr EnableX
    lda coll_count1
    sta coll_count2
    bne @cc
    lda #1
    sta coll_count2
    sta coll_count1
@cc:
    stz crash_counter
    stz crash_state
    stz collision_sprite
    lda #0
    sta f:JT+OE_X+EOFS(SPRITE_FERRARI)
    lda #221
    sta f:JT+OE_Y+EOFS(SPRITE_FERRARI)
    lda #1
    sta car_ctrl_active
    lda #CAR_NORMAL
    sta car_state
    stz spray_counter
    stz crash_z
    lda spin_control1
    and #$00FF
    beq @reset
    lda car_increment+2
    sta car_inc_old
    bra @sc
@reset:
    jsr FerResetCar
@sc:
    stz spin_control2
    stz spin_control1
    ldx spr_ferrari
    jsr DisableX
    ldx spr_shadow
    jsr DisableX
    ldx spr_pass1
    jsr DisableX
    ldx spr_pass1s
    jsr DisableX
    ldx spr_pass2
    jsr DisableX
    ldx spr_pass2s
    jsr DisableX
    lda #DoCrashPassengers
    sta function_pass1
    sta function_pass2
    lda #$10
    sta crash_input         ; delay in processing the steering
    rts

;----------------------------------------------------------------------------
; do_bump (ocrash.cpp 503, source $12BE): low speed bump - the car rises
; in the air and sinks
;----------------------------------------------------------------------------
DoBump:
    stz car_ctrl_active     ; disable user control of the car
    ldx spr_ferrari
    lda #$80
    STEB OE_ZOOM
    lda #$1FD
    STE OE_PRIORITY
    ; new_position = (int8_t) rom0.read8(DATA_MOVEMENT + (lookup_index << 3))
    lda #.loword(DATA_MOVEMENT)
    sta cr_base
    lda #.hiword(DATA_MOVEMENT)
    sta cr_base+2
    lda lookup_index
    jsr PtIdx8
    ldy #0
    jsr PtByte
    jsr Sext8
    sta cr_u
    beq @y
    ldx spr_ferrari
    LDE OE_COUNTER
    sta crash_z
@y:
    ; y = 221 - (new_position >> shift)
    lda shift
    and #31                 ; (int shift count)
    tay
    lda cr_u
    cpy #0
    beq @sub
@asr:
    cmp #$8000
    ror a
    dey
    bne @asr
@sub:
    eor #$FFFF
    sec
    adc #221
    ldx spr_ferrari
    STE OE_Y
    ; frames = addr + (frame << 3)
    jsr PtAddrFrame
    ldx spr_ferrari
    jsr PtAddr
    ldy #4
    jsr PtByte
    ldx spr_ferrari
    jsr HflipA
    ; (pal_src = read8(frames + 5) in the original)
    lda ferrari_pal
    ldx spr_ferrari
    STE OE_PAL_SRC
    ldy #6
    jsr PtByte
    jsr Sext8
    sta spin_pass_frame
    ; if (++lookup_index >= 0x10)
    inc lookup_index
    lda lookup_index
    sec
    sbc #$10
    bvc :+
    eor #$8000
:   bmi @done
    ; addr += frame_restore << 3
    lda addr
    sta cr_base
    lda addr+2
    sta cr_base+2
    lda frame_restore
    jsr PtIdx8
    lda cr_pt
    sta addr
    lda cr_pt+2
    sta addr+2
    ldx spr_ferrari
    jsr PtAddr              ; spr_ferrari->addr = read32(addr)
    ldy #6
    jsr PtByte
    jsr Sext8
    sta spin_pass_frame
    lda #4
    sta crash_state         ; trigger smoke cloud
    lda #1
    sta crash_spin_count    ; denote crash
@done:
    ldx spr_ferrari
    jmp Done

;----------------------------------------------------------------------------
; do_car_flip (ocrash.cpp 541, source $1562)
;----------------------------------------------------------------------------
DoCarFlip:
    ; recollided with a new sprite during the flip + slow crash
    lda collision_sprite
    and #$00FF
    bne @col
    jmp @flip_cont
@col:
    lda crash_speed
    cmp #1
    beq @col1
    jmp @flip_cont
@col1:
    lda car_increment+2
    sta cr_u                ; car_inc16
    ; road generator 1: car_x_pos - (road_width >> 16) >= 0 (int)
    lda car_x_pos
    sec
    sbc road_width+2
    bvc :+
    eor #$8000
:   bmi @gen2
    lda slide
    bmi @swap               ; generator 1: slide < 0
    bra @inc
@gen2:
    lda slide
    bpl @swap               ; generator 2: slide >= 0
@inc:
    ; 0x15F6: slide += slide >> 3
    lda slide
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    clc
    adc slide
    sta slide
    bra @flip_cont
@swap:
    ; swap_slide_dir2
    lda slide
    eor #$FFFF
    inc a
    sta slide
    lda cr_u
    lsr a
    sta car_increment+2     ; high word = car_inc16 >> 1
    lda #S_CRASH2
    jsr SndQueueSound
    lda car_increment+2
    cmp #$15
    bcc @flip_cont          ; (car_increment >> 16) > 0x14
    ; z = min(counter, 0x1FD); x_adjust = (0x50 * z) >> 9
    ldx spr_ferrari
    LDE OE_COUNTER
    cmp #$1FE
    bcc :+
    lda #$1FD
:   ldx #$50
    jsr SMul16
    jsr Mres9
    ldy slide
    bpl :+
    eor #$FFFF
    inc a                   ; if (slide < 0) x_adjust = -x_adjust
:   sta cr_t
    lda car_x_pos
    sec
    sbc cr_t
    sta car_x_pos
@flip_cont:
    stz collision_sprite
    jsr PtAddrFrame         ; frames = addr + (frame << 3)
    ldx spr_ferrari
    jsr PtAddr
    lda crash_speed
    bne @slower
    ; fast crash: the car heads towards the camera, then vanishes (0x161E)
    ldx spr_shadow
    jsr DisableX            ; disable the shadow
    ldx spr_ferrari
    LDE OE_COUNTER
    clc
    adc crash_zinc
    STE OE_COUNTER          ; increment crash z
    cmp #$400
    bcc @zinc               ; counter > 0x3FF (uint16)?
    lda #0
    STEB OE_ZOOM
    STE OE_COUNTER
    jsr InitFinger
    ldx spr_ferrari
    jmp Done
@zinc:
    inc crash_zinc
    bra @prio
@slower:
    ; slow crash (0x1648 flip_slower)
    ldx spr_ferrari
    LDE OE_COUNTER
    sec
    sbc crash_zinc
    STE OE_COUNTER          ; decrement crash z
    lda crash_zinc
    sec
    sbc #3
    bvc :+
    eor #$8000
:   bmi @prio
    dec crash_zinc          ; crash_zinc > 2: crash_zinc--
@prio:
    ; set_crash_z_inc: priority = min(counter, 0x1FD)
    ldx spr_ferrari
    LDE OE_COUNTER
    cmp #$1FE
    bcc :+
    lda #$1FD
:   STE OE_PRIORITY
    ; x_diff = (slide * priority) >> 9
    ldx slide
    jsr SMul16
    jsr Mres9
    sta cr_t
    lda car_x_pos
    sec
    sbc cr_t
    sta car_x_pos
    ; passenger_frame = (int8_t) read8(6 + frames)
    ldy #6
    jsr PtByte
    jsr Sext8
    sta cr_u
    bne @lowz
    ; start of sequence
    lda slide
    cmp #$8000
    ror a
    sta slide
    lda #S_CRASH2
    jsr SndQueueSound
@lowz:
    ; set z during the lower frames: passenger_frame <= 0x10 && counter <= 0x1FE
    lda cr_u
    sec
    sbc #$11
    bvc :+
    eor #$8000
:   bpl @f16cc
    ldx spr_ferrari
    LDE OE_COUNTER
    cmp #$1FF
    bcs @f16cc
    sta crash_z
@f16cc:
    ; passenger_frame = (passenger_frame * priority) >> 9
    ldx spr_ferrari
    LDE OE_PRIORITY
    ldx cr_u
    jsr SMul16
    jsr Mres9
    sta cr_u
    ; y = -(road_y[road_p0 + priority] >> 4) + 223 - passenger_frame
    ldx spr_ferrari
    LDE OE_PRIORITY
    jsr RoadY223
    sec
    sbc cr_u
    ldx spr_ferrari
    STE OE_Y
    ; zoom from z: (uint8) (counter >> 2), at least 0x40
    LDE OE_COUNTER
    lsr a
    lsr a
    and #$00FF
    cmp #$40
    bcs :+
    lda #$40
:   STEB OE_ZOOM
    ; h-flip
    lda crash_side
    jsr HflipA
    ; palette (recoloured car hack; original: pal_src = read8(4 + frames))
    lda frame
    sec
    sbc #7
    bvc :+
    eor #$8000
:   bmi @pal2
    lda ferrari_pal         ; frame >= 7
    bra @pal
@pal2:
    lda ferrari_pal
    cmp #PAL_RED
    bne @pal4
    ldy #4
    jsr PtByte
    bra @pal
@pal4:
    clc
    adc #4
@pal:
    ldx spr_ferrari
    STE OE_PAL_SRC
    dec spinflipcount2
    beq @expired
    bmi @expired
    bra @done               ; --spinflipcount2 > 0
@expired:
    lda crash_spin_count
    sta spinflipcount2
    ; 0x1736: advance to the next frame in the sequence
    lda spinflipcount1
    beq @last
    inc frame
    ldy #7
    jsr PtByte
    and #$80
    beq @done               ; not the end of the frame sequence
@last:
    stz frame
    dec spinflipcount1
    beq @finger
    bmi @finger
    inc crash_spin_count
    bra @done
@finger:
    jsr InitFinger
@done:
    ldx spr_ferrari
    jmp Done

;----------------------------------------------------------------------------
; init_finger (ocrash.cpp 707, source $175C): frames = cr_pt
;----------------------------------------------------------------------------
InitFinger:
    lda #1
    sta crash_spin_count    ; denote crash has taken place
    lda crash_type
    cmp #CRASH_FLIP
    bne @slide
    ; delay whilst the girl points her finger
    stz wheel_state         ; WHEELS_ON
    lda #CAR_NORMAL
    sta car_state
    stz slide
    lda addr
    clc
    adc cr_pt
    sta addr
    lda addr+2
    adc cr_pt+2
    sta addr+2              ; addr += frames
    lda #30
    sta crash_delay
    lda #5
    sta crash_state
    rts
@slide:
    ; slide car and trigger smoke cloud
    lda #3
    sta crash_state
    stz frame
    lda #.loword(SPRITE_CRASH_MAN1)
    sta addr
    lda #.hiword(SPRITE_CRASH_MAN1)
    sta addr+2
    lda #4
    sta crash_spin_count    ; denote third flip
    sta spinflipcount2
    rts

;----------------------------------------------------------------------------
; trigger_smoke (ocrash.cpp 734, source $17D2): slide the car slightly,
; then trigger smoke
;----------------------------------------------------------------------------
TriggerSmoke:
    ldx spr_ferrari
    LDE OE_COUNTER
    sta crash_z
    lda slide
    sta cr_u                ; slide_copy
    beq @slid
    bmi @sinc
    dec slide
    bra @slid
@sinc:
    inc slide
@slid:
    lda car_x_pos
    sec
    sbc cr_u
    sta car_x_pos           ; slide car
    lda addr
    sta cr_pt
    lda addr+2
    sta cr_pt+2
    ldx spr_ferrari
    jsr PtAddr              ; addr = read32(addr)
    ldy #4
    jsr PtByte
    ldx spr_ferrari
    jsr HflipA
    ; (pal_src = read8(5 + addr) in the original)
    lda ferrari_pal
    ldx spr_ferrari
    STE OE_PAL_SRC
    ldy #6
    jsr PtByte
    jsr Sext8
    sta spin_pass_frame
    ; slow car: car_increment - ((car_increment >> 2) & 0xFFFF0000), low
    ; word kept: high word -= high word >> 2
    lda car_increment+2
    lsr a
    lsr a
    sta cr_t
    lda car_increment+2
    sec
    sbc cr_t
    sta car_increment+2
    bne @done
    ; car stationary: post crash animation delay
    stz car_increment
    stz wheel_state         ; WHEELS_ON
    lda #CAR_NORMAL
    sta car_state
    stz slide
    lda #30
    sta crash_delay
    lda #5
    sta crash_state
@done:
    ldx spr_ferrari
    jmp Done

;----------------------------------------------------------------------------
; post_flip_anim (ocrash.cpp 779, source $1870)
;----------------------------------------------------------------------------
PostFlipAnim:
    stz car_ctrl_active     ; car and road updates disabled
    dec crash_delay
    beq @pan
    bmi @pan
    jmp @done               ; --crash_delay > 0
@pan:
    lda #1
    sta car_ctrl_active
    lda #6
    sta crash_state         ; pan camera to the track centre
    lda road_width+2
    sta cr_u                ; road_width (int16)
    lda #8
    sta camera_xinc
    ; double road: road_width >= 0xD7
    lda cr_u
    sec
    sbc #$D7
    bvc :+
    eor #$8000
:   bmi @single
    lda car_x_pos
    bpl @tgt
    lda cr_u
    eor #$FFFF
    inc a
    sta cr_u                ; car_x_pos < 0: road_width = -road_width
    bra @tgt
@single:
    stz cr_u
@tgt:
    lda cr_u
    sta camera_x_target
    ; road_width < car_x_pos (int16)?
    sec
    sbc car_x_pos
    bvc :+
    eor #$8000
:   bpl @right
    ; camera_xinc = -(camera_xinc + ((car_x_pos - road_width) >> 6))
    lda car_x_pos
    sec
    sbc cr_u                ; 1..65535 (int): unsigned shift
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc camera_xinc
    eor #$FFFF
    inc a
    sta camera_xinc
    bra @done
@right:
    ; camera_xinc += (road_width - car_x_pos) >> 6
    lda cr_u
    sec
    sbc car_x_pos           ; 0..65535 (int): unsigned shift
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc camera_xinc
    sta camera_xinc
@done:
    ldx spr_ferrari
    jmp Done

;----------------------------------------------------------------------------
; pan_camera (ocrash.cpp 825, source $18EC): pan back to the centre
;----------------------------------------------------------------------------
PanCamera:
    lda #1
    sta car_ctrl_active
    lda car_x_pos
    clc
    adc camera_xinc
    sta car_x_pos
    ; x_diff = (car_x_diff * counter) >> 9 (int16 * uint16)
    ldx spr_ferrari
    LDE OE_COUNTER
    tax
    lda car_x_diff
    jsr MulSU
    jsr Mres9
    ldx spr_ferrari
    clc
    ADCE OE_X
    STE OE_X
    lda camera_xinc
    bmi @left
    ; pan right: camera_x_target <= car_x_pos
    lda car_x_pos
    sec
    sbc camera_x_target
    bvc :+
    eor #$8000
:   bmi @done
    bra @set
@left:
    ; pan left: camera_x_target >= car_x_pos
    lda camera_x_target
    sec
    sbc car_x_pos
    bvc :+
    eor #$8000
:   bmi @done
@set:
    lda #7
    sta crash_state         ; camera positioned: ready for restart
@done:
    ldx spr_ferrari
    jmp Done

;----------------------------------------------------------------------------
; init_spin1 (ocrash.cpp 851, source $1C7E)
;----------------------------------------------------------------------------
InitSpin1:
    lda #S_INIT_SLIP
    jsr SndQueueSound
    lda car_increment+2
    sta cr_u                ; car_inc (uint16)
    lda #1
    sta cr_t                ; spins
    lda cr_u
    cmp #$B5
    bcc @sp
    jsr Random              ; car_inc > 0xB4: spins += random() & 1
    and #1
    clc
    adc cr_t
    sta cr_t
@sp:
    lda cr_t
    sta spinflipcount1
    lda #2
    sta crash_spin_count
    sta spinflipcount2
    ; slide = ((spins + 1) << 2) + (car_inc > 0xFF) ? 0xFF >> 3 : car_inc >> 3
    ; C precedence: the condition is ((spins + 1) << 2) + (car_inc > 0xFF)
    lda cr_t
    inc a
    asl a
    asl a
    sta cr_t+2
    lda cr_u
    cmp #$100               ; C = car_inc > 0xFF
    lda #0
    rol a
    clc
    adc cr_t+2
    beq @c0
    lda #$FF >> 3
    bra @sl
@c0:
    lda cr_u
    lsr a
    lsr a
    lsr a
@sl:
    sta slide
    ; (addr = sprite_crash_spin1 either way)
    lda skid_counter_bak
    bmi @adr
    lda slide
    eor #$FFFF
    inc a
    sta slide
@adr:
    lda #.loword(SPRITE_CRASH_SPIN1)
    sta addr
    lda #.hiword(SPRITE_CRASH_SPIN1)
    sta addr+2
    lda spin_control1
    inc a
    and #$00FF
    sta spin_control1
    stz frame
    stz skid_counter
    ldx spr_ferrari
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts

;----------------------------------------------------------------------------
; init_spin2 (ocrash.cpp 880, source $1C10)
;----------------------------------------------------------------------------
InitSpin2:
    lda #S_INIT_SLIP
    jsr SndQueueSound
    lda #1
    sta spinflipcount1
    lda #2
    sta crash_spin_count
    lda #8
    sta spinflipcount2
    ; slide = (car_inc > 0xFF) ? 0xFF >> 3 : car_inc >> 3
    lda car_increment+2
    cmp #$100
    bcc :+
    lda #$FF
:   lsr a
    lsr a
    lsr a
    sta slide
    ; (addr = sprite_crash_spin1 either way)
    lda road_type
    cmp #ROAD_RIGHT
    bne @adr
    lda slide
    eor #$FFFF
    inc a
    sta slide
@adr:
    lda #.loword(SPRITE_CRASH_SPIN1)
    sta addr
    lda #.hiword(SPRITE_CRASH_SPIN1)
    sta addr+2
    lda spin_control2
    inc a
    and #$00FF
    sta spin_control2
    stz frame
    stz skid_counter
    ldx spr_ferrari
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts

;----------------------------------------------------------------------------
; collide_slow (ocrash.cpp 909, source $19EE): rebound and bounce the car
;----------------------------------------------------------------------------
CollideSlow:
    lda #S_REBOUND
    jsr SndQueueSound
    ; shift value for the bump from the speed: how much the car rises
    lda car_increment+2
    ldx #6
    cmp #$29
    bcc @sh
    dex
    cmp #$47
    bcc @sh
    dex
@sh:
    stx shift
    stz lookup_index
    ; y = road_y[road_p0 + 0x3E0 / 2] - road_y[road_p0 + 0x3F0 / 2] (int16)
    lda road_p0
    clc
    adc #($3E0 / 2) * 2
    tax
    lda f:RDB*$10000+RD_Y,x
    sec
    sbc f:RDB*$10000+RD_Y+(($3F0 - $3E0) / 2) * 2,x
    sta cr_u
    stz frame_restore
    sec
    sbc #$12
    bvc :+
    eor #$8000
:   bmi @fr
    inc frame_restore       ; y >= 0x12
@fr:
    lda cr_u
    sec
    sbc #$13
    bvc :+
    eor #$8000
:   bmi @fr2
    inc frame_restore       ; y >= 0x13
@fr2:
    lda car_x_pos
    bpl @lhs
    lda #.loword(SPRITE_BUMP_DATA2)
    sta addr
    lda #.hiword(SPRITE_BUMP_DATA2)
    sta addr+2
    bra @type
@lhs:
    lda #.loword(SPRITE_BUMP_DATA1)
    sta addr
    lda #.hiword(SPRITE_BUMP_DATA1)
    sta addr+2
@type:
    lda #CRASH_BUMP
    sta crash_type          ; low speed bump
    stz car_increment+2     ; car_increment &= 0xFFFF
    ; set_collision
    stz frame
    lda #1
    sta crash_state         ; collision with object
    ldx spr_ferrari
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts

;----------------------------------------------------------------------------
; collide_med (ocrash.cpp 949, source $1A98): spin car
;----------------------------------------------------------------------------
CollideMed:
    lda #S_INIT_SLIP
    jsr SndQueueSound
    ; number of spins from the speed
    lda car_increment+2
    sta cr_u                ; car_inc (uint16)
    ldx #1
    cmp #$97
    bcc :+
    inx
:   stx spinflipcount1
    lda #2
    sta crash_spin_count
    sta spinflipcount2
    ; slide = ((spinflipcount1 + 1) << 2) + (min(car_inc, 0xFF) >> 3)
    lda cr_u
    cmp #$100
    bcc :+
    lda #$FF
:   lsr a
    lsr a
    lsr a
    sta cr_t
    lda spinflipcount1
    inc a
    asl a
    asl a
    clc
    adc cr_t
    sta slide
    ; (addr = sprite_crash_spin1 either way)
    lda car_x_pos
    bpl @adr
    lda slide
    eor #$FFFF
    inc a
    sta slide
@adr:
    lda #.loword(SPRITE_CRASH_SPIN1)
    sta addr
    lda #.hiword(SPRITE_CRASH_SPIN1)
    sta addr+2
    lda #CRASH_SPIN
    sta crash_type
    ; set_collision
    stz frame
    lda #1
    sta crash_state
    ldx spr_ferrari
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts

;----------------------------------------------------------------------------
; collide_fast (ocrash.cpp 980, source $1B12): spin, then flip car
;----------------------------------------------------------------------------
CollideFast:
    lda #S_CRASH1
    jsr SndQueueSound
    lda car_increment+2
    sta cr_u                ; car_inc (uint16)
    cmp #$FB
    bcc @slowc
    lda #1
    sta crash_zinc
    stz crash_speed
    bra @cnt
@slowc:
    lda #$10
    sta crash_zinc
    lda #1
    sta crash_speed
@cnt:
    lda #1
    sta spinflipcount1
    lda #2
    sta crash_spin_count
    sta spinflipcount2
    ; slide = min(car_inc, 0xFF) >> 2; slide += slide >> 1
    lda cr_u
    cmp #$100
    bcc :+
    lda #$FF
:   lsr a
    lsr a
    sta slide
    cmp #$8000
    ror a
    clc
    adc slide
    sta slide
    lda road_type
    cmp #ROAD_STRAIGHT
    beq @straight
    ; d2 = (0x78 - min(road_curve, 0x78)) >> 1 (int, 0..0x8078)
    lda road_curve
    sec
    sbc #$79
    bvc :+
    eor #$8000
:   bmi @rc                 ; road_curve <= 0x78
    lda #$78
    bra @d2
@rc:
    lda road_curve
@d2:
    sta cr_t
    lda #$78
    sec
    sbc cr_t
    lsr a
    ; collide_fast_curve
    clc
    adc slide
    sta slide
    lda road_type
    cmp #ROAD_RIGHT
    bne @max
    bra @neg
@straight:
    lda car_x_pos
    bpl @max                ; rhs: car_x_pos < 0
@neg:
    lda slide
    eor #$FFFF
    inc a
    sta slide
@max:
    ; set_fast_slide: slide = min(slide, 0x78) (int16)
    lda slide
    sec
    sbc #$79
    bvc :+
    eor #$8000
:   bmi @side
    lda #$78
    sta slide
@side:
    lda car_x_pos
    bpl @lhs
    lda #.loword(SPRITE_CRASH_SPIN2)
    sta addr
    lda #.hiword(SPRITE_CRASH_SPIN2)
    sta addr+2
    stz crash_side          ; rhs
    bra @type
@lhs:
    lda #.loword(SPRITE_CRASH_SPIN1)
    sta addr
    lda #.hiword(SPRITE_CRASH_SPIN1)
    sta addr+2
    lda #1
    sta crash_side          ; lhs
@type:
    lda #CRASH_FLIP
    sta crash_type
    ; set_collision
    stz frame
    lda #1
    sta crash_state
    ldx spr_ferrari
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts

;----------------------------------------------------------------------------
; done (ocrash.cpp 1040, source $1556): X = sprite
;----------------------------------------------------------------------------
Done:
    stx cr_done
    jsr MapPalette
    ldx cr_done
    jsr DoSprOrderShadows
    ldx cr_done
    LDE OE_COUNTER
    STE OE_ROAD_PRIORITY
    rts

;----------------------------------------------------------------------------
; do_shadow (ocrash.cpp 1059, source $1DF2): X = src_sprite, Y = dst_sprite
;----------------------------------------------------------------------------
DoShadow:
    stx cr_src
    sty cr_dst
    lda #3
    sta cr_t                ; shadow_shift
    cpx spr_ferrari
    bne @xy
    ; Ferrari shadow
    tyx
    lda #DP_BOTTOM
    STEB OE_DRAW_PROPS
    lda #1
    sta cr_t
@xy:
    ldx cr_src
    LDE OE_X
    ldx cr_dst
    STE OE_X
    ldx cr_src
    LDE OE_ROAD_PRIORITY
    ldx cr_dst
    STE OE_ROAD_PRIORITY
    ; counter = src->counter >> shadow_shift; counter -= counter >> 2
    ldx cr_src
    LDE OE_COUNTER
    ldy cr_t
@shr:
    lsr a
    dey
    bne @shr
    sta cr_u
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc cr_u
    ldx cr_dst
    STEB OE_ZOOM            ; (uint8) counter
    ; y = -(road_y[road_p0 + min(src->counter, 0x1FF)] >> 4) + 223
    ldx cr_src
    LDE OE_COUNTER
    cmp #$200
    bcc :+
    lda #$1FF
:   jsr RoadY223
    ldx cr_dst
    STE OE_Y
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; do_crash_passengers (ocrash.cpp 1099, source $1E66): X = sprite
; (flips & spins only)
;----------------------------------------------------------------------------
DoCrashPassengers:
    stx cr_spr
    lda crash_state
    cmp #2
    bne @nonflip
    ; flip car: update the function pointers
    cpx spr_pass1
    bne @p2
    lda #FlipStart
    sta function_pass1
    bra @flip
@p2:
    cpx spr_pass2
    bne @flip
    lda #FlipStart
    sta function_pass2
@flip:
    jmp CrashPassFlip       ; crash passenger flip (X = sprite)
@nonflip:
    ; crash_state < 5 (int8)
    lda crash_state
    sec
    sbc #5
    bvc :+
    eor #$8000
:   bpl @p2nd
    jsr CrashPass1
    bra @draw
@p2nd:
    jsr CrashPass2
@draw:
    ldx cr_spr
    jsr MapPalette
    ldx cr_spr
    jmp DoSprOrderShadows

;----------------------------------------------------------------------------
; crash_pass1 (ocrash.cpp 1138, source $1EA6): passenger sprites during the
; crash (not flip); sprite = cr_spr
;----------------------------------------------------------------------------
CrashPass1:
    ; frames = (man1 / girl1) + (spin_pass_frame << 3)
    ldx cr_spr
    cpx spr_pass1
    bne @girl
    lda #.loword(SPRITE_CRASH_MAN1)
    sta cr_base
    lda #.hiword(SPRITE_CRASH_MAN1)
    sta cr_base+2
    bra @fr
@girl:
    lda #.loword(SPRITE_CRASH_GIRL1)
    sta cr_base
    lda #.hiword(SPRITE_CRASH_GIRL1)
    sta cr_base+2
@fr:
    lda spin_pass_frame
    jsr PtIdx8
    lda #$1FE               ; priority if props & BIT_0
    ldy #$1FD               ; otherwise
    jmp PassFrame

;----------------------------------------------------------------------------
; crash_pass2 (ocrash.cpp 1175, source $1F26): passenger animations after
; the crash (car stationary); sprite = cr_spr
;----------------------------------------------------------------------------
CrashPass2:
    ldx cr_spr
    cpx spr_pass1
    bne @girl
    lda #.loword(SPRITE_CRASH_MAN2)
    sta cr_pt
    lda #.hiword(SPRITE_CRASH_MAN2)
    sta cr_pt+2
    bra @fr
@girl:
    lda #.loword(SPRITE_CRASH_GIRL2)
    sta cr_pt
    lda #.hiword(SPRITE_CRASH_GIRL2)
    sta cr_pt+2
@fr:
    ; frames += ((coll_count2 & 3) << 4) + (crash_delay & 8): coll_count2
    ; selects the animation, crash_delay toggles between two frames
    lda coll_count2
    and #3
    asl a
    asl a
    asl a
    asl a
    sta cr_t
    lda crash_delay
    and #8
    clc
    adc cr_t
    clc
    adc cr_pt
    sta cr_pt
    lda cr_pt+2
    adc #0
    sta cr_pt+2
    lda #$1FF               ; priority if props & BIT_0
    ldy #$1FE               ; otherwise
    jsr PassFrame
    ; x / y offsets of the man / woman frames
    lda spin_pass_frame
    asl a
    tay
    ldx cr_spr
    cpx spr_pass1
    bne @woman
    tyx
    lda f:XyOffMan,x
    bra @add
@woman:
    tyx
    lda f:XyOffWoman,x
@add:
    sta cr_t
    jsr Sext8               ; x offset
    ldx cr_spr
    clc
    ADCE OE_X
    STE OE_X
    lda cr_t
    xba
    jsr Sext8               ; y offset
    ldx cr_spr
    clc
    ADCE OE_Y
    STE OE_Y
    rts

; PassFrame: common part of crash_pass1 / crash_pass2: sprite cr_spr from
; the frame at cr_pt; A = priority if props & BIT_0, Y = priority otherwise
PassFrame:
    sta cr_pa
    sty cr_pb
    ldx cr_spr
    jsr PtAddr              ; addr = read32(frames)
    ldy #4
    jsr PtByte
    sta cr_props            ; props
    ldy #5
    jsr PtByte
    ldx cr_spr
    STE OE_PAL_SRC
    ; x = spr_ferrari->x + (int8_t) read8(6 + frames)
    ldy #6
    jsr PtByte
    jsr Sext8
    ldx spr_ferrari
    clc
    ADCE OE_X
    ldx cr_spr
    STE OE_X
    ; y = spr_ferrari->y + (int8_t) read8(7 + frames)
    ldy #7
    jsr PtByte
    jsr Sext8
    ldx spr_ferrari
    clc
    ADCE OE_Y
    ldx cr_spr
    STE OE_Y
    ; h-flip
    lda cr_props
    and #$80
    jsr HflipA
    ; priority (higher if props & BIT_0)
    lda cr_props
    and #1
    beq @lo
    lda cr_pa
    bra @pr
@lo:
    lda cr_pb
@pr:
    ldx cr_spr
    STE OE_ROAD_PRIORITY
    STE OE_PRIORITY
    lda #$7E
    STEB OE_ZOOM
    rts

;----------------------------------------------------------------------------
; crash_pass_flip (ocrash.cpp 1262, source $1FDE): passenger animation
; during the car flip; X = sprite
;----------------------------------------------------------------------------
CrashPassFlip:
    stx cr_spr
    lda #0
    STE OE_RELOAD           ; clear passenger flip control
    STE OE_XW1
    ldx spr_ferrari
    LDE OE_X
    ldx cr_spr
    STE OE_X
    lda crash_spin_count
    STE OE_TRAFFIC_SPEED
    lda #$1FE
    STE OE_COUNTER          ; sprite zoom
    ; address of the animation sequence: male / female
    cpx spr_pass1
    bne @girl
    lda #.loword(SPRITE_CRASH_FLIP_MAN1)
    STE OE_Z
    lda #.hiword(SPRITE_CRASH_FLIP_MAN1)
    STE OE_Z+2
    jmp FlipStart
@girl:
    lda #.loword(SPRITE_CRASH_FLIP_GIRL1)
    STE OE_Z
    lda #.hiword(SPRITE_CRASH_FLIP_GIRL1)
    STE OE_Z+2
    jmp FlipStart

;----------------------------------------------------------------------------
; flip_start (ocrash.cpp 1278, source $201A): X = sprite
;----------------------------------------------------------------------------
FlipStart:
    stx cr_spr
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq @sw
    cmp #GS_INGAME
    beq @sw
    jsr DoSprOrderShadows   ; (X = sprite)
    ldx cr_spr
    jmp Done
@sw:
    ; passenger flip control
    LDE OE_RELOAD
    and #3
    beq @flip
    cmp #1
    beq @situp
    jmp PassTurnhead        ; 2, 3: turn head and look at the car
@flip:
    jmp PassFlip            ; 0: flip passengers out of the car
@situp:
    jmp PassSitup           ; 1: sit up on the road after the crash

;----------------------------------------------------------------------------
; pass_flip (ocrash.cpp 1309, source $2066): flip passengers out of the
; car; sprite = cr_spr
;----------------------------------------------------------------------------
PassFlip:
    ldx cr_spr
    lda crash_speed
    bne @slow
    ; fast crash
    lda crash_zinc
    asl a
    asl a
    clc
    ADCE OE_COUNTER
    STE OE_COUNTER
    cmp #$400
    bcc @zoom               ; counter > 0x3FF (uint16)?
    lda #1
    STE OE_RELOAD           ; passengers sit up on the road after the crash
    ; disable sprite and shadow
    jsr DisableX
    ldx cr_spr
    cpx spr_pass1
    bne @s2
    ldx spr_pass1s
    jmp DisableX
@s2:
    ldx spr_pass2s
    jmp DisableX
@slow:
    ; slow crash: zinc = crash_zinc >> 2; the woman moves more
    lda crash_zinc
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    sta cr_t
    cpx spr_pass2
    bne @sub
    cmp #$8000
    ror a
    clc
    adc cr_t
    sta cr_t                ; zinc += zinc >> 1
@sub:
    LDE OE_COUNTER
    sec
    sbc cr_t
    STE OE_COUNTER
@zoom:
    ; set_z_lookup: zoom = counter >> 2, at least 0x40
    LDE OE_COUNTER
    lsr a
    lsr a
    cmp #$40
    bcs :+
    lda #$40
:   STEB OE_ZOOM
    ; frames = sprite->z + (sprite->xw1 << 3)
    LDE OE_Z
    sta cr_base
    LDE OE_Z+2
    sta cr_base+2
    LDE OE_XW1
    jsr PtIdx8
    ldx cr_spr
    jsr PtAddr
    ; offset = min(counter, 0x1FF)
    ldx cr_spr
    LDE OE_COUNTER
    cmp #$200
    bcc :+
    lda #$1FF
:   sta cr_u
    ; y_change = ((int8_t) read8(6 + frames) * offset) >> 9
    ldy #6
    jsr PtByte
    jsr Sext8
    ldx cr_u
    jsr SMul16
    jsr Mres9
    sta cr_t
    lda cr_u
    jsr RoadY223
    sec
    sbc cr_t
    ldx cr_spr
    STE OE_Y
    ; 2138
    lda cr_u
    STE OE_PRIORITY
    lda crash_side
    jsr HflipA
    ldy #4
    jsr PtByte
    ldx cr_spr
    STE OE_PAL_SRC
    ; decrement the spin count; next passenger frame for the first spins
    LDE OE_TRAFFIC_SPEED
    dec a
    STE OE_TRAFFIC_SPEED
    beq @next
    bmi @next
    bra @setx
@next:
    lda crash_spin_count
    STE OE_TRAFFIC_SPEED
    LDE OE_XW1
    inc a
    STE OE_XW1              ; next passenger frame
    ldy #7
    jsr PtByte
    and #$80
    beq @setx
    ; end of the sequence: next sequence of animations (sit up)
    ldx cr_spr
    lda #1
    STE OE_RELOAD
    lda #0
    STE OE_XW1
    cpx spr_pass1
    bne @g2
    lda #.loword(SPRITE_CRASH_FLIP_MAN2)
    ldy #.hiword(SPRITE_CRASH_FLIP_MAN2)
    bra @z2
@g2:
    lda #.loword(SPRITE_CRASH_FLIP_GIRL2)
    ldy #.hiword(SPRITE_CRASH_FLIP_GIRL2)
@z2:
    STE OE_Z
    sta cr_pt
    tya
    STE OE_Z+2
    sta cr_pt+2             ; frames = sprite->z
    ; frame delay of this sequence from the lower bits
    ldy #7
    jsr PtByte
    and #$7F
    ldx cr_spr
    STE OE_TRAFFIC_SPEED
    jmp Done
@setx:
    ; set_passenger_x
    ldy #5
    jsr PtByte
    jsr Sext8
    ldx spr_ferrari
    clc
    ADCE OE_X
    ldx cr_spr
    STE OE_X
    jmp Done

;----------------------------------------------------------------------------
; pass_situp (ocrash.cpp 1400, source $205A): passengers sit up on the
; road after the crash; sprite = cr_spr
;----------------------------------------------------------------------------
PassSitup:
    jsr PassXDiff
    jsr PassFrameAddr
    ; decrement the frame delay counter
    ldx cr_spr
    LDE OE_TRAFFIC_SPEED
    dec a
    STE OE_TRAFFIC_SPEED
    beq @exp
    bmi @exp
    bra @done
@exp:
    ldy #$F
    jsr PtByte
    and #$7F
    ldx cr_spr
    STE OE_TRAFFIC_SPEED
    ldy #7
    jsr PtByte
    and #$80
    beq @next
    ; end of the sequence: turn head and look at the car
    lda #2
    ldx cr_spr
    STE OE_RELOAD
    bra @done
@next:
    ldx cr_spr
    LDE OE_XW1
    inc a
    STE OE_XW1              ; next passenger frame
    lda crash_state
    cmp #6
    bne @done
    lda #2
    STE OE_RELOAD           ; camera pan: make the passengers turn heads
@done:
    ldx cr_spr
    jmp Done

;----------------------------------------------------------------------------
; pass_turnhead (ocrash.cpp 1434, source $222C): passengers turn their
; heads and look at the car (only if camera pan); sprite = cr_spr
;----------------------------------------------------------------------------
PassTurnhead:
    jsr PassXDiff
    jsr PassFrameAddr
    ; end of the animation sequence?
    ldy #7
    jsr PtByte
    and #$80
    bne @done
    ; decrement the frame delay counter
    ldx cr_spr
    LDE OE_TRAFFIC_SPEED
    dec a
    STE OE_TRAFFIC_SPEED
    beq @exp
    bmi @exp
    bra @done
@exp:
    ldy #$F
    jsr PtByte
    and #$7F
    ldx cr_spr
    STE OE_TRAFFIC_SPEED
    LDE OE_XW1
    inc a
    STE OE_XW1              ; next passenger frame
@done:
    ldx cr_spr
    jmp Done

; PassXDiff: sprite cr_spr: x += (int16)((car_x_diff * counter) >> 9)
PassXDiff:
    ldx cr_spr
    LDE OE_COUNTER
    tax
    lda car_x_diff
    jsr MulSU
    jsr Mres9
    ldx cr_spr
    clc
    ADCE OE_X
    STE OE_X
    rts

; PassFrameAddr: sprite cr_spr: frames (cr_pt) = z + (xw1 << 3);
; addr = read32(frames), pal_src = read8(4 + frames)
PassFrameAddr:
    ldx cr_spr
    LDE OE_Z
    sta cr_base
    LDE OE_Z+2
    sta cr_base+2
    LDE OE_XW1
    jsr PtIdx8
    ldx cr_spr
    jsr PtAddr
    ldy #4
    jsr PtByte
    ldx cr_spr
    STE OE_PAL_SRC
    rts

;============================================================================
; helpers
;============================================================================
; PtAddrFrame: cr_pt = addr + (frame << 3)
PtAddrFrame:
    lda addr
    sta cr_base
    lda addr+2
    sta cr_base+2
    lda frame
    ; fall into PtIdx8

; PtIdx8: cr_pt = cr_base + (A << 3), A = int16 (sign-extended: the C++
; int arithmetic on a uint32 / int32 base)
PtIdx8:
    ldy #0
    cmp #$8000
    bcc :+
    dey
:   sty cr_t+2
    asl a
    rol cr_t+2
    asl a
    rol cr_t+2
    asl a
    rol cr_t+2
    clc
    adc cr_base
    sta cr_pt
    lda cr_t+2
    adc cr_base+2
    sta cr_pt+2
    rts

; PtSet: rp0 -> the rom0 byte at cr_pt
PtSet:
    lda cr_pt
    ldy cr_pt+2
    jmp R0Set

; PtByte: Y = offset -> A = rom0.read8(cr_pt + Y) (Z set when 0)
PtByte:
    phy
    jsr PtSet
    ply
    lda [rp0],y
    and #$00FF
    rts

; PtAddr: X = entry: entry->addr = rom0.read32(cr_pt)
PtAddr:
    phx
    jsr PtSet
    plx
    lda [rp0]
    xba
    STE OE_ADDR+2
    ldy #2
    lda [rp0],y
    xba
    STE OE_ADDR
    rts

; HflipA: X = entry: A != 0 -> control |= HFLIP, else control &= ~HFLIP
HflipA:
    tay
    LDEB OE_CONTROL
    and #$FFFF-C_HFLIP
    cpy #0
    beq :+
    ora #C_HFLIP
:   STEB OE_CONTROL
    rts

; EnableX / DisableX: X = entry: control |= / &= ~ENABLE
EnableX:
    LDEB OE_CONTROL
    ora #C_ENABLE
    STEB OE_CONTROL
    rts
DisableX:
    LDEB OE_CONTROL
    and #$FFFF-C_ENABLE
    STEB OE_CONTROL
    rts

; Sext8: A = byte -> (int8_t) sign-extended (flags from the result)
Sext8:
    and #$00FF
    eor #$0080
    sec
    sbc #$0080
    rts

; Mres9: A = (int32 mres >> 9) truncated to 16 bits
Mres9:
    sep #$20
    .a8
    lda mres+3
    lsr a
    rep #$20
    .a16
    lda mres+1
    ror a
    rts

; MulSU: mres = A (int16) * X (uint16), exact 32-bit product
MulSU:
    sta cr_ms
    stx cr_ms+2
    jsr SMul16
    lda cr_ms+2
    bpl :+
    lda mres+2
    clc
    adc cr_ms
    sta mres+2
:   rts

; RoadY223: A = index (int16) -> A = -(road_y[road_p0 + index] >> 4) + 223
; (road_p0 is a byte offset)
RoadY223:
    asl a
    clc
    adc road_p0
    tax
    lda f:RDB*$10000+RD_Y,x
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
    adc #223
    rts

.segment "RODATA"
; crash_pass2 XY_OFF (int8 x, y per spin_pass_frame)
XyOffMan:
    .lobytes -$C, -$1E,  $2, -$1B,  $4, -$1A,  $5, -$1E
    .lobytes $11, -$1B,  $0, -$1A, -$1, -$1B, -$C, -$1C
    .lobytes -$E, -$1B, -$E, -$1C, -$E, -$1D, -$C, -$1B
    .lobytes -$C, -$1C, -$C, -$1D
XyOffWoman:
    .lobytes $A, -$1A,  $0, -$1B, -$F, -$1B, -$15, -$1B
    .lobytes -$2, -$1E, $7, -$1A, $13, -$1D,  $9, -$1B
    .lobytes $3, -$1B,  $3, -$1C,  $3, -$1D,  $7, -$1B
    .lobytes $7, -$1C,  $7, -$1D
.endif
