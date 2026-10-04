; Outrun: game state machine and per-tick driver - port of the original
; CannonBall engine/outrun.cpp (classic arcade mode only: cannonball_mode =
; MODE_ORIGINAL; no time trial, continuous mode, motor calibration, outputs,
; fps counter, view mode switching (always VIEW_ORIGINAL), menus or score
; load / save).
;
; Entry points for the SNES main loop:
;   OutrunInit = Outrun::init() + boot()
;   OutrunTick = Outrun::tick(true) at fps = tick_fps = 30:
;                jump_table, ORoadTick, vint, vint, oinputs.do_credits
; tick_frame is always true: code under `if (!tick_frame)` is dead (omitted).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

; osprites / olevelobjs
.import TC_HiDisplayScores, TC_HiInit, TC_HiInitDefScores, TC_HiSetupPalBest, TC_HiSetupRoadBest, TC_HiTick, TC_LogoDisable, TC_LogoEnable, TC_LogoTick, TC_MapInit, TC_MapTick, TC_MusicCheckStart, TC_MusicDisable, TC_MusicEnable, TC_MusicPlayMusic, TC_MusicTick   ; (farbank.py)
.import scn_page
.import OSpritesInit, OSpritesTick, SpriteCopy, UpdateSprites, DisableSprites
.import ClearPaletteData
.import LevelObjDoSpriteRoutine, LevelObjInitStartlineSprites
.import LevelObjInitHiscoreSprites
; otraffic / oferrari / ocrash / osmoke / oanimseq / obonus
.import TrafficInit, TrafficInitStage1, TrafficTick, TrafficDisable
.import FerTick, FerDrawShadow, car_ctrl_active, car_inc_old, fer_state
.import CrashTick, coll_count1, coll_count2, crash_counter, skid_counter
.import spin_control1
.import SmokeInit, SmokeDrawFerrari, AnimFlagSeq
.import BonusInit, bonus_control, bonus_timer
; oinitengine / ostats / oinputs / oattractai
.import IeInit, IeInitCrashBonus, IeUpdateRoad, IeUpdateEngine
.import IeSetGranularPosition, car_increment
.import StatsInit, StatsDoTimers, credits, cur_stage, frame_counter
.import time_counter, game_completed
.import InputsInit, InputsAdjust, InputsDoCredits, AiInit
; ohud
.import HudDrawCredits, HudDrawCopyrightText, HudDrawInsertCoin
.import HudDrawMainHud, HudBlitText1, HudBlitText2, HudDrawTimer1
; oroad / otiles / opalette
.import ORoadInit, ORoadTick, horizon_base, road_load_end
.import OTilesInit, WriteTilemapHw, UpdateTilemaps, FillTilemapColor
.import OPalInit, CycleSkyPalette, FadePalette
; omusic / omap / ologo / ohiscore
.import MusicEnable, MusicDisable, MusicTick, MusicCheckStart, MusicPlayMusic
.import MapInit, MapTick, LogoEnable, LogoDisable, LogoTick
.import HiInit, HiInitDefScores, HiDisplayScores, HiTick
.import HiSetupPalBest, HiSetupRoadBest
; outils / osoundint / video adapter
.import ResetRandomSeed, BcdSub, bcd_a, bcd_b
.import SndInit, SndQueueSound, has_booted
.import InHasPressed
.import VidSetEnabled, VidClearTextRam

.export OutrunInit, OutrunTick, OutrunInitBestOutrunners
.export game_state, tick_counter, freeze_timer, tick_frame

FRAME_RESET     = 30        ; ostats.frame_reset (const static int16_t)
TIME_START      = $75       ; ostats.TIME[config.engine.dip_time * 40] (dip_time = 1)
HISCORE_TIMER   = $30       ; config.engine.hiscore_timer
BONUS_INIT      = $04       ; OBonus::BONUS_INIT (BONUS_DISABLE = 0)
FERRARI_END_SEQ = 4         ; OFerrari::FERRARI_END_SEQ

.segment "BSS"
game_state:      .res 2     ; int8 (GS_*, 0-21: stored as a word)
tick_counter:    .res 4     ; uint32
freeze_timer:    .res 2     ; bool: always 0 (classic)
tick_frame:      .res 2     ; bool: always 1 (30 fps)
attract_view:    .res 2     ; uint8 (enhanced attract only)
attract_counter: .res 2     ; int16 (enhanced attract only)
car_inc_bak:     .res 4     ; uint32 car increment backup for attract mode
; (fork_chosen: DEBUG_LEVEL only, omitted)

