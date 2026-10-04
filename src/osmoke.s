; OSmoke: smoke & spray control - port of the original CannonBall engine
; engine/osmoke.cpp (classic arcade): animates the smoke / spray sprites
; (SPRITE_SMOKE1 / SPRITE_SMOKE2) below the Ferrari's wheels.
;
; Animation data format for smoke / spray (8-byte frames):
;   [+0] long: sprite data address   [+4] byte: z (zoom) of the smoke
;   [+5] byte: palette               [+6] byte: x (bits 4-7) / y (bits 0-3)
;   [+7] byte: bit 0 h-flip, bit 1 zoom shift, bits 4-7 priority change
;
; oferrari.spr_ferrari = entry SPRITE_FERRARI, ocrash.spr_ferrari = entry
; SPRITE_CRASH (fixed slots).  oroad.get_view_mode() is always
; VIEW_ORIGINAL: the in-car view tests fold.
; Note: EOFS() must be the LAST term of an expression (ca65 C-style macro
; arguments extend to the end: JT+EOFS(i)+OE_X = JT+(i+OE_X)*64).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import MapPalette, DoSprOrderShadows, R0Set, SMul16
.importzp rp0, mres
.import RD_Y
.importzp RDB
.import game_state
.import crash_counter, crash_z, crash_state, crash_spin_count
.import car_state, wheel_state, is_slipping, revs
.import car_increment
.import spray_counter, spray_type
.import road_p0, stage_lookup_off

.export SmokeInit, SmokeDrawFerrari, SmokeSetup, SmokeDraw, load_smoke_data

; OFerrari (1-byte variables are words: compared on the low byte)
CAR_ANIM_SEQ_B   = $FF      ; int8 -1
CAR_NORMAL       = 0
CAR_SMOKE        = 1
WHEELS_ON        = 0
WHEELS_LEFT_OFF  = 1
WHEELS_RIGHT_OFF = 2
WHEELS_OFF       = 3

.segment "BSS"
load_smoke_data:    .res 2  ; int8 (word)
smoke_type_onroad:  .res 2  ; uint16
smoke_type_offroad: .res 2  ; uint16
smoke_type_slip:    .res 2  ; uint16
; scratch
sm_spr:     .res 2          ; oentry* sprite
sm_ctrl:    .res 2          ; tick_smoke_anim: anim_ctrl
sm_adr:     .res 4          ; tick_smoke_anim: addr (rom0)
sm_pt:      .res 4          ; addr + frame
sm_t:       .res 2
sm_z:       .res 2          ; smoke_z
sm_zoom:    .res 2          ; zoom
sm_x:       .res 2          ; x
sm_hf:      .res 2          ; hflip

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; init (osmoke.cpp 25)
;----------------------------------------------------------------------------
SmokeInit:
    stz load_smoke_data
    rts

;----------------------------------------------------------------------------
; draw_ferrari_smoke (osmoke.cpp 49, source $A816): X = sprite (called
; once for each plume of smoke)
;----------------------------------------------------------------------------
SmokeDrawFerrari:
    stx sm_spr
    lda #0
    jsr SmokeSetup          ; setup_smoke_sprite(false)
    ; game state: attract, or GS_START1 <= state < GS_INIT_GAMEOVER (int8)
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq @st
    cmp #GS_START1
    bcc @ret
    cmp #GS_INIT_GAMEOVER
    bcs @ret
@st:
    lda crash_counter
    beq @spray
    lda crash_z
    beq @ret
@spray:
    ; spray from water: more violent than the offroad wheel stuff
    lda spray_counter
    beq @slip
    lda spray_type
    clc
    adc #.loword(SPRAY_DATA)
    ldy #.hiword(SPRAY_DATA)
    bcc :+
    iny
:   jsr ReadAdr
    lda #1
    jmp TickSmokeAnim
@ret:
    rts
@slip:
    ; (enhancement: in-car view without flip returns - never in VIEW_ORIGINAL)
    ; car slipping / skidding
    lda is_slipping
    beq @offroad
    lda wheel_state
    and #$00FF
    bne @offroad            ; (WHEELS_ON)
    lda smoke_type_slip
    jsr SmokeAdr
    lda #0
    jmp TickSmokeAnim
