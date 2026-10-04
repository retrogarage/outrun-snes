; OMusic: music selection screen - port of the original CannonBall
; engine/omusic.cpp (classic): the compressed tilemap on tile RAM page 16
; plus five overlaid sprites (radio, equalizer, FM readout, dial, hand) in
; jump table entries entry_start .. entry_start+4 (SPRITE_ENTRIES - $10).
; Classic arcade selection only: tick_original with the three arcade tracks
; (tick_enhanced, custom music and the widescreen tilemap / tile patching are
; CannonBall extras: omitted).  The music preview (CannonBall's default
; config.sound.preview = 1: the selected song plays while selecting) is on;
; -D NO_PREVIEW gives the original arcade (wave noise, no music).
; blit() (omusic.cpp 378) only runs when frame skipping: omitted.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import FC_DisableSprites, FC_DoSprOrderShadows, FC_HudBlitText2, FC_InHasPressed, FC_InputsWheelRead, FC_MapPalette, FC_SetTileScroll, FC_SndQueueSound, FC_TrafficDisable, FC_VidClearTextRam, FC_VidSetEnabled, FC_VidWritePal32, FC_VidWriteText32, FC_VidWriteTile16   ; (farbank.py)
.import InputsWheelRead, scn_page
.import DoSprOrderShadows, MapPalette, DisableSprites
.import spr_cnt_main, spr_cnt_shadow
.import TrafficDisable, SetTileScroll, LogoDisable, HudBlitText2
.import VidClearTextRam, VidSetEnabled, VidWriteText32, VidWriteTile16
.import VidWritePal32
.import SndQueueSound, InHasPressed
.import car_ctrl_active, car_inc_old, car_increment
.import road_ctrl, horizon_base
.import time_counter, frame_counter, credits
.import steering_adjust, game_state

.export MusicEnable, MusicDisable, MusicTick, MusicCheckStart
.export MusicPlayMusic, MusicCycleMusic

; config.sound.music_timer: the arcade value.  The routine at $B342 (rev B
; rom0 $B394) does move.w #$30, time_counter: 30 seconds (BCD), which is
; also CannonBall's MUSIC_TIMER default.
MUSIC_TIMER  = $30
FRAME_RESET  = 30           ; ostats.frame_reset (const static int16_t)
ROAD_BOTH_P0 = 3            ; ORoad::ROAD_BOTH_P0
HORIZON_OFF  = -$3FF        ; ORoad::HORIZON_OFF
HAND_LEFT    = 0
HAND_CENTRE  = 1
HAND_RIGHT   = 2
NOTE_TILES1  = $8A7A8A7B    ; note tiles to the left of the track name
NOTE_TILES2  = $8A7C8A7D

.segment "BSS"
music_selected:      .res 2 ; uint8 (0 at boot)
entry_start:         .res 2 ; uint16
last_music_selected: .res 2 ; int16
preview_counter:     .res 2 ; int8 (preview only)
; (cursor_pos, total_tracks: enhanced selection only; next_track: the track
; index is enough)
mu_i:       .res 2
mu_e:       .res 2
mu_d:       .res 2
mu_fm:      .res 2
mu_dial:    .res 2
mu_hand:    .res 2
mu_idx:     .res 2
mu_dst:     .res 2          ; palette / tile RAM address (low word)
mu_row:     .res 2          ; tilemap16
mu_src:     .res 2          ; src_addr (rom0 bank 3 offset)
mu_x:       .res 2
mu_y:       .res 2
mu_val:     .res 2
mu_cnt:     .res 2

.segment "SA1CODE2"
.a16
.i16

; EntryInit: oentry::init(i) (oentry.hpp 156): X = entry offset, A = i
EntryInit:
    pha
    phx
    ldy #OE_SIZE/2
    lda #0
:   sta f:JT,x
    inx
    inx
    dey
    bne :-
    plx
    pla
    sep #$20
    .a8
    sta f:JT+OE_JUMP_INDEX,x
    lda #$FF
    sta f:JT+OE_FUNC,x          ; function_holder = -1
    lda #3
    sta f:JT+OE_SHADOW,x
    rep #$20
    .a16
    rts

; EOfs: A = k -> X = offset of jump_table[entry_start + k]
EOfs:
    clc
    adc entry_start
    xba                         ; (index < $100)
    lsr a
    lsr a
    tax
    rts