.segment "SA1CODE"
.a16
.i16

;============================================================================
; init (outrun.cpp 67): OutrunInit = init() + boot()
;============================================================================
OutrunInit:
    stz freeze_timer        ; MODE_ORIGINAL: config.engine.freeze_timer = 0
    .ifdef FREEZE_TIMER
    lda #1                  ; debug build: the timer does not run
    sta freeze_timer
    .endif
    lda #1
    sta tick_frame          ; (constant true; also set by every OutrunTick)
    lda #0
    jsr VidSetEnabled       ; video.enabled = false
    ; select_course(jap = 0, prototype = 0) (outrun.cpp 832): adr.* are the
    ; oaddr.inc constants, trackloader.init's tables are ROM data (TrkSections,
    ; StageData in build/gen/gametab.s) and StageData[0] is already $3C.
    jsr VidClearTextRam
    stz tick_counter
    stz tick_counter+2
    ; smartypi / haptic / rumble outputs: omitted
    ; fall into boot

;============================================================================
; boot (outrun.cpp 93)
;============================================================================
OutrunBoot:
    lda #GS_INIT            ; (layout_debug = 0)
    sta game_state
    jsl $CF0000+TC_HiInitDefScores   ; default hi-score entries
    ; config.load_scores(): omitted
    lda #0
    jsr StatsInit           ; ostats.init(ttrial = false)
    jsr InitJumpTable
    lda #0
    jsr IeInit              ; oinitengine.init(0)
    jsr SndInit
    jmp ResetRandomSeed     ; match the genuine boot up of the original game

;============================================================================
; tick (outrun.cpp 107): OutrunTick = tick(tick_frame = true), fps = 30
;============================================================================
OutrunTick:
    lda #1
    sta tick_frame
    inc tick_counter        ; tick_counter++ (uint32)
    bne :+
    inc tick_counter+2
:   ; VIEWPOINT view mode switching: always VIEW_ORIGINAL (omitted)
    ; config.fps == 30 && config.tick_fps == 30
    jsr JumpTable
    jsr ORoadTick
    jsr Vint
    jsr Vint
    ; coin = oinputs.do_credits() (coin chute outputs omitted)
    jsr InputsDoCredits
    ; fps counter: omitted
    rts

;============================================================================
; vint (outrun.cpp 179): vertical interrupt
;============================================================================
Vint:
    jsr WriteTilemapHw
    jsr UpdateSprites
    ; otiles.update_tilemaps(ostats.cur_stage) (MODE_ORIGINAL): int8 -> A
    lda cur_stage
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   jsr UpdateTilemaps
    jsr CycleSkyPalette
    jsr FadePalette
    jsr StatsDoTimers
    lda time_counter        ; (cannonball_mode != MODE_TTRIAL)
    jsr HudDrawTimer1
    jmp IeSetGranularPosition

;============================================================================
; jump_table (outrun.cpp 191)
;============================================================================
JumpTable:
    ; tick_frame && game_state != GS_CALIBRATE_MOTOR: always true
    jsr MainSwitch          ; Address #1 (0xB128) - Main Switch
    jsr InputsAdjust        ; Address #2 (0x74D8) - Adjust Analogue Inputs

    lda game_state
    cmp #GS_REINIT          ; (GS_CALIBRATE_MOTOR: no motor calibration)
    bne :+
    jmp @copy
:   cmp #GS_MAP
    bne :+
    jsl $CF0000+TC_MapTick   
    jmp @copy
:   cmp #GS_MUSIC
    bne :+
    jsl $CF0000+TC_MusicCheckStart   ; check for start button
    jsr OSpritesTick
    jsr LevelObjDoSpriteRoutine
    ; (!tick_frame: omusic.blit)
    jmp @copy
:   cmp #GS_INIT_BEST2
    beq @best2
    cmp #GS_BEST2
    bne @logo
@best2:
    jsr OSpritesTick
    jsr LevelObjDoSpriteRoutine
    ; (!tick_frame: start button -> GS_INIT_MUSIC)
    jmp @copy
@logo:
    ; GS_LOGO: (!tick_frame: ologo.blit), falls into GS_ATTRACT / GS_BEST1
    cmp #GS_LOGO
    beq @attract
    cmp #GS_ATTRACT
    beq @attract
    cmp #GS_BEST1
    bne @default
