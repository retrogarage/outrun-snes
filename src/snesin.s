; SNES input adapter for the engine port: CannonBall's Input class
; (keys[] / keys_old[], is_pressed, has_pressed, is_pressed_clear) fed by
; joypad 1. Mapping: D-pad = LEFT/RIGHT/UP/DOWN, B = ACCEL, A = BRAKE,
; Y / L / R = GEAR1 (gear toggle, GEAR_BUTTON mode), X = GEAR2,
; START = START, SELECT unused (console freeplay).
;
; LOCKSTEP / LSINPUT builds read the keys from the scripted input table instead
; (tools/lockstep.py -> build/gen/lsinput.s, same spans as cbref0 -i).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"

.export InUpdate, InFrameDone, InIsPressed, InHasPressed, InIsPressedClear
.export in_keys, in_keys_old
.ifdef LSINPUT
.import in_tick
.export LsInput, LsStopTick
.segment "RODATA"
; scripted inputs, patched into the ROM by tools/lockstep.py: spans of
; (first tick, end tick (exclusive), key mask), first tick $FFFF = end
LsInput:    .res 6 * 64, $FF
LsStopTick: .word $FFFF
.endif

NKEYS = 11

.segment "BSS"
in_keys:     .res NKEYS + 1     ; bytes 0/1
in_keys_old: .res NKEYS + 1

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; InUpdate: keys[] from the joypad (start of a tick, as apply_inputs)
;----------------------------------------------------------------------------
InUpdate:
    .ifdef LSINPUT
    ; key mask of the spans that contain in_tick
    lda #0
    tay                         ; Y = mask
    ldx #0
@span:
    lda f:LsInput,x             ; first tick ($FFFF = end)
    cmp #$FFFF
    beq @spd
    lda in_tick
    cmp f:LsInput,x
    bcc @spn
    cmp f:LsInput+2,x
    bcs @spn
    tya
    ora f:LsInput+4,x
    tay
@spn:
    txa
    clc
    adc #6
    tax
    bra @span
@spd:
    tya
    ldx #0
@bit:
    lsr a
    pha
    lda #0
    rol a
    sep #$20
    .a8
    sta in_keys,x
    rep #$20
    .a16
    pla
    inx
    cpx #NKEYS
    bne @bit
    rts
    .else
    ldx #0
    ldy #0
@key:
    .import cfg_masks
    cpx #IN_ACCEL
    bcc @fixed
    cpx #IN_GEAR2
    bcs @fixed
    phy
    tya
    sec
    sbc #IN_ACCEL*2
    tay
    lda cfg_masks,y
    ply
    bra @mask
@fixed:
    lda KeyMask,y
@mask:
    and SH_JOY
    beq :+
    lda #1
:   sep #$20
    .a8
    sta in_keys,x
    rep #$20
    .a16
    iny
    iny
    inx
    cpx #NKEYS
    bne @key
    rts
    .endif

;----------------------------------------------------------------------------
; InFrameDone: keys_old = keys (end of a tick, input.frame_done)
;----------------------------------------------------------------------------
InFrameDone:
    ldx #0
:   lda in_keys,x
    sta in_keys_old,x
    inx
    inx
    cpx #NKEYS + 1
    bcc :-
    rts

;----------------------------------------------------------------------------
; A = key -> A = 0/1 (Z set when 0)
;----------------------------------------------------------------------------
InIsPressed:
    tax
    lda in_keys,x
    and #$00FF
    rts

InHasPressed:
    tax
    lda in_keys_old,x
    and #$00FF
    bne @no
    lda in_keys,x
    and #$00FF
    rts
@no:
    lda #0
    rts

InIsPressedClear:
    tax
    lda in_keys,x
    and #$00FF
    beq :+
    sep #$20
    .a8
    stz in_keys,x
    rep #$20
    .a16
    lda #1
:   rts

.segment "RODATA"
; joypad bits per key (bank 0, read with DB = 0) (SH_JOY = JOY1L/H: B Y Sel St U D L R | A X L R)
KeyMask:
    .word $0200                 ; LEFT
    .word $0100                 ; RIGHT
    .word $0800                 ; UP
    .word $0400                 ; DOWN
    .word $8000                 ; ACCEL  (B)
    .word $0080                 ; BRAKE  (A, beside B)
    .word $4000 | $0020 | $0010 ; GEAR1  (Y, L, R)
    .word $0040                 ; GEAR2  (X)
    .word $1000                 ; START
    .word $0000                 ; COIN   (unused)
    .word $0000                 ; VIEWPOINT
.endif