@offroad:
    ; wheels offroad
    lda wheel_state
    and #$00FF
    beq @onroad
    lda smoke_type_offroad
    jsr SmokeAdr            ; smoke_adr
    ; left wheel only
    lda wheel_state
    and #$00FF
    sta sm_t
    ldx sm_spr
    cpx #EOFS(SPRITE_SMOKE2)
    bne @rw
    cmp #WHEELS_LEFT_OFF
    beq @tick1
@rw:
    ; right wheel only
    cpx #EOFS(SPRITE_SMOKE1)
    bne @both
    lda sm_t
    cmp #WHEELS_RIGHT_OFF
    beq @tick1
@both:
    ; both wheels
    lda sm_t
    cmp #WHEELS_OFF
    beq @tick1
    rts
@onroad:
    ; test_crash_intro
    lda car_state
    and #$00FF
    cmp #CAR_NORMAL
    bne @csmoke
    ; normal: copy the frame number to type
    ldx sm_spr
    LDE OE_XW1
    STE OE_TYPE
    rts
@csmoke:
    cmp #CAR_SMOKE
    beq @onsmoke            ; smoke from wheels
    ; animation sequence
    lda wheel_state
    and #$00FF
    beq @onsmoke            ; (WHEELS_ON)
    ldx sm_spr
    LDE OE_XW1
    STE OE_TYPE             ; copy the frame number to type
    rts
@onsmoke:
    lda smoke_type_onroad
    jsr SmokeAdr
@tick1:
    lda #1
    jmp TickSmokeAnim

; SmokeAdr: A = offset -> sm_adr = rom0.read32(smoke_data + A)
SmokeAdr:
    clc
    adc #.loword(SMOKE_DATA)
    ldy #.hiword(SMOKE_DATA)
    bcc ReadAdr
    iny
    ; fall into ReadAdr

; ReadAdr: A = rom0 address low, Y = high -> sm_adr = rom0.read32(address)
ReadAdr:
    jsr R0Set
    lda [rp0]
    xba
    sta sm_adr+2
    ldy #2
    lda [rp0],y
    xba
    sta sm_adr
    rts

;----------------------------------------------------------------------------
; setup_smoke_sprite (osmoke.cpp 135, source $A94C): A = force_load (bool)
; wheel spray sprite data for the upcoming stage
;----------------------------------------------------------------------------
SmokeSetup:
    ldx #0                  ; stage_lookup = 0 (MODE_ORIGINAL)
    and #$00FF
    bne @load
    ; load new sprite data when transitioning between stages?
    lda load_smoke_data
    tay
    and #$FFFE
    sta load_smoke_data     ; load_smoke_data &= ~BIT_0
    tya
    and #1
    bne @next
    rts                     ; don't load new smoke data
@next:
    lda stage_lookup_off
    clc
    adc #8
    tax                     ; stage_lookup (uint16)
@load:
    ; smoke colour on road
    lda f:OnroadSmoke,x
    and #$00FF
    asl a
    asl a
    sta smoke_type_onroad
    sta smoke_type_slip
    ; smoke colour off road
    lda f:OffroadSmoke,x
    and #$00FF
    asl a
    asl a
    sta smoke_type_offroad
    rts

;----------------------------------------------------------------------------
; tick_smoke_anim (osmoke.cpp 184, source $A9B6): sprite = sm_spr,
; A = anim_ctrl (0: animation speed from the car speed, 1: from the revs),
; sm_adr = addr.  Sets the smoke x, y and z and the animation speed.
;----------------------------------------------------------------------------
TickSmokeAnim:
    sta sm_ctrl
    ldx sm_spr
    lda f:JT+OE_X+EOFS(SPRITE_FERRARI)
    STE OE_X
    lda f:JT+OE_Y+EOFS(SPRITE_FERRARI)
    STE OE_Y
    lda sm_ctrl
    cmp #1
    beq @revs
    jmp @speed
@revs:
    ; use the revs to set the sprite counter reload value
    lda car_state
    and #$00FF
    cmp #CAR_ANIM_SEQ_B
    bne @rv
    lda #$80                ; force smoke during the animation sequence
    bra @rs
@rv:
    lda revs+2              ; revs >> 16 (int16)
    sec
    sbc #$100
    bvc :+
    eor #$8000
:   bmi @rv2
    lda #$FF                ; revs > 0xFF
    bra @rs
@rv2:
    lda revs+2
