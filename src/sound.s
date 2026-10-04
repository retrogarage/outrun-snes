; Sound: S-CPU side.  Boots the SPC700 driver through the IPL ROM, uploads
; the resident bank (effects, common drums), then services the command
; queue that the SA-1 fills (BW-RAM ring buffer) from the S-CPU idle loop.
; Uploads: tools/mksound.py streams of 2-byte packets (whole ARAM pages),
; ports 2/3 = data, port 0 = sequence number (echoed by the driver).
.p816
.smart
.include "snes.inc"
.include "shared.inc"
.include "sound.inc"

.import SndDriver, SndStreams
.export SndBoot, SndService

; driver commands (tools/spc/driver.s)
DC_PLAY   = 1
DC_STOP   = 2
DC_SFX    = 3
DC_SFXOFF = 4
DC_ENGINE = 5
DC_UPLOAD = 6
DC_MVOL   = 7
DC_TRAFFIC = 8

.segment "SZEROPAGE": zeropage
s_seq:   .res 1             ; last command sequence number sent
s_song:  .res 1             ; song bank in ARAM ($FF none)
s_engp:  .res 1             ; engine values last sent
s_engv:  .res 1
s_trafi: .res 1
s_trafp: .res 1
s_sptr:  .res 3             ; upload stream pointer
s_npk:   .res 2
s_prm:   .res 4             ; command parameters / scratch

; The SA-1 shares the cartridge bus. Polling APU handshakes from ROM
; stalls its renderer; reset already copies NMICODE before SndBoot.
.segment "NMICODE"

;----------------------------------------------------------------------------
; SndBoot: IPL transfer of the driver, then the resident bank (A8 X16)
;----------------------------------------------------------------------------
.a8
.i16
SndBoot:
    php
    sep #$20
    rep #$10
    ; IPL ready signature
:   lda APUIO0
    cmp #$AA
    bne :-
:   lda APUIO1
    cmp #$BB
    bne :-
    ldx #SND_DRV_BASE
    stx APUIO2
    lda #1
    sta APUIO1
    lda #$CC
    sta APUIO0
:   cmp APUIO0
    bne :-
    lda #<SndDriver
    sta s_sptr
    lda #>SndDriver
    sta s_sptr+1
    lda #^SndDriver
    sta s_sptr+2
    ldy #0
@byte:
    lda [s_sptr],y
    sta APUIO1
    tya
    sta APUIO0
:   cmp APUIO0
    bne :-
    iny
    cpy #SND_DRV_LEN
    bne @byte
    ldx #SND_DRV_ENTRY
    stx APUIO2
    stz APUIO1
    tya
    clc
    adc #2
    bne :+
    lda #2
:   sta APUIO0
    ; driver ready signature
:   lda APUIO1
    cmp #$DC
    bne :-
:   lda APUIO0
    cmp #$5A
    bne :-
    stz s_seq
    lda #$FF
    sta s_song
    stz s_engp
    stz s_engv
    stz s_trafi
    stz s_trafp
    ; resident bank
    ldx #0
:   phx
    jsr SndUpload
    plx
    inx
    cpx #SND_NRES
    bne :-
    plp
    rts

;----------------------------------------------------------------------------
; SndCmd: A = command, s_prm = param 1, s_prm+1 = param 2 (A8)
;----------------------------------------------------------------------------
SndCmd:
    sta APUIO1
    lda s_prm
    sta APUIO2
    lda s_prm+1
    sta APUIO3
    inc s_seq
    lda s_seq
    sta APUIO0
    ; wait for the echo (bounded: a lost command must not stop the service)
    phx
    ldx #0
:   cmp APUIO0
    beq :+
    dex
    bne :-
:   plx
    rts

;----------------------------------------------------------------------------
; SndUpload: X = stream number (0 - SND_NRES-1 resident, then songs) (A8 X16)
;----------------------------------------------------------------------------
SndUpload:
    rep #$20
    .a16
    txa
    asl a
    asl a
    sta s_prm+2
    txa
    clc
    adc s_prm+2             ; x5
    tax
    lda f:SndStreams,x
    sta s_sptr
    lda f:SndStreams+3,x
    sta s_npk
    sep #$20
    .a8
    lda f:SndStreams+2,x
    sta s_sptr+2
    lda #DC_UPLOAD
    jsr SndCmd
    ldy #0
    ldx s_npk
@pk:
    rep #$20
    .a16
    lda [s_sptr],y          ; two bytes -> ports 2 / 3
    sta APUIO2
    iny
    iny
    sep #$20
    .a8
    inc s_seq
    lda s_seq
    sta APUIO0
:   cmp APUIO0              ; (the driver echoes once it has read them)
    bne :-
    dex
    bne @pk
    rts

;----------------------------------------------------------------------------
; SndService: called from the S-CPU idle loop once per frame
;----------------------------------------------------------------------------
SndService:
    php
    sep #$20
    rep #$10
    ; engine tone
    lda f:SND_ENGP
    cmp s_engp
    bne @eng
    lda f:SND_ENGV
    cmp s_engv
    beq @queue0
@eng:
    lda f:SND_ENGP
    sta s_engp
    sta s_prm
    lda f:SND_ENGV
    sta s_engv
    sta s_prm+1
    lda #DC_ENGINE
    jsr SndCmd
@queue0:
    ; passing traffic
    lda f:SND_TRAFI
    cmp s_trafi
    bne @traf
    lda f:SND_TRAFP
    cmp s_trafp
    beq @queue
@traf:
    lda f:SND_TRAFI
    sta s_trafi
    sta s_prm
    lda f:SND_TRAFP
    sta s_trafp
    sta s_prm+1
    lda #DC_TRAFFIC
    jsr SndCmd
@queue:
    rep #$20
    .a16
    lda f:SND_QR
    cmp f:SND_QW
    beq @done
    tax
    lda f:SND_Q,x
    sta s_prm               ; lo = command, hi = parameter
    txa
    inc a
    inc a
    and #SND_QMASK
    sta f:SND_QR
    sep #$20
    .a8
    lda s_prm+1
    sta s_prm+2
    lda s_prm
    cmp #SQ_PLAY
    bne @notplay
    lda s_prm+2
    cmp s_song
    beq @play
    sta s_song
    rep #$20
    .a16
    and #$00FF
    clc
    adc #SND_NRES
    tax
    sep #$20
    .a8
    jsr SndUpload
@play:
    lda #DC_PLAY
    jsr SndCmd
    bra @queue
@notplay:
    ; other commands map 1:1 onto driver commands, parameter in s_prm
    pha
    lda s_prm+2
    sta s_prm
    pla
    jsr SndCmd
    bra @queue
@done:
    plp
    rts