@attract:
    jsr CheckFreeplayStart
    ; fall into default
@default:
    jsr OSpritesTick        ; Address #3 Jump_SetupSprites
    jsr LevelObjDoSpriteRoutine
    jsr TrafficTick         ; (disable_traffic = 0) spawn & tick traffic
    jsr IeInitCrashBonus    ; initialise crash sequence or bonus code
    jsr FerTick
    lda fer_state
    and #$00FF
    cmp #FERRARI_END_SEQ
    beq @endseq
    jsr AnimFlagSeq
    jsr CrashTick
    ldx #EOFS(SPRITE_SMOKE1)
    jsr SmokeDrawFerrari    ; left hand smoke
    jsr FerDrawShadow       ; (0xF1A2) Ferrari shadow
    ldx #EOFS(SPRITE_SMOKE2)
    jsr SmokeDrawFerrari    ; right hand smoke
    bra @copy
@endseq:
    ldx #EOFS(SPRITE_SMOKE1)
    jsr SmokeDrawFerrari
    ldx #EOFS(SPRITE_SMOKE2)
    jsr SmokeDrawFerrari
@copy:
    jsr SpriteCopy
    ; motor code (outputs): omitted
    rts

;============================================================================
; main_switch (outrun.cpp 303; source 0xB15E)
;============================================================================
MainSwitch:
    lda game_state
    cmp #GS_REINIT+1
    bcc :+
    jmp MsEnd               ; (no case)
:   asl a
    tax
    jmp (MsTab,x)
MsTab:
    .addr MsInit            ; GS_INIT
    .addr MsAttract         ; GS_ATTRACT
    .addr MsInitBest1       ; GS_INIT_BEST1
    .addr MsBest1           ; GS_BEST1
    .addr MsInitLogo        ; GS_INIT_LOGO
    .addr MsLogo            ; GS_LOGO
    .addr MsInitMusic       ; GS_INIT_MUSIC
    .addr MsMusic           ; GS_MUSIC
    .addr MsInitGame        ; GS_INIT_GAME
    .addr MsStart12         ; GS_START1
    .addr MsStart12         ; GS_START2
    .addr MsStart3          ; GS_START3
    .addr MsIngame          ; GS_INGAME
    .addr MsInitBonus       ; GS_INIT_BONUS
    .addr MsBonus           ; GS_BONUS
    .addr MsInitGameover    ; GS_INIT_GAMEOVER
    .addr MsGameover        ; GS_GAMEOVER
    .addr MsInitMap         ; GS_INIT_MAP
    .addr MsMap             ; GS_MAP
    .addr MsInitBest2       ; GS_INIT_BEST2
    .addr MsBest2           ; GS_BEST2
    .addr MsReinit          ; GS_REINIT

; ---- attract mode ----
MsInit:                     ; GS_INIT
    jsr InitAttract
    ; fall through
MsAttract:                  ; GS_ATTRACT
    jsr TickAttract
    jmp MsEnd

MsInitBest1:                ; GS_INIT_BEST1
    sep #$20
    .a8
    stz car_ctrl_active     ; oferrari.car_ctrl_active = false
    rep #$20
    .a16
    stz car_increment       ; oinitengine.car_increment = 0
    stz car_increment+2
    stz car_inc_old
    lda #5
    sta time_counter
    lda #FRAME_RESET
    sta frame_counter
    jsl $CF0000+TC_HiInit   
    lda #S_FM_RESET
    jsr SndQueueSound
    ; cannonball::audio.clear_wav(): omitted
    lda #GS_BEST1
    sta game_state
    ; fall through
MsBest1:                    ; GS_BEST1
    jsr HudDrawCopyrightText
    jsl $CF0000+TC_HiDisplayScores   
    jsr HudDrawCredits
    jsr HudDrawInsertCoin
    lda credits
    and #$00FF
    beq :+
    lda #GS_INIT_MUSIC
    sta game_state
    jmp MsEnd
:   jsr DecrementTimers
    beq :+
    lda #GS_INIT_LOGO
    sta game_state
:   jmp MsEnd

MsInitLogo:                 ; GS_INIT_LOGO
    jsr VidClearTextRam
    .ifndef LOCKSTEP
    lda #3                  ; complete logo on BG1, independent of OBJ budgets
    sta scn_page
    .endif
    sep #$20
    .a8
    stz car_ctrl_active
    rep #$20
    .a16
    stz car_increment
    stz car_increment+2
    stz car_inc_old
    lda #5
    sta time_counter
    lda #FRAME_RESET
    sta frame_counter
    lda #0
    jsr SndQueueSound       ; osoundint.queue_sound(0)
    lda #S_FM_RESET
    jsl $CF0000+TC_LogoEnable   ; ologo.enable(sound::FM_RESET)
    lda #GS_LOGO
    sta game_state
    ; fall through