;============================================================================
; enable (omusic.cpp 58, source $B342): initialise the music select screen
;============================================================================
MusicEnable:
    sep #$20
    .a8
    stz car_ctrl_active         ; oferrari.car_ctrl_active = false
    rep #$20
    .a16
    jsl $C10000+FC_VidClearTextRam   
    jsl $C10000+FC_DisableSprites   
    jsl $C10000+FC_TrafficDisable   
    stz car_increment           ; (uint32)
    stz car_increment+2
    stz car_inc_old
    stz spr_cnt_main
    stz spr_cnt_shadow
    lda #ROAD_BOTH_P0
    sta road_ctrl
    lda #.loword(HORIZON_OFF)
    sta horizon_base
    lda #$FFFF
    sta last_music_selected     ; -1
    lda #.loword(-20)
    sta preview_counter         ; delay before playing music (preview only)
    jsl $C10000+FC_InputsWheelRead   ; (SNES: the pad has no wheel noise)
    lda #MUSIC_TIMER
    sta time_counter
    lda #FRAME_RESET
    sta frame_counter
    jsr BlitMusicSelect
    lda #TEXT2_SELECT_MUSIC     ; select music by steering
    jsl $C10000+FC_HudBlitText2   
    lda #S_RESET
    jsl $C10000+FC_SndQueueSound   
    .ifdef NO_PREVIEW
    lda #S_PCM_WAVE             ; (!config.sound.preview) wave noises
    jsl $C10000+FC_SndQueueSound   
    .endif
    ; enable block of sprites: init(i) for i = entry_start .. entry_start+4
    lda #SPRITE_ENTRIES - $10
    sta entry_start
    sta mu_i
@init:
    lda mu_i
    xba
    lsr a
    lsr a
    tax
    lda mu_i
    jsr EntryInit
    inc mu_i
    lda mu_i
    sec
    sbc entry_start
    cmp #5
    bcc @init
    jsr SetupSprite1
    jsr SetupSprite2
    jsr SetupSprite3
    jsr SetupSprite4
    jsr SetupSprite5
    ; widescreen: tile_layer->patch_tiles / otiles.setup_palette_widescreen
    ; (tile_patch->loaded && s16_x_off > 0) and tile_layer->set_x_clamp(
    ; CENTRE): omitted.  cursor_pos = 1, total_tracks: enhanced only.
    rts

;============================================================================
; disable (omusic.cpp 108)
;============================================================================
MusicDisable:
    stz mu_i
:   lda mu_i
    jsr EOfs
    LDEB OE_CONTROL
    and #$FFFF-C_ENABLE
    STEB OE_CONTROL
    inc mu_i
    lda mu_i
    cmp #5
    bcc :-
    ; tile_layer->set_x_clamp(RIGHT), widescreen restore_tiles /
    ; otiles.setup_palette_tilemap: omitted
    stz scn_page                ; SNES: the stage scenery again
    lda #0
    jsl $C10000+FC_VidSetEnabled   ; video.enabled = false (screen off)
    rts

; setup_sprite1 (omusic.cpp 130, source $CAF0): radio
SetupSprite1:
    lda #0
    jsr EOfs
    lda #28
    STE OE_X
    lda #180
    STE OE_Y
    lda #$FF
    STE OE_ROAD_PRIORITY
    lda #$1FE
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$B0
    STE OE_PAL_SRC
    lda #.loword(SPRITE_RADIO)
    STE OE_ADDR
    lda #.hiword(SPRITE_RADIO)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite2 (omusic.cpp 145, source $CB2A): equalizer
SetupSprite2:
    lda #1
    jsr EOfs
    lda #4
    STE OE_X
    lda #189
    STE OE_Y
    lda #$FF
    STE OE_ROAD_PRIORITY
    lda #$1FE
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$A7
    STE OE_PAL_SRC
    lda #.loword(SPRITE_EQ)
    STE OE_ADDR
    lda #.hiword(SPRITE_EQ)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite3 (omusic.cpp 160, source $CB64): FM radio readout
SetupSprite3:
    lda #2
    jsr EOfs
    lda #$FFF8                  ; -8
    STE OE_X
    lda #176
    STE OE_Y
    lda #$FF
    STE OE_ROAD_PRIORITY
    lda #$1FE
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$87
    STE OE_PAL_SRC
    lda #.loword(SPRITE_FM_LEFT)
    STE OE_ADDR
    lda #.hiword(SPRITE_FM_LEFT)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite4 (omusic.cpp 175, source $CB9E): FM radio dial
