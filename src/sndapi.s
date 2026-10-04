; Sound: SA-1 side API (queues commands for the S-CPU sound service).
; All entry points preserve A, X and Y.
.p816
.smart
.include "shared.inc"
.include "gamevars.inc"
.include "sound.inc"

.export SndQueue, SndSfx, SndSfxStop, SndMusic, SndStop

.segment "SA1CODE"
.a16
.i16

; SndQueue: A = command | parameter << 8
SndQueue:
    phx
    pha
    lda f:SND_QW
    tax
    pla
    sta f:SND_Q,x
    pha
    txa
    inc a
    inc a
    and #SND_QMASK
    sta f:SND_QW
    pla
    plx
    rts

; SndSfx / SndSfxStop: A = effect id (SFX_*).  Attract mode stays silent
; like the arcade (only the coin sound plays).
SndSfx:
    pha
    .ifdef SFX_TEST
    bra @ok
    .endif
    lda game_state
    cmp #GS_ATTRACT
    bne @ok
    lda 1,s
    cmp #SFX_COIN
    beq @ok
    pla
    rts
@ok:
    lda 1,s
    xba
    and #$FF00
    ora #SQ_SFX
    jsr SndQueue
    pla
    rts
SndSfxStop:
    pha
    xba
    and #$FF00
    ora #SQ_SFXOFF
    jsr SndQueue
    pla
    rts

; SndMusic: A = song number (SND_SONG_*); loads the bank when needed and
; (re)starts the song
SndMusic:
    pha
    xba
    and #$FF00
    ora #SQ_PLAY
    jsr SndQueue
    pla
    rts

SndStop:
    pha
    lda #SQ_STOP
    jsr SndQueue
    pla
    rts
