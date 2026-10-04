; OInputs: player controls - port of the original CannonBall engine
; (engine/oinputs.cpp, classic arcade) for the digital pad:
; config.controls.analog = 0, gear = GEAR_BUTTON, steer_speed = 3,
; pedal_speed = 4.  Digital steering / pedal ramps simulating the analog
; controls, the gear button, the arcade's analogue adjust (source $74E2)
; and the coin input (source $6DE0).  Analog / rumble / haptic / smartypi
; paths and the menu helpers is_analog_l/r/select (not classic) omitted.
;
; ostats.credits is read as the low byte and written with an 8-bit store
; (right whether ostats keeps a byte or a word with a zero high byte).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import InIsPressed, InHasPressed, SndQueueSound, SDiv16u
.import crash_counter, credits

.export InputsInit, InputsTick, InputsDoGear, InputsAdjust, InputsDoCredits
.export crash_input, input_acc, input_steering, steering_adjust
.export acc_adjust, brake_adjust, gear
.export steering_inc, acc_inc, brake_inc, delay1, delay2, delay3
.export coin1, coin2, steering_old, steering_change, input_brake, InputsWheelRead

STEERING_MIN    = $48
STEERING_MAX    = $B8
STEERING_CENTRE = $80
PEDAL_MIN       = $30
PEDAL_MAX       = $90
STEER_SPEED     = 3             ; config.controls.steer_speed
PEDAL_SPEED     = 4             ; config.controls.pedal_speed

.segment "BSS"
crash_input:     .res 2         ; int8 (sign-extended word)
input_acc:       .res 2         ; int16 acceleration input
input_steering:  .res 2         ; int16 steering input
steering_adjust: .res 2         ; int16 processed / adjusted values
acc_adjust:      .res 2         ; int16
brake_adjust:    .res 2         ; int16
gear:            .res 2         ; bool: 1 high gear
steering_inc:    .res 2         ; uint8 steering change per tick
acc_inc:         .res 2         ; uint8
brake_inc:       .res 2         ; uint8
delay1:          .res 4         ; int (menu helpers: not used by the classic game)
delay2:          .res 4
delay3:          .res 4
coin1:           .res 2         ; bool: coin chutes (CannonBoard only)
coin2:           .res 2
steering_old:    .res 2         ; int16
steering_change: .res 2         ; int16
input_brake:     .res 2         ; int16
in_t:            .res 2

.segment "SA1CODE"
.a16
.i16

;============================================================================
; init (oinputs.cpp 27)
;============================================================================
InputsInit:
    lda #STEERING_CENTRE
    sta input_steering
    sta steering_old
    stz steering_adjust
    stz acc_adjust
    stz brake_adjust
    stz steering_change
    lda #STEER_SPEED
    sta steering_inc
    lda #PEDAL_SPEED * 4
    sta acc_inc
    sta brake_inc
    stz input_acc
    stz input_brake
    stz gear
    stz crash_input
    stz delay1
    stz delay1+2
    stz delay2
    stz delay2+2
    stz delay3
    stz delay3+2
    stz coin1
    stz coin2
    rts

;============================================================================
; tick (oinputs.cpp 51): digital controls (input.analog = 0), simulate analog
;============================================================================
InputsTick:
    jsr DigitalSteering
    jmp DigitalPedals

;----------------------------------------------------------------------------
; digital_steering (oinputs.cpp 78)
;----------------------------------------------------------------------------
DigitalSteering:
    lda #IN_LEFT
    jsr InIsPressed
    beq @right
    ; recentre the wheel immediately if facing the other way
    lda input_steering          ; input_steering > CENTRE
    sec
    sbc #STEERING_CENTRE+1
    bvc :+
    eor #$8000
:   bmi :+
    lda #STEERING_CENTRE
    sta input_steering
:   lda input_steering
    sec
    sbc steering_inc
    sta input_steering
    sec                         ; input_steering < MIN
    sbc #STEERING_MIN
    bvc :+
    eor #$8000
:   bpl @done
    lda #STEERING_MIN
    sta input_steering
    rts