MsLogo:                     ; GS_LOGO
    jsr HudDrawCredits
    jsr HudDrawCopyrightText
    jsr HudDrawInsertCoin
    jsl $CF0000+TC_LogoTick   
    lda credits
    and #$00FF
    beq :+
    lda #GS_INIT_MUSIC
    sta game_state
    jmp MsEnd
:   jsr DecrementTimers
    beq :+
    jsl $CF0000+TC_LogoDisable   
    stz scn_page
    lda #GS_INIT            ; resume attract mode
    sta game_state
:   jmp MsEnd

; ---- music select screen ----
MsInitMusic:                ; GS_INIT_MUSIC
    jsl $CF0000+TC_MusicEnable   
    lda #GS_MUSIC
    sta game_state
    ; fall through
MsMusic:                    ; GS_MUSIC
    jsr HudDrawCredits
    jsr HudDrawInsertCoin
    jsl $CF0000+TC_MusicTick   
    jsr DecrementTimers
    beq :+
    jsl $CF0000+TC_MusicDisable   
    lda #GS_INIT_GAME
    sta game_state
:   jmp MsEnd

; ---- in-game ----
MsInitGame:                 ; GS_INIT_GAME
    jsr VidClearTextRam
    sep #$20
    .a8
    lda #1
    sta car_ctrl_active     ; oferrari.car_ctrl_active = true
    rep #$20
    .a16
    jsr InitJumpTable
    lda #0
    jsr IeInit              ; oinitengine.init(0)
    ; timing hack to ensure the horizon is correct
    jsr ORoadTick
    jsr ORoadTick
    jsr ORoadTick
    lda #S_STOP_CHEERS
    jsr SndQueueSound
    lda #S_VOICE_GETREADY
    jsr SndQueueSound
    lda #S_REVS
    jsr SndQueueSound       ; (moved from Z80 code)
    lda #$FFFF
    jsl $CF0000+TC_MusicPlayMusic   ; omusic.play_music() (index = -1)
    .ifndef LOCKSTEP
    .import SettingsRace
    jsl $CF0000+SettingsRace
    .else
    lda #TIME_START
    .endif
    .ifdef FREEZE_TIMER
    lda #$30                ; debug build: freeze_timer -> 0x30
    .endif
    sta time_counter
    lda #FRAME_RESET+50
    sta frame_counter
    sep #$20
    .a8
    dec credits             ; ostats.credits-- (uint8)
    rep #$20
    .a16
    lda #TEXT1_CLEAR_START
    jsr HudBlitText1
    lda #TEXT1_CLEAR_CREDITS
    jsr HudBlitText1
    lda #S_INIT_CHEERS
    jsr SndQueueSound
    lda #1
    jsr VidSetEnabled       ; video.enabled = true
    .ifndef LOCKSTEP
    .import grid_warm, SprForgetScene
    jsr SprForgetScene
    lda #16
    sta grid_warm           ; settle scenery and complete people before arrival
    .endif
    lda #GS_START1
    sta game_state
    jsr HudDrawMainHud
    ; fall through
MsStart12:                  ; GS_START1, GS_START2: car driving in, countdown
    lda frame_counter       ; --frame_counter < 0 (int16)
    dec a
    sta frame_counter
    bpl :+
    lda #S_SIGNAL1
    jsr SndQueueSound
    lda #FRAME_RESET
    sta frame_counter
    inc game_state
:   jmp MsEnd

MsStart3:                   ; GS_START3: countdown 2
    lda frame_counter
    dec a
    sta frame_counter
    bpl :+
    ; (MODE_TTRIAL: ohud.clear_timetrial_text)
    lda #S_SIGNAL2
    jsr SndQueueSound
    lda #S_STOP_CHEERS
    jsr SndQueueSound
    lda #FRAME_RESET
    sta frame_counter
    inc game_state
:   jmp MsEnd

MsIngame:                   ; GS_INGAME
    jsr DecrementTimers
    beq :+
    lda #GS_INIT_GAMEOVER
    sta game_state
:   jmp MsEnd