SetupSprite4:
    lda #3
    jsr EOfs
    lda #68
    STE OE_X
    lda #181
    STE OE_Y
    lda #$FF
    STE OE_ROAD_PRIORITY
    lda #$1FE
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$89
    STE OE_PAL_SRC
    lda #.loword(SPRITE_DIAL_LEFT)
    STE OE_ADDR
    lda #.hiword(SPRITE_DIAL_LEFT)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

; setup_sprite5 (omusic.cpp 190, source $CBD8): hand
SetupSprite5:
    lda #4
    jsr EOfs
    lda #21
    STE OE_X
    lda #196
    STE OE_Y
    lda #$FF
    STE OE_ROAD_PRIORITY
    lda #$1FE
    STE OE_PRIORITY
    lda #$7F
    STEB OE_ZOOM
    lda #$AF
    STE OE_PAL_SRC
    lda #.loword(SPRITE_HAND_LEFT)
    STE OE_ADDR
    lda #.hiword(SPRITE_HAND_LEFT)
    STE OE_ADDR+2
    jsl $C10000+FC_MapPalette
    rts

;============================================================================
; check_start (omusic.cpp 206, source $B768): start button
;============================================================================
MusicCheckStart:
    lda credits
    and #$00FF
    beq @r
    lda #IN_START
    jsl $C10000+FC_InHasPressed   
    cmp #0
    beq @r
    lda #GS_INIT_GAME
    sta game_state
    jsr LogoDisable
    jmp MusicDisable
@r: rts