@right:
    lda #IN_RIGHT
    jsr InIsPressed
    beq @centre
    lda input_steering          ; input_steering < CENTRE
    sec
    sbc #STEERING_CENTRE
    bvc :+
    eor #$8000
:   bpl :+
    lda #STEERING_CENTRE
    sta input_steering
:   lda input_steering
    clc
    adc steering_inc
    sta input_steering
    sec                         ; input_steering > MAX
    sbc #STEERING_MAX+1
    bvc :+
    eor #$8000
:   bmi @done
    lda #STEERING_MAX
    sta input_steering
@done:
    rts
@centre:
    ; return the steering to the centre if nothing is pressed
    lda input_steering
    cmp #STEERING_CENTRE
    beq @done
    sec
    sbc #STEERING_CENTRE
    bvc :+
    eor #$8000
:   bpl @gt
    lda input_steering          ; < CENTRE
    clc
    adc steering_inc
    sta input_steering
    sec                         ; > CENTRE
    sbc #STEERING_CENTRE+1
    bvc :+
    eor #$8000
:   bmi @done
    lda #STEERING_CENTRE
    sta input_steering
    rts
@gt:
    lda input_steering          ; > CENTRE
    sec
    sbc steering_inc
    sta input_steering
    sec                         ; < CENTRE
    sbc #STEERING_CENTRE
    bvc :+
    eor #$8000
:   bpl @done
    lda #STEERING_CENTRE
    sta input_steering
    rts

;----------------------------------------------------------------------------
; digital_pedals (oinputs.cpp 118)
;----------------------------------------------------------------------------
DigitalPedals:
    ; acceleration
    lda #IN_ACCEL
    jsr InIsPressed
    beq @accoff
    lda input_acc
    clc
    adc acc_inc
    sta input_acc
    sec                         ; input_acc > $FF
    sbc #$0100
    bvc :+
    eor #$8000
:   bmi @brake
    lda #$00FF
    sta input_acc
    bra @brake
@accoff:
    lda input_acc
    sec
    sbc acc_inc
    sta input_acc
    bpl @brake                  ; input_acc < 0 (int16)
    stz input_acc
@brake:
    ; brake
    lda #IN_BRAKE
    jsr InIsPressed
    beq @brakeoff
    lda input_brake
    clc
    adc brake_inc
    sta input_brake
    sec                         ; input_brake > $FF
    sbc #$0100
    bvc :+
    eor #$8000
:   bmi @done
    lda #$00FF
    sta input_brake
    rts
@brakeoff:
    lda input_brake
    sec
    sbc brake_inc
    sta input_brake
    bpl @done                   ; input_brake < 0 (int16)
    stz input_brake
@done:
    rts

;============================================================================
; do_gear (oinputs.cpp 151): GEAR_BUTTON - the gear button toggles the gear
;============================================================================
InputsDoGear:
    lda #IN_GEAR1
    jsr InHasPressed
    beq @done
    lda gear                    ; gear = !gear
    and #$00FF
    beq :+
    stz gear
    rts
:   lda #1
    sta gear
@done:
    rts

;============================================================================
; adjust_inputs (oinputs.cpp 192, source $74E2)
;============================================================================
InputsAdjust:
    ; cap the steering value
    lda input_steering          ; < MIN
    sec
    sbc #STEERING_MIN
    bvc :+
    eor #$8000
:   bpl :+
    lda #STEERING_MIN
    sta input_steering
    bra @crash
:   lda input_steering          ; > MAX
    sec
    sbc #STEERING_MAX+1
    bvc :+
    eor #$8000
:   bmi @crash
    lda #STEERING_MAX
    sta input_steering
@crash:
    lda crash_input             ; int8 crash_input != 0
    and #$00FF
    beq @nocrash
    dec a                       ; crash_input-- (int8)
    eor #$0080
    sec
    sbc #$0080
    sta crash_input
    jsr SteerConv
    ldx crash_counter
    beq :+
    lda #0
:   sta steering_adjust
    bra @pedals
@nocrash:
    ; no_crash1
    lda input_steering          ; d0 = input_steering - steering_old (int16)
    sec
    sbc steering_old
    tax
    lda input_steering
    sta steering_old
    txa
    clc
    adc steering_change         ; steering_change += d0 (int16)
    sta steering_change
    bpl :+                      ; d0 = |steering_change| (int16)
    eor #$FFFF
    inc a