; ---- bonus mode ----
MsInitBonus:                ; GS_INIT_BONUS
    lda #FRAME_RESET
    sta frame_counter
    sep #$20
    .a8
    lda #BONUS_INIT
    sta bonus_control       ; initialise bonus mode logic
    lda road_load_end
    ora #1
    sta road_load_end       ; CPU 1: load the end road section (uint8 |= 1)
    lda game_completed
    ora #1
    sta game_completed      ; denote game completed (bool |= 1)
    rep #$20
    .a16
    lda #3600
    sta bonus_timer         ; safety timer added in rev. A roms
    lda #GS_BONUS
    sta game_state
    ; fall through
MsBonus:                    ; GS_BONUS
    lda bonus_timer         ; --bonus_timer < 0 (int16)
    dec a
    sta bonus_timer
    bpl :+
    sep #$20
    .a8
    stz bonus_control       ; BONUS_DISABLE
    rep #$20
    .a16
    lda #GS_INIT_GAMEOVER
    sta game_state
:   jmp MsEnd

; ---- game over text ----
MsInitGameover:             ; GS_INIT_GAMEOVER (cannonball_mode != MODE_TTRIAL)
    sep #$20
    .a8
    stz car_ctrl_active
    rep #$20
    .a16
    stz car_increment
    stz car_increment+2
    stz car_inc_old
    lda #3
    sta time_counter
    lda #FRAME_RESET
    sta frame_counter
    lda #TEXT2_GAMEOVER
    jsr HudBlitText2
    lda #S_NEW_COMMAND
    jsr SndQueueSound
    lda #GS_GAMEOVER
    sta game_state
    ; fall through
MsGameover:                 ; GS_GAMEOVER (MODE_ORIGINAL)
    jsr DecrementTimers
    beq :+
    lda #GS_INIT_MAP
    sta game_state
:   jmp MsEnd

; ---- course map ----
MsInitMap:                  ; GS_INIT_MAP
    jsl $CF0000+TC_MapInit   
    lda #TEXT2_COURSEMAP
    jsr HudBlitText2
    lda #GS_MAP
    sta game_state
    ; fall through
MsMap:                      ; GS_MAP
    jmp MsEnd

; ---- best outrunners / score entry ----
MsInitBest2:                ; GS_INIT_BEST2
    ; oroad.set_view_mode(VIEW_ORIGINAL, true): always VIEW_ORIGINAL (omitted)
    jsr DisableSprites      ; EndGame
    jsr TrafficDisable
    jsr ClearPaletteData    ; EditJumpTable3
    jsr LevelObjInitHiscoreSprites
    stz coll_count1
    stz coll_count2
    stz crash_counter
    stz skid_counter
    sep #$20
    .a8
    stz spin_control1
    stz car_ctrl_active
    rep #$20
    .a16
    stz car_increment
    stz car_increment+2
    stz car_inc_old
    lda #HISCORE_TIMER
    sta time_counter
    lda #FRAME_RESET
    sta frame_counter
    jsl $CF0000+TC_HiInit   
    lda #S_NEW_COMMAND
    jsr SndQueueSound
    lda #S_FM_RESET
    jsr SndQueueSound
    ; cannonball::audio.clear_wav(): omitted
    lda #GS_BEST2
    sta game_state
    ; fall through
MsBest2:                    ; GS_BEST2
    jsl $CF0000+TC_HiTick   ; high score logic
    jsr HudDrawCredits
    jsr DecrementTimers     ; countdown expired?
    beq :+
    sep #$20
    .a8
    lda #1
    sta car_ctrl_active     ; allow road updates
    rep #$20
    .a16
    jsr InitJumpTable
    lda #0
    jsr IeInit              ; oinitengine.init(0)
    lda #GS_REINIT          ; reinit game to attract mode
    sta game_state
:   jmp MsEnd

; ---- reinitialise game after high score entry ----
MsReinit:                   ; GS_REINIT
    jsr VidClearTextRam
    lda #GS_INIT
    sta game_state
    ; break
MsEnd:
    jsr IeUpdateRoad
    jmp IeUpdateEngine      ; (DEBUG_LEVEL = false: fork debug code omitted)