;============================================================================
; tick (omusic.cpp 217): tick and blit
;============================================================================
MusicTick:
    lda #0                      ; radio sprite
    jsr EOfs
    jsl $C10000+FC_DoSprOrderShadows   
    lda #1                      ; animated EQ sprite: cycle the equalizer
    jsr EOfs
    stx mu_e
    LDE OE_RELOAD
    inc a
    STE OE_RELOAD               ; e->reload++
    and #$3E
    lsr a
    ora #.loword(MUSIC_EQ_PAL)  ; ((reload & 0x3E) >> 1) | MUSIC_EQ_PAL
    tax
    lda f:R0BANK*$10000 + (MUSIC_EQ_PAL & $FFFF0000),x
    and #$00FF
    ldx mu_e
    STE OE_PAL_SRC
    jsl $C10000+FC_MapPalette   
    ldx mu_e
    jsl $C10000+FC_DoSprOrderShadows   
    ; FM station and dial depending on the steering: the classic selection
    ; (CannonBall calls tick_enhanced when total_tracks >= 3)
    jsr TickOriginal
    lda #2
    jsr EOfs
    jsl $C10000+FC_DoSprOrderShadows   ; fm
    lda #3
    jsr EOfs
    jsl $C10000+FC_DoSprOrderShadows   ; dial
    lda #4
    jsr EOfs
    jsl $C10000+FC_DoSprOrderShadows   ; hand
    .ifndef NO_PREVIEW
    ; enhancement: preview music on the sound selection screen
    ; (config.sound.preview): 10 ticks after the selection changed (30 at
    ; the screen's start) the selected song plays
    lda music_selected
    cmp last_music_selected
    beq @pv
    lda preview_counter
    bne :+
    lda last_music_selected
    cmp #$FFFF
    beq :+
    lda #S_FM_RESET             ; the old song stops
    jsl $C10000+FC_SndQueueSound   
:   lda preview_counter         ; ++preview_counter >= 10 (int8)
    inc a
    sta preview_counter
    sec
    sbc #10
    bvc :+
    eor #$8000
:   bmi @pv
    lda #$FFFF
    jsr MusicPlayMusic          ; play_music() (index = -1)
    stz preview_counter
@pv:
    .endif
    rts

;============================================================================
; play_music (omusic.cpp 260): A = index (int, -1 = music_selected)
;============================================================================
MusicPlayMusic:
    cmp #$FFFF
    bne :+
    lda music_selected
:   sta mu_idx
    ; next_track = config.sound.music[index]: an IS_YM_INT arcade track
    ; (audio.clear_wav(): no wav playback), queue its Z80 command
    tax
    lda f:MusicCmds,x
    and #$00FF
    jsl $C10000+FC_SndQueueSound   
    lda mu_idx
    sta last_music_selected
    rts

;============================================================================
; cycle_music (omusic.cpp 288): next track (continuous mode)
;============================================================================
MusicCycleMusic:
    lda music_selected
    inc a
    and #$00FF
    sta music_selected          ; ++music_selected (uint8)
    cmp #3
    bcc :+
    stz music_selected          ; > 2
:   lda #$FFFF
    jmp MusicPlayMusic

;----------------------------------------------------------------------------
; tick_original (omusic.cpp 296): wheel left = track 0, centre = track 1,
; right = track 2 (fm, dial, hand = entries entry_start + 2, 3, 4)
;----------------------------------------------------------------------------
TickOriginal:
    lda steering_adjust         ; steering_adjust + 0x80 <= 0x55 (int)
    sec
    sbc #.loword(-$2A)          ;   <=> steering_adjust < -0x2A
    bvc :+
    eor #$8000
:   bpl @nleft
    lda #HAND_LEFT              ; steer left
    jsr SetHand
    lda #TEXT2_MAGICAL
    jsl $C10000+FC_HudBlitText2   
    lda #.loword($1105C0)
    ldx #.hiword(NOTE_TILES1)
    ldy #.loword(NOTE_TILES1)
    jsl $C10000+FC_VidWriteText32   
    lda #.loword($110640)
    ldx #.hiword(NOTE_TILES2)
    ldy #.loword(NOTE_TILES2)
    jsl $C10000+FC_VidWriteText32   
    stz music_selected
    rts
@nleft:
    lda steering_adjust         ; steering_adjust + 0x80 <= 0xAA
    sec                         ;   <=> steering_adjust < 0x2B
    sbc #$2B
    bvc :+
    eor #$8000
:   bpl @right
    lda #HAND_CENTRE            ; centre
    jsr SetHand
    lda #TEXT2_BREEZE
    jsl $C10000+FC_HudBlitText2   
    lda #.loword($1105C6)
    ldx #.hiword(NOTE_TILES1)
    ldy #.loword(NOTE_TILES1)
    jsl $C10000+FC_VidWriteText32   
    lda #.loword($110646)
    ldx #.hiword(NOTE_TILES2)
    ldy #.loword(NOTE_TILES2)
    jsl $C10000+FC_VidWriteText32   
    lda #1
    sta music_selected
    rts
@right:
    lda #HAND_RIGHT             ; steer right
    jsr SetHand
    lda #TEXT2_SPLASH
    jsl $C10000+FC_HudBlitText2   
    lda #.loword($1105C8)
    ldx #.hiword(NOTE_TILES1)
    ldy #.loword(NOTE_TILES1)
    jsl $C10000+FC_VidWriteText32   
    lda #.loword($110648)
    ldx #.hiword(NOTE_TILES2)
    ldy #.loword(NOTE_TILES2)
    jsl $C10000+FC_VidWriteText32   
    lda #2
    sta music_selected
    rts

;----------------------------------------------------------------------------
; set_hand (omusic.cpp 350): A = direction (fm, dial, hand = entries
; entry_start + 2, 3, 4)
;----------------------------------------------------------------------------
SetHand:
    sta mu_d
    lda #2
    jsr EOfs
    stx mu_fm
    lda #3
    jsr EOfs
    stx mu_dial
    lda #4
    jsr EOfs
    stx mu_hand
    lda mu_d
    cmp #HAND_LEFT
    bne @nl
    ldx mu_hand
    lda #17
    STE OE_X
    ldx mu_fm
    lda #.loword(SPRITE_FM_LEFT)
    STE OE_ADDR
    lda #.hiword(SPRITE_FM_LEFT)
    STE OE_ADDR+2
    ldx mu_dial
    lda #.loword(SPRITE_DIAL_LEFT)
    STE OE_ADDR
    lda #.hiword(SPRITE_DIAL_LEFT)
    STE OE_ADDR+2
    ldx mu_hand
    lda #.loword(SPRITE_HAND_LEFT)
    STE OE_ADDR
    lda #.hiword(SPRITE_HAND_LEFT)
    STE OE_ADDR+2
    rts
@nl:
    cmp #HAND_CENTRE
    bne @nc
    ldx mu_hand
    lda #21
    STE OE_X
    ldx mu_fm
    lda #.loword(SPRITE_FM_CENTRE)
    STE OE_ADDR
    lda #.hiword(SPRITE_FM_CENTRE)
    STE OE_ADDR+2
    ldx mu_dial
    lda #.loword(SPRITE_DIAL_CENTRE)
    STE OE_ADDR
    lda #.hiword(SPRITE_DIAL_CENTRE)
    STE OE_ADDR+2
    ldx mu_hand
    lda #.loword(SPRITE_HAND_CENTRE)
    STE OE_ADDR
    lda #.hiword(SPRITE_HAND_CENTRE)
    STE OE_ADDR+2
    rts
@nc:
    cmp #HAND_RIGHT
    bne @r
    ldx mu_hand
    lda #21
    STE OE_X
    ldx mu_fm
    lda #.loword(SPRITE_FM_RIGHT)
    STE OE_ADDR
    lda #.hiword(SPRITE_FM_RIGHT)
    STE OE_ADDR+2
    ldx mu_dial
    lda #.loword(SPRITE_DIAL_RIGHT)
    STE OE_ADDR
    lda #.hiword(SPRITE_DIAL_RIGHT)
    STE OE_ADDR+2
    ldx mu_hand
    lda #.loword(SPRITE_HAND_RIGHT)
    STE OE_ADDR
    lda #.hiword(SPRITE_HAND_RIGHT)
    STE OE_ADDR+2
@r: rts

;----------------------------------------------------------------------------
; blit_music_select (omusic.cpp 407, source $E0DC): sky palette and the
; music select tilemap (tile RAM page 16).  Tilemap data: words copied as
; they are, except $0000 = compression: value.w, count.w -> count + 1 copies
;----------------------------------------------------------------------------
BlitMusicSelect:
    lda #1                      ; SNES: the tile layers show the page
    sta scn_page
    ; 32 palette longs: PAL_MUSIC_SELECT -> PAL_RAM_SKY ($120F00)
    stz mu_i
    lda #.loword($120F00)
    sta mu_dst
:   ldx mu_i
    lda f:R0(PAL_MUSIC_SELECT),x
    xba
    pha                         ; high word
    lda f:R0(PAL_MUSIC_SELECT)+2,x
    xba
    tay                         ; low word
    plx
    lda mu_dst
    jsl $C10000+FC_VidWritePal32   ; write_pal32(&dst_addr, read32(&src_addr))
    lda mu_dst
    clc
    adc #4
    sta mu_dst
    lda mu_i
    clc
    adc #4
    sta mu_i
    cmp #32*4
    bcc :-
    lda #0                      ; otiles.set_scroll(config.s16_x_off = 0)
    jsl $C10000+FC_SetTileScroll   
    ; (widescreen tilemap: tilemap->loaded && s16_x_off > 0: omitted)
    ; original 4:3 version: 28 rows of 40 tiles (the data stays in rom0
    ; bank 3)
    lda #.loword($10F030)
    sta mu_row                  ; tilemap16 = TILEMAP_RAM_16
    lda #.loword(TILEMAP_MUSIC_SELECT)
    sta mu_src
    lda #28
    sta mu_y
@row:
    lda mu_row
    sta mu_dst                  ; dst_addr = tilemap16
    stz mu_x
@col:
    ldx mu_src
    lda f:R0BANK*$10000 + (TILEMAP_MUSIC_SELECT & $FFFF0000),x
    xba                         ; data = read16(&src_addr)
    inx
    inx
    stx mu_src
    cmp #0
    beq @comp
    tax
    jsr WrTile16                ; no compression: write the tile directly
    inc mu_x
    bra @chk
@comp:
    lda f:R0BANK*$10000 + (TILEMAP_MUSIC_SELECT & $FFFF0000),x
    xba
    sta mu_val                  ; value (tile to copy)
    lda f:R0BANK*$10000 + (TILEMAP_MUSIC_SELECT & $FFFF0000) + 2,x
    xba
    sta mu_cnt                  ; count
    inx
    inx
    inx
    inx
    stx mu_src
@rep:                           ; for (i = 0; i <= count; i++)
    ldx mu_val
    jsr WrTile16
    inc mu_x
    lda mu_cnt
    beq @chk
    dec mu_cnt
    bra @rep
@chk:
    lda mu_x
    cmp #40
    bcc @col
    lda mu_row
    clc
    adc #$80                    ; next line of tiles
    sta mu_row
    dec mu_y
    bne @row
    ; (fix_bugs: misplaced tile above the steering wheel - omitted)
    rts

; WrTile16: write_tile16(&dst_addr, X)
WrTile16:
    lda mu_dst
    jsl $C10000+FC_VidWriteTile16   
    lda mu_dst
    clc
    adc #2
    sta mu_dst
    rts

.segment "RODATA"
; config.sound.music[i].cmd: the three arcade tracks (config.cpp 49)
MusicCmds:
    .byte S_MUSIC_MAGICAL, S_MUSIC_BREEZE, S_MUSIC_SPLASH
.endif