:   sec                         ; d0 > 2 (fix_bugs = 0)
    sbc #3
    bvc :+
    eor #$8000
:   bmi @pedals
    stz steering_change
    jsr SteerConv               ; convert input steering to the internal value
    ldx crash_counter
    beq :+
    lda #0
:   sta steering_adjust
@pedals:
    ; cap and adjust the acceleration and brake values
    lda input_acc
    jsr PedalConv
    sta acc_adjust
    lda input_brake
    jsr PedalConv
    sta brake_adjust
    rts

; InputsWheelRead: steering_adjust from the wheel as it is now.  The arcade
; only re-reads the wheel after it moved (adjust_inputs: |change| > 2); a
; real wheel at rest does that through its analog noise, the digital pad
; never does, so the attract AI's last steering would stay in force through
; the music select (wrong track shown) and into the race (the car drifts).
; Called when a game starts (MusicEnable).
InputsWheelRead:
    stz steering_change
    lda input_steering
    sta steering_old
    jsr SteerConv
    sta steering_adjust
    rts

; SteerConv: A = ((input_steering - $80) * $100) / $70 (int, truncating),
; capped to +-$7F (input_steering is within MIN-MAX: |dividend| <= $3800)
SteerConv:
    lda input_steering
    sec
    sbc #STEERING_CENTRE
    bmi @neg
    xba                         ; * $100
    ldx #$70
    jsr SDiv16u
    bra @cap
@neg:
    eor #$FFFF                  ; truncate toward zero: -(-n / $70)
    inc a
    xba
    ldx #$70
    jsr SDiv16u
    eor #$FFFF
    inc a
@cap:
    sta in_t
    sec                         ; d0 > $7F
    sbc #$0080
    bvc :+
    eor #$8000
:   bmi :+
    lda #$007F
    rts
:   lda in_t                    ; d0 < -$7F
    sec
    sbc #$FF81
    bvc :+
    eor #$8000
:   bpl :+
    lda #$FF81
    rts
:   lda in_t
    rts

; PedalConv: A = pedal (int16) -> ((cap(A, PEDAL_MIN, PEDAL_MAX) - $30)
; * $100) / $61
PedalConv:
    sta in_t
    sec                         ; > PEDAL_MAX
    sbc #PEDAL_MAX+1
    bvc :+
    eor #$8000
:   bmi :+
    lda #PEDAL_MAX
    bra @conv
:   lda in_t                    ; < PEDAL_MIN
    sec
    sbc #PEDAL_MIN
    bvc :+
    eor #$8000
:   bpl :+
    lda #PEDAL_MIN
    bra @conv
:   lda in_t
@conv:
    sec
    sbc #$30                    ; 0-$60
    xba                         ; * $100 (<= $6000: non-negative)
    ldx #$61
    jmp SDiv16u

;============================================================================
; do_credits (oinputs.cpp 250, source $6DE0) -> A = 0 no coin, 1 coin chute
; 1, 2 coin chute 2, 3 key pressed / service button
;============================================================================
InputsDoCredits:
    .ifndef LOCKSTEP
    ; Console build: Start grants the freeplay token; coins are unused.
    lda #0
    rts
    .else
    lda #IN_COIN
    jsr InHasPressed
    beq @chute1
    jsr AddCredit
    lda #3
    rts
@chute1:
    lda coin1
    and #$00FF
    beq @chute2
    stz coin1
    jsr AddCredit
    lda #1
    rts
@chute2:
    lda coin2
    and #$00FF
    beq @none
    stz coin2
    jsr AddCredit
    lda #2
    rts
@none:
    lda #0
    rts

; AddCredit: (freeplay = 0) ostats.credits < 9: credits++, coin in sound
AddCredit:
    lda credits
    and #$00FF
    cmp #9
    bcs @done
    inc a
    sep #$20
    .a8
    sta credits
    rep #$20
    .a16
    lda #S_COIN_IN
    jmp SndQueueSound
@done:
    rts
    .endif
.endif