;============================================================================
; init_jump_table (outrun.cpp 648; source 0x7E1C)
;============================================================================
InitJumpTable:
    stz car_inc_bak         ; value to restore car increment to in attract mode
    stz car_inc_bak+2
    jsr OSpritesInit
    ; cannonball_mode != MODE_TTRIAL
    jsr TrafficInitStage1   ; hard coded traffic in the right hand lane
    ; trackloader.display_start_line = true
    jsr LevelObjInitStartlineSprites
    jsr TrafficInit
    jsr SmokeInit
    jsr ORoadInit
    jsr OTilesInit
    jsr OPalInit
    jsr InputsInit
    jsr BonusInit
    ; outputs->init(): omitted
    ; video.tile_layer->set_x_clamp(RIGHT), sprite_layer->set_x_clip(false):
    ; widescreen only (omitted)
    rts

;============================================================================
; decrement_timers (outrun.cpp 684; source 0xB736): -> A = 1 (Z clear) when
; the timer expired, else A = 0 (Z set)
;============================================================================
DecrementTimers:
    ; Relaxed affects the race timer only, not attract/music/countdown.
    lda freeze_timer
    beq @timed
    lda game_state
    and #$00FF
    cmp #GS_INGAME
    bne :+
    lda #0
    rts
:
@timed:
    lda frame_counter       ; if (--frame_counter >= 0) return false (int16)
    dec a
    sta frame_counter
    bmi :+
    lda #0
    rts
:   lda #FRAME_RESET
    sta frame_counter
    ; time_counter = bcd_sub(1, (uint32) time_counter)
    lda #1
    sta bcd_a
    stz bcd_a+2
    lda time_counter
    sta bcd_b
    and #$8000              ; (int16 -> uint32: sign extension)
    beq :+
    lda #$FFFF
:   sta bcd_b+2
    jsr BcdSub              ; -> A = low word (int16 truncation)
    sta time_counter
    asl a                   ; return time_counter < 0
    lda #0
    rol a
    rts

; init_motor_calibration (outrun.cpp 721): smartypi only (omitted)

;============================================================================
; init_attract (outrun.cpp 755)
;============================================================================
InitAttract:
    lda #1
    jsr VidSetEnabled       ; video.enabled = true
    sep #$20
    .a8
    lda #1
    sta has_booted          ; osoundint.has_booted = true
    sta car_ctrl_active     ; oferrari.car_ctrl_active = true
    rep #$20
    .a16
    lda car_inc_bak+2
    sta car_inc_old         ; car_inc_bak >> 16
    lda car_inc_bak
    sta car_increment
    lda car_inc_bak+2
    sta car_increment+2
    lda #$15                ; (new_attract = 0)
    sta time_counter
    lda #FRAME_RESET
    sta frame_counter
    stz attract_counter
    stz attract_view
    jsr AiInit
    lda #GS_ATTRACT         ; (MODE_ORIGINAL)
    sta game_state
    rts

;============================================================================
; tick_attract (outrun.cpp 770)
;============================================================================
TickAttract:
    jsr HudDrawCredits
    jsr HudDrawCopyrightText
    jsr HudDrawInsertCoin
    ; enhanced attract mode view switching (new_attract = 0): omitted
    lda credits
    and #$00FF
    beq :+
    lda #GS_INIT_MUSIC
    sta game_state
    rts
:   jsr DecrementTimers
    beq :+
    lda car_increment
    sta car_inc_bak
    lda car_increment+2
    sta car_inc_bak+2
    lda #GS_INIT_BEST1
    sta game_state
:   rts

;============================================================================
; Console Start grants the engine's freeplay token to enter music selection.
; LOCKSTEP keeps the original coin flow for comparison with CannonBall.
;============================================================================
CheckFreeplayStart:
    .ifndef LOCKSTEP
    lda credits
    and #$00FF
    bne :+
    lda #IN_START
    jsr InHasPressed
    beq :+
    inc credits
:
    .endif
    rts

;============================================================================
; init_best_outrunners (outrun.cpp 816)
;============================================================================
OutrunInitBestOutrunners:
    stz scn_page            ; SNES: the course map page goes
    lda #0
    jsr VidSetEnabled       ; video.enabled = false
    ; video.sprite_layer->set_x_clip(false): widescreen only (omitted)
    lda #0
    jsr FillTilemapColor    ; fill tilemap black
    jsr DisableSprites
    lda #$0154
    sta horizon_base        ; oroad.horizon_base = 0x154
    jsl $CF0000+TC_HiSetupPalBest   ; setup palettes
    jsl $CF0000+TC_HiSetupRoadBest   
    lda #GS_INIT_BEST2
    sta game_state
    rts

; select_course (outrun.cpp 832): constant (see OutrunInit)
.endif
