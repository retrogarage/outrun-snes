; osoundint adapter for the engine port: the arcade sound commands
; (sound::* ids, S_* in oaddr.inc) and engine_data[] (engine pitch /
; volume, passing traffic) mapped onto the SNES sound driver interface
; (sndapi.s queue: songs, effects; SND_ENGP / SND_ENGV / SND_TRAFI /
; SND_TRAFP polled by the S-CPU sound service).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"
.include "sound.inc"

.import SndSfx, SndSfxStop, SndMusic, SndStop
.import game_state

.export SndInit, SndReset, SndQueueSound, SndSetEngineData, SndTick
.export has_booted, engine_data

.segment "BSS"
has_booted:  .res 2             ; bool (byte access allowed)
engine_data: .res 8             ; uint8[8]
sp_t:        .res 2

.segment "SA1CODE"
.a16
.i16

;----------------------------------------------------------------------------
; SndInit (osoundint.init) / SndReset
;----------------------------------------------------------------------------
SndInit:
    stz engine_data
    stz engine_data+2
    stz engine_data+4
    stz engine_data+6
SndReset:
    rts

;----------------------------------------------------------------------------
; SndSetEngineData: X = index, A = value (byte)
;----------------------------------------------------------------------------
SndSetEngineData:
    sep #$20
    .a8
    sta engine_data,x
    rep #$20
    .a16
    rts

;----------------------------------------------------------------------------
; SndQueueSound: A = command (queue_sound: attract mode filter, then the
; SNES equivalent)
;----------------------------------------------------------------------------
SndQueueSound:
    and #$00FF
    sta sp_t
    lda has_booted
    and #$00FF
    bne :+
    rts
:   lda game_state
    and #$00FF
    cmp #GS_ATTRACT
    bne @ok
    ; advertise sound on: everything but the music
    lda sp_t
    cmp #S_MUSIC_BREEZE
    beq @x
    cmp #S_MUSIC_MAGICAL
    beq @x
    cmp #S_MUSIC_SPLASH
    beq @x
    cmp #S_MUSIC_LASTWAVE
    beq @x
@ok:
    ldx #0
@find:
    lda f:CmdMap,x
    cmp #$FFFF
    beq @x
    and #$00FF
    cmp sp_t
    beq @hit
    inx
    inx
    bra @find
@hit:
    lda f:CmdMap,x
    xba
    and #$00FF              ; action
    asl a
    tax
    jmp (CmdAct,x)
@x: rts

; actions (A = command)
ActMagical:
    lda #SND_SONG_MAGICAL
    jmp SndMusic
ActBreeze:
    lda #SND_SONG_BREEZE
    jmp SndMusic
ActSplash:
    lda #SND_SONG_SPLASH
    jmp SndMusic
ActLastWave:
    lda #SND_SONG_LASTWAVE
    jmp SndMusic
ActFmReset:                 ; FM_RESET: music off, and new_command():
    jsr SndStop             ; every effect stops
ActNewCmd:                  ; NEW_COMMAND (game over): every effect stops
    lda #$FF
    jmp SndSfxStop
ActCoin:
    lda #SFX_COIN
    jmp SndSfx
ActCheck:
    lda #SFX_CHECKPOINT
    jmp SndSfx
ActSlipOn:
    lda #SFX_SLIP
    jmp SndSfx
ActSlipOff:                 ; STOP_SLIP / STOP_SAFETYZONE: the arcade stops
ActSafeOff:                 ; its PCM_FX3/4 channels, slip or safety zone
    lda #SFX_SLIP
    jsr SndSfxStop
    lda #SFX_SAFETY
    jmp SndSfxStop
ActCheersOn:
    lda #SFX_CHEERS
    jmp SndSfx
ActCheersOff:
    lda #SFX_CHEERS
    jmp SndSfxStop
ActCrash1:
    lda #SFX_CRASH1
    jmp SndSfx
ActCrash2:
    lda #SFX_CRASH2
    jmp SndSfx
ActRebound:
    lda #SFX_REBOUND
    jmp SndSfx
ActSignal1:
    lda #SFX_SIGNAL1
    jmp SndSfx
ActSignal2:
    lda #SFX_SIGNAL2
    jmp SndSfx
ActVCheck:
    lda #SFX_VOICE_CHECKPOINT
    jmp SndSfx
ActVCongrats:
    lda #SFX_VOICE_CONGRATS
    jmp SndSfx
ActVReady:
    lda #SFX_VOICE_GETREADY
    jmp SndSfx
ActSafeOn:
    lda #SFX_SAFETY
    jmp SndSfx