@rs:
    sta sm_t                ; revs
    ; reload = 3 - (revs >> 6)
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
    cmp #$8000
    ror a
    eor #$FFFF
    sec
    adc #3
    ldx sm_spr
    STE OE_RELOAD
    ; z = revs >> 1 (int32): more revs = smoke emitted further
    lda sm_t
    cmp #$8000
    ror a
    STE OE_Z
    lda #0
    ldy sm_t
    bpl :+
    dec a
:   STE OE_Z+2
    ; crash occurring
    lda crash_counter
    bne @crash
    jmp @stat
@crash:
    lda crash_z
    jsr RoadY223
    ldx sm_spr
    STE OE_Y
    ; trigger smoke cloud: the car is slid to the side, offset the smoke
    lda crash_state
    cmp #4
    bne @zs
    lda f:JT+OE_CONTROL+EOFS(SPRITE_CRASH)
    and #C_HFLIP
    beq @nofl
    cpx #EOFS(SPRITE_SMOKE2)
    bne @fl1
    LDE OE_Y
    sec
    sbc #10
    STE OE_Y
    bra @zs
@fl1:
    LDE OE_X
    sec
    sbc #64
    STE OE_X
    LDE OE_Y
    sec
    sbc #4
    STE OE_Y
    bra @zs
@nofl:
    cpx #EOFS(SPRITE_SMOKE2)
    bne @nf1
    LDE OE_X
    clc
    adc #64
    STE OE_X
    LDE OE_Y
    sec
    sbc #4
    STE OE_Y
    bra @zs
@nf1:
    LDE OE_Y
    sec
    sbc #10
    STE OE_Y
@zs:
    ; z_shift = crash_spin_count - 1 (0 -> 1); z = 0xFF >> z_shift
    lda crash_spin_count
    dec a
    bne :+
    lda #1
:   and #31                 ; (int shift count: mod 32 as on x86 / ARM)
    tay
    lda #$FF
    cpy #0
    beq @zst
@zsh:
    lsr a
    dey
    bne @zsh
@zst:
    ldx sm_spr
    STE OE_Z
    lda #0
    STE OE_Z+2
    bra @stat
@speed:
    ; use the car speed to set the sprite counter reload value
    lda car_increment+2
    cmp #$100
    bcc :+
    lda #$FF
:   lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #7                  ; reload = 7 - (car_inc >> 5)
    ldx sm_spr
    STE OE_RELOAD
    lda #0
    STE OE_Z
    STE OE_Z+2
@stat:
    ; return if stationary and not in the animation sequence
    lda car_state
    and #$00FF
    cmp #CAR_ANIM_SEQ_B
    beq @anim
    lda car_increment+2
    bne @anim
    rts
@anim:
    ; (tick_frame is always true)
    ldx sm_spr
    LDE OE_COUNTER
    beq @reload
    dec a
    STE OE_COUNTER
    bra @setup
@reload:
    lda wheel_state
    and #$00FF
    beq @two
    cmp #WHEELS_OFF
    beq @two
    ; one wheel off road
    LDE OE_RELOAD
    STE OE_COUNTER
    LDE OE_XW1
    inc a
    STE OE_XW1              ; increment frame
    bra @setup
@two:
    ; two wheels on road
    cpx #EOFS(SPRITE_SMOKE1)
    bne @setup
    LDE OE_RELOAD
    STE OE_COUNTER
    sta f:JT+OE_COUNTER+EOFS(SPRITE_SMOKE2)
    LDE OE_XW1
    inc a
    STE OE_XW1              ; increment frame
    sta f:JT+OE_XW1+EOFS(SPRITE_SMOKE2)   ; copy to the second smoke sprite
@setup:
    ; setup_smoke: frame = (xw1 & 7) << 3
    ldx sm_spr
    LDE OE_XW1
    and #7
    asl a
    asl a
    asl a
    clc
    adc sm_adr
    sta sm_pt
    lda sm_adr+2
    adc #0
    sta sm_pt+2
    jsr SmPtSet
    ldx sm_spr
    lda [rp0]
    xba
    STE OE_ADDR+2
    ldy #2
    lda [rp0],y
    xba
    STE OE_ADDR             ; addr = read32(addr + frame)
    ldy #5
    lda [rp0],y
    and #$00FF
    STE OE_PAL_SRC          ; pal_src = read8(addr + frame + 5)
    ; smoke_z = read8(addr + frame + 4) + z (uint16), at most 0xFF
    ldy #4
    lda [rp0],y
    and #$00FF
    clc
    ADCE OE_Z
    cmp #$100
    bcc :+
    lda #$FF