ActNone:
    rts

CmdAct:
    .word ActNone, ActNone, ActFmReset, ActMagical, ActBreeze, ActSplash
    .word ActLastWave, ActCoin, ActCheck, ActSlipOn, ActSlipOff
    .word ActCheersOn, ActCheersOff, ActCrash1, ActCrash2, ActRebound
    .word ActSignal1, ActSignal2, ActVCheck, ActVCongrats, ActVReady
    .word ActSafeOn, ActSafeOff, ActNewCmd

.segment "RODATA"
; command | action << 8 ($FFFF end); commands not listed are ignored
; (YM beeps, INIT/STOP_WEIRD, PCM wave, YM levels, REVS: no SNES sound yet)
CmdMap:
    ; RESET ($80) is the Z80's idle/no-command value, also sent on every
    ; overtake. Only FM_RESET stops music (OSound::process_command).
    .word S_RESET | 0 << 8
    .word S_FM_RESET | 2 << 8
    .word S_MUSIC_MAGICAL | 3 << 8
    .word S_MUSIC_BREEZE | 4 << 8
    .word S_MUSIC_SPLASH | 5 << 8
    .word S_MUSIC_LASTWAVE | 6 << 8
    .word S_COIN_IN | 7 << 8
    .word S_YM_CHECKPOINT | 8 << 8
    .word S_INIT_SLIP | 9 << 8
    .word S_STOP_SLIP | 10 << 8
    .word S_INIT_CHEERS | 11 << 8
    .word S_INIT_CHEERS2 | 11 << 8
    .word S_STOP_CHEERS | 12 << 8
    .word S_CRASH1 | 13 << 8
    .word S_CRASH2 | 14 << 8
    .word S_REBOUND | 15 << 8
    .word S_SIGNAL1 | 16 << 8
    .word S_SIGNAL2 | 17 << 8
    .word S_VOICE_CHECKPOINT | 18 << 8
    .word S_VOICE_CONGRATS | 19 << 8
    .word S_VOICE_GETREADY | 20 << 8
    .word S_INIT_SAFETYZONE | 21 << 8
    .word S_STOP_SAFETYZONE | 22 << 8
    .word S_NEW_COMMAND | 23 << 8
    .word $FFFF

.segment "SA1CODE"
;----------------------------------------------------------------------------
; SndTick (osoundint.tick): engine tone and passing traffic from
; engine_data (z80: revs = (data >> 5) & $1FF; from revs $30 the player's
; channels play the engine loop at PCM delta $40 + (revs - $30) / 2, below
; that the table entries (z80 $7956: the loop at delta $50 + revs - 1)),
; nearest traffic car = highest volume
;----------------------------------------------------------------------------
SndTick:
    lda engine_data+S_ENGINE_PITCH_H
    and #$00FF
    xba
    sta sp_t
    lda engine_data+S_ENGINE_PITCH_L
    and #$00FF
    ora sp_t
    beq @off
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    and #$01FF
    beq @off                ; (revs 0: the arcade mutes the engine)
    sec
    sbc #$30
    bpl :+
    adc #$30+$4F            ; revs < $30: delta $50 + revs - 1 (C clear)
    bra :++
:   lsr a
    clc
    adc #$40
    cmp #$100
    bcc :+
    lda #$FF
:   sep #$20
    .a8
    sta f:SND_ENGP
    lda engine_data+S_ENGINE_VOL
    lsr a
    sta f:SND_ENGV
    rep #$20
    .a16
    bra @traf
@off:
    sep #$20
    .a8
    lda #0
    sta f:SND_ENGP
    rep #$20
    .a16
@traf:
    ; loudest of TRAFFIC1-4: vol = bits 3-7, pan = bits 0-2 (-3..3)
    stz sp_t
    ldx #0
    ldy #0
:   lda engine_data+S_TRAFFIC1,x
    and #$00F8
    cmp sp_t
    bcc :+
    beq :+
    sta sp_t
    txy
:   inx
    cpx #4
    bcc :--
    lda sp_t
    beq @toff
    lsr a
    lsr a
    lsr a                   ; 1-31
    sep #$20
    .a8
    sta f:SND_TRAFI
    lda engine_data+S_TRAFFIC1,y
    and #$07
    cmp #4
    bcc :+
    ora #$F8                ; -3..-1
:   clc
    adc #3
    sta f:SND_TRAFP
    rep #$20
    .a16
    rts
@toff:
    sep #$20
    .a8
    lda #0
    sta f:SND_TRAFI
    rep #$20
    .a16
    rts
.endif