:   sta sm_z
    ; inc_crash_z: include crash_z in the zoom if necessary
    lda crash_counter
    beq @zm
    lda crash_z
    beq @zm
    tax
    lda sm_z
    jsr SMul16
    jsr Mres9
    sta sm_z                ; (smoke_z * crash_z) >> 9
@zm:
    ; sprite zoom
    lda sm_z
    cmp #$41
    bcs :+
    lda #$40
    sta sm_z                ; smoke_z <= 0x40: 0x40
:   jsr SmPtSet
    ldy #7
    lda [rp0],y
    and #2
    lsr a
    tay                     ; shift
    lda sm_z
    cpy #0
    beq :+
    lsr a
:   and #$00FF              ; (uint8) zoom
    cmp #$41
    bcs :+
    lda #$40
:   sta sm_zoom
    ldx sm_spr
    STEB OE_ZOOM
    ; y += ((read8(addr + frame + 6) & 0xF) * zoom) >> 8
    ldy #6
    lda [rp0],y
    and #$000F
    ldx sm_zoom
    jsr SMul16
    lda mres+1
    ldx sm_spr
    clc
    ADCE OE_Y
    STE OE_Y
    ; priority = oferrari.spr_ferrari->priority + ((read8(+7) >> 4) & 0xF)
    jsr SmPtSet
    ldy #7
    lda [rp0],y
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc f:JT+OE_PRIORITY+EOFS(SPRITE_FERRARI)
    ldx sm_spr
    STE OE_PRIORITY
    STE OE_ROAD_PRIORITY
    ; hflip = read8(+7) & 1; x = (read8(+6) >> 3) & 0x1E (int8)
    ldy #7
    lda [rp0],y
    and #1
    sta sm_hf
    ldy #6
    lda [rp0],y
    and #$00FF
    lsr a
    lsr a
    lsr a
    and #$1E
    sta sm_x
    ; (enhancement: in-car view spreads the spray - never in VIEW_ORIGINAL)
    ldx sm_spr
    cpx #EOFS(SPRITE_SMOKE1)
    bne @rhs
    lda #DP_BOTTOM | DP_LEFT
    STEB OE_DRAW_PROPS      ; anchor bottom left
    inc sm_hf               ; hflip++
    bra @xadd
@rhs:
    lda #DP_BOTTOM | DP_RIGHT
    STEB OE_DRAW_PROPS      ; anchor bottom right
    lda sm_x
    eor #$FFFF
    inc a
    sta sm_x                ; x = -x
@xadd:
    ; x += (x * zoom) >> 8 (int)
    lda sm_x
    ldx sm_zoom
    jsr SMul16
    lda mres+1
    ldx sm_spr
    clc
    ADCE OE_X
    STE OE_X
    ; h-flip
    LDEB OE_CONTROL
    and #$FFFF-C_HFLIP
    sta sm_t
    lda sm_hf
    and #1
    ora sm_t                ; (C_HFLIP = bit 0)
    STEB OE_CONTROL
    jsr MapPalette
    ldx sm_spr
    jmp DoSprOrderShadows

; SmPtSet: rp0 -> the rom0 byte at sm_pt
SmPtSet:
    lda sm_pt
    ldy sm_pt+2
    jmp R0Set

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

;----------------------------------------------------------------------------
; draw (osmoke.cpp 347): X = sprite (draw only helper; framerate changes)
;----------------------------------------------------------------------------
SmokeDraw:
    stx sm_spr
    lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    beq @st
    cmp #GS_START1
    bcc @ret
    cmp #GS_INIT_GAMEOVER
    bcs @ret
@st:
    lda crash_counter
    beq @stat
    lda crash_z
    beq @ret
@stat:
    ; return if stationary and not in the animation sequence
    lda car_state
    and #$00FF
    cmp #CAR_ANIM_SEQ_B
    beq @draw
    lda car_increment+2
    beq @ret
@draw:
    ldx sm_spr
    jsr MapPalette
    ldx sm_spr
    jmp DoSprOrderShadows
@ret:
    rts

.segment "RODATA"
; smoke colour on road (stage_lookup: 8 entries per stage)
OnroadSmoke:
    .include "asset_OnroadSmoke.inc"
; smoke colour off road
OffroadSmoke:
    .include "asset_OffroadSmoke.inc"
.endif
