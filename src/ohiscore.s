; OHiScore: Best OutRunners table display and name entry - port of the
; original CannonBall engine/ohiscore.cpp (classic: cannonball_mode =
; MODE_ORIGINAL, hiscore_delete = 0; config.save_scores / load_scores are
; omitted).  The score table is written to tile RAM page 15 ($10E000) and
; revealed on the text layer by seven mini cars.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "globals.inc"
.include "ogame.inc"

.import FC_BcdAdd, FC_HudBlitText1, FC_HudBlitText2, FC_HudDrawScore, FC_HudDrawScoreTile, FC_HudDrawTimer2, FC_HudSetupMiniMap, FC_R0Long, FC_Random, FC_SDiv16u, FC_SndQueueSound, FC_VidClearTextRam, FC_VidReadText8, FC_VidReadTile8, FC_VidSetEnabled, FC_VidWritePal32, FC_VidWriteText16, FC_VidWriteText32, FC_VidWriteText8, FC_VidWriteTile16, FC_VidWriteTile32, FC_VidWriteTile8   ; (farbank.py)
.import HudBlitText1, HudBlitText2, HudDrawScore, HudDrawScoreTile
.import HudDrawTimer2, HudSetupMiniMap, hud_v32
.import VidClearTextRam, VidSetEnabled, VidWriteText8, VidWriteText16
.import VidWriteText32, VidReadText8, VidWriteTile8, VidWriteTile16
.import VidWriteTile32, VidReadTile8, VidWritePal32
.import SndQueueSound
.import Random, BcdAdd, bcd_a, bcd_b, R0Long, SDiv16u
.import score, time_counter, frame_counter, game_completed, stage_counters, lap_ms
.import input_acc, input_steering

.export HiInit, HiInitDefScores, HiTick, HiDisplayScores
.export HiSetupPalBest, HiSetupRoadBest
.export scores

NO_SCORES     = 20
NO_MINICARS   = 7
TILE_PROPS    = $8030
FRAME_RESET   = 30          ; ostats.frame_reset (const static int16_t)
ENTRIES       = 28          ; do_input: selectable entries ("ED" = end)
DELETE        = ENTRIES - 1
BIT_3         = $08
; state
STATE_GETPOS  = 0
STATE_DISPLAY = 1
STATE_ENTRY   = 2
STATE_DONE    = 3
; score_entry record (C layout, 16 bytes)
SC_SCORE      = 0           ; uint32
SC_INIT1      = 4           ; uint8
SC_INIT2      = 5           ; uint8
SC_INIT3      = 6           ; uint8
SC_MAPTILES   = 8           ; uint32
SC_TIME       = 12          ; uint16
SC_SIZE       = 16
; minicar_entry record (10 bytes)
MC_POS        = 0           ; int16
MC_SPEED      = 2           ; int16
MC_BASE       = 4           ; int16 base_speed
MC_DST        = 6           ; int16 dst_reached
MC_PROPS      = 8           ; uint16 tile_props
MC_SIZE       = 10

.segment "BWBSS": far
scores:             .res NO_SCORES * SC_SIZE

.segment "BSS"
best_or_state:      .res 2  ; uint8
state:              .res 2  ; uint8
score_pos:          .res 2  ; int8 (sign-extended word)
initial_selected:   .res 2  ; int8
letter_selected:    .res 2  ; int16
acc_curr:           .res 2  ; int16
acc_prev:           .res 2  ; int16
steer:              .res 2  ; int16
flash:              .res 2  ; uint8
dest_total:         .res 2  ; int8
score_display_pos:  .res 2  ; int8
minicars:           .res NO_MINICARS * MC_SIZE
laptime:            .res 6*2    ; uint16 laptime[6]
hs_i:       .res 2
hs_n:       .res 2
hs_x:       .res 2          ; scores record offset
hs_mc:      .res 2          ; minicars record offset
hs_dst:     .res 2          ; tile / text / palette RAM address (low word)
hs_pos:     .res 2
hs_t:       .res 2
hs_u:       .res 2
hs_sadr:    .res 2          ; check_name_entry score_adr
hs_iadr:    .res 2          ; do_input adr
hs_mv:      .res 2          ; read_controls movement
hs_tile:    .res 2
hs_tiles:   .res 2          ; tick_minicars tiles_adr (rom0 bank 0)
hs_sm:      .res 2          ; tiles_smoke_adr (rom0 bank 0)
hs_ta:      .res 2          ; textram_adr
hs_p8:      .res 2          ; minicar pos >> 8
hs_q:       .res 2
hs_r:       .res 2
hs_st:      .res 4          ; convert_lap_time src_time (int32)
hs_min:     .res 2
hs_ms:      .res 2
hs_sec:     .res 2
hs_s2:      .res 2
hs_d3:      .res 2
hs_lk:      .res 2
hs_tb:      .res 2

.segment "SA1CODE2"
.a16
.i16

;============================================================================
; init (ohiscore.cpp 29, source $CE74): clear the score variables
;============================================================================
HiInit:
    stz best_or_state
    lda #STATE_GETPOS
    sta state
    lda #$FFFF
    sta score_pos               ; -1
    stz initial_selected
    stz letter_selected
    stz acc_curr
    stz acc_prev
    stz flash
    stz score_display_pos
    stz dest_total
    rts

;============================================================================
; setup_pal_best (ohiscore.cpp 48, source $360C): shaded red background
;============================================================================
HiSetupPalBest:
    stz hs_i                    ; src = PAL_BESTOR + hs_i
    lda #.loword($120F00)
    sta hs_dst
:   ldx hs_i
    lda f:R0(PAL_BESTOR),x
    xba
    pha                         ; high word
    lda f:R0(PAL_BESTOR)+2,x
    xba
    tay                         ; low word
    plx
    lda hs_dst
    jsl $C10000+FC_VidWritePal32   ; write_pal32(&dst, read32(&src))
    lda hs_dst
    clc
    adc #4
    sta hs_dst
    lda hs_i
    clc
    adc #4
    sta hs_i
    cmp #$20*4
    bcc :-
    rts

;============================================================================
; setup_road_best (ohiscore.cpp 60, source $3624): black road
;============================================================================
HiSetupRoadBest:
    lda #.loword($120800)
    sta hs_dst
:   lda hs_dst
    ldx #0
    ldy #0
    jsl $C10000+FC_VidWritePal32   ; write_pal32(&dst, 0)
    lda hs_dst
    clc
    adc #4
    sta hs_dst
    cmp #.loword($120800) + $20*4
    bcc :-
    rts

;============================================================================
; init_def_scores (ohiscore.cpp 70, source $D17A): default score table
; (rom0 DEFAULT_SCORES: 20 x (score.l, initials.l, time.w, maptiles.l))
;============================================================================
HiInitDefScores:
    stz hs_i                    ; rom offset
    stz hs_x                    ; record offset
@l: ldx hs_i
    lda f:R0(DEFAULT_SCORES),x
    xba
    pha
    lda f:R0(DEFAULT_SCORES)+2,x
    xba
    ldx hs_x
    sta f:scores+SC_SCORE,x
    pla
    sta f:scores+SC_SCORE+2,x
    ldx hs_i
    lda f:R0(DEFAULT_SCORES)+4,x    ; initials: bits 31-24, 23-16
    ldx hs_x
    sep #$20
    .a8
    sta f:scores+SC_INIT1,x
    xba
    sta f:scores+SC_INIT2,x
    rep #$20
    .a16
    ldx hs_i
    lda f:R0(DEFAULT_SCORES)+6,x    ; bits 15-8
    ldx hs_x
    sep #$20
    .a8
    sta f:scores+SC_INIT3,x
    rep #$20
    .a16
    ldx hs_i
    lda f:R0(DEFAULT_SCORES)+8,x
    xba
    ldx hs_x
    sta f:scores+SC_TIME,x
    ldx hs_i
    lda f:R0(DEFAULT_SCORES)+10,x
    xba
    pha
    lda f:R0(DEFAULT_SCORES)+12,x
    xba
    ldx hs_x
    sta f:scores+SC_MAPTILES,x
    pla
    sta f:scores+SC_MAPTILES+2,x
    lda hs_i
    clc
    adc #14
    sta hs_i
    lda hs_x
    clc
    adc #SC_SIZE
    sta hs_x
    cmp #NO_SCORES * SC_SIZE
    bcs :+
    jmp @l
:   rts

;============================================================================
; tick (ohiscore.cpp 97, source $D1C4)
;============================================================================
HiTick:
    lda state
    and #3
    beq @getpos
    cmp #STATE_DISPLAY
    beq @display
    cmp #STATE_ENTRY
    beq @entry
    rts                         ; STATE_DONE
@entry:
    jmp CheckNameEntry
@display:
    jsr HiDisplayScores
    lda best_or_state
    cmp #2
    bcc :+
    lda #STATE_ENTRY            ; name entry once the minicars are done
    sta state
:   rts
@getpos:
    jsr GetScorePos
    lda score_pos
    cmp #$FFFF
    beq @nohi
    lda #S_PCM_WAVE             ; new high score
    jsl $C10000+FC_SndQueueSound   
    lda #S_MUSIC_LASTWAVE
    jsl $C10000+FC_SndQueueSound   
    jsr InsertScore
    bra @setd
@nohi:
    lda #5
    sta time_counter
@setd:
    jsr SetDisplayPos
    lda #$FFFF
    sta acc_prev
    lda #STATE_DISPLAY
    sta state
    lda #1
    jsl $C10000+FC_VidSetEnabled   ; video.enabled = true
    rts

;----------------------------------------------------------------------------
; get_score_pos (ohiscore.cpp 143, source $D318)
;----------------------------------------------------------------------------
GetScorePos:
    stz hs_i
    ldx #0
@l: stx hs_x
    lda score+2                 ; ostats.score > scores[i].score (uint32)
    cmp f:scores+SC_SCORE+2,x
    bne :+
    lda score
    cmp f:scores+SC_SCORE,x
:   beq @n
    bcc @n
    lda hs_i
    sta score_pos
    jmp SetDisplayPos
@n: lda hs_x
    clc
    adc #SC_SIZE
    tax
    inc hs_i
    lda hs_i
    cmp #NO_SCORES
    bcc @l
    lda #$FFFF
    sta score_pos               ; not a new high score
    rts

;----------------------------------------------------------------------------
; insert_score (ohiscore.cpp 164, source $D2C0)
;----------------------------------------------------------------------------
InsertScore:
    ; move entries down: for (i = 19; i > score_pos; i--) scores[i] = scores[i-1]
    lda #NO_SCORES - 1
    sta hs_i
@mv:
    lda hs_i
    sec
    sbc score_pos
    bvc :+
    eor #$8000
:   bmi @ins
    beq @ins
    lda hs_i
    asl a
    asl a
    asl a
    asl a
    tax
    ldy #SC_SIZE/2
:   lda f:scores-SC_SIZE,x
    sta f:scores,x
    inx
    inx
    dey
    bne :-
    dec hs_i
    bra @mv
@ins:
    lda score_pos
    asl a
    asl a
    asl a
    asl a
    tax
    stx hs_x
    lda score
    sta f:scores+SC_SCORE,x
    lda score+2
    sta f:scores+SC_SCORE+2,x
    sep #$20
    .a8
    lda #$20
    sta f:scores+SC_INIT1,x
    sta f:scores+SC_INIT2,x
    sta f:scores+SC_INIT3,x
    rep #$20
    .a16
    lda game_completed
    and #$00FF
    beq @nc
    ; total time: sum of stage_counters[0..4] (MODE_ORIGINAL: 5 entries)
    lda f:stage_counters
    clc
    adc f:stage_counters+2
    clc
    adc f:stage_counters+4
    clc
    adc f:stage_counters+6
    clc
    adc f:stage_counters+8
    sta f:scores+SC_TIME,x
    bra @map
@nc:
    lda #0
    sta f:scores+SC_TIME,x
    sep #$20
    .a8
    stz game_completed          ; ostats.game_completed = false
    rep #$20
    .a16
@map:
    jsl $C10000+FC_HudSetupMiniMap   ; -> A = tile address low word, X = high
    txy
    jsl $C10000+FC_R0Long   ; maptiles = rom0.read32(...)
    stx hs_t
    ldx hs_x
    sta f:scores+SC_MAPTILES+2,x
    lda hs_t
    sta f:scores+SC_MAPTILES,x
    rts

;----------------------------------------------------------------------------
; set_display_pos (ohiscore.cpp 199, source $D298)
;----------------------------------------------------------------------------
SetDisplayPos:
    lda score_pos
    bpl :+
    lda #13
    sta score_display_pos
    rts
:   sec
    sbc #3                      ; (score_pos >= 0: no int8 wrap)
    sta score_display_pos
    bpl :+
    stz score_display_pos       ; < 0
    rts
:   cmp #14
    bcc :+
    lda #13                     ; > 13
    sta score_display_pos
:   rts

;----------------------------------------------------------------------------
; check_name_entry (ohiscore.cpp 220, source $D252)
;----------------------------------------------------------------------------
CheckNameEntry:
    lda score_pos
    cmp #$FFFF
    bne @entry
    lda #TEXT1_YOURSCORE        ; no high score
    jsl $C10000+FC_HudBlitText1   
    lda score
    sta hud_v32
    lda score+2
    sta hud_v32+2
    lda #.loword($110BDA)
    ldy #3                      ; font 3
    jsl $C10000+FC_HudDrawScore   
    lda #STATE_DONE
    sta state
    rts
@entry:
    jsr GetScoreAdr
    sta hs_sadr
    jsr BlitAlphabet
    lda hs_sadr
    jsr FlashEntry
    lda time_counter            ; big red countdown timer
    ldx #.loword($1101EC)
    ldy #$8080                  ; BIG_RED_FONT
    jsl $C10000+FC_HudDrawTimer2   
    lda hs_sadr
    jmp DoInput                 ; (state == STATE_DONE: save_scores omitted)

;----------------------------------------------------------------------------
; get_score_adr (ohiscore.cpp 251, source $D542): -> A = text RAM address
;----------------------------------------------------------------------------
GetScoreAdr:
    lda score_pos
    sec
    sbc #3
    bvc :+
    eor #$8000
:   bpl @n3
    lda score_pos               ; top 3 positions
    xba
    and #$FF00
    clc
    adc #.loword($110452)
    rts
@n3:
    lda score_pos
    sec
    sbc #17
    bvc :+
    eor #$8000
:   bmi @mid
    lda score_pos               ; last 3 positions
    sec
    sbc #19
    xba
    and #$FF00
    clc
    adc #.loword($110A52)
    rts
@mid:
    lda #.loword($110752)       ; middle positions
    rts

;----------------------------------------------------------------------------
; blit_alphabet (ohiscore.cpp 263, source $D45A): highlight the selected
; letter red
;----------------------------------------------------------------------------
BlitAlphabet:
    lda #TEXT2_ALPHABET
    jsl $C10000+FC_HudBlitText2   
    ; adr = $110BF0: write_text16(&adr, v) / write_text16(adr + $7E, v2)
    lda #.loword($110BF0)
    ldx #$8D00                  ; full stop
    jsl $C10000+FC_VidWriteText16   
    lda #.loword($110BF2) + $7E
    ldx #$8D01
    jsl $C10000+FC_VidWriteText16   
    lda #.loword($110BF2)
    ldx #$8D04                  ; arrow
    jsl $C10000+FC_VidWriteText16   
    lda #.loword($110BF4) + $7E
    ldx #$8D05
    jsl $C10000+FC_VidWriteText16   
    lda #.loword($110BF4)
    ldx #$8D02                  ; ED
    jsl $C10000+FC_VidWriteText16   
    lda #.loword($110BF6) + $7E
    ldx #$8D03
    jsl $C10000+FC_VidWriteText16   
    ; colour selected tile red
    lda letter_selected
    asl a
    clc
    adc #.loword($110BBC)
    sta hs_t                    ; adr = 0x110BBC + (letter_selected << 1)
    jsl $C10000+FC_VidReadText8   
    and #1
    ora #$80
    tax
    lda hs_t
    jsl $C10000+FC_VidWriteText8   
    lda hs_t
    clc
    adc #$80
    sta hs_t
    jsl $C10000+FC_VidReadText8   
    and #1
    ora #$80
    tax
    lda hs_t
    jsl $C10000+FC_VidWriteText8
    rts

;----------------------------------------------------------------------------
; flash_entry (ohiscore.cpp 290, source $D42C): A = score text RAM address
;----------------------------------------------------------------------------
FlashEntry:
    sta hs_t
    lda flash
    inc a
    and #$00FF
    sta flash                   ; flash++ (uint8)
    and #BIT_3
    beq @blank
    lda letter_selected
    clc
    adc #.loword(TILES_ALPHABET)
    tax
    lda f:R0BANK*$10000,x       ; rom0.read8(letter_selected + TILES_ALPHABET)
    and #$00FF
    ora #$8600
    bra :+
@blank:
    lda #$20                    ; blank tile
:   tax
    lda initial_selected
    asl a
    clc
    adc hs_t
    jsl $C10000+FC_VidWriteText16
    rts

;----------------------------------------------------------------------------
; do_input (ohiscore.cpp 306, source $D33A): A = score text RAM address
;----------------------------------------------------------------------------
DoInput:
    sta hs_iadr
    jsr ReadControls
    clc
    adc letter_selected
    sta hs_pos                  ; position = read_controls() + letter_selected
    sec
    sbc #ENTRIES + 1            ; position > ENTRIES
    bvc :+
    eor #$8000
:   bmi @nover
    stz letter_selected         ; letter_selected = position = 0
    bra @acc
@nover:
    ldx #0                      ; position < (initial_selected == 3 ? DELETE : 0)
    lda initial_selected
    cmp #3
    bne :+
    ldx #DELETE
:   stx hs_u
    lda hs_pos
    sec
    sbc hs_u
    bvc :+
    eor #$8000
:   bpl @inr
    lda #ENTRIES
    sta letter_selected
    bra @acc
@inr:
    lda hs_pos
    sta letter_selected
@acc:
    ; accelerator pressed then released: (!acc_curr || !(acc_prev ^ acc_curr))
    lda acc_curr
    beq @ret
    eor acc_prev
    bne :+
@ret:
    rts
:   lda letter_selected
    cmp #ENTRIES
    bne @nend
    ; end option selected
    lda initial_selected
    asl a
    clc
    adc hs_iadr
    ldx #$20
    jsl $C10000+FC_VidWriteText16   ; blank tile
    stz frame_counter
    stz time_counter
    lda #STATE_DONE
    sta state
    rts
@nend:
    cmp #DELETE
    bne @char
    ; delete option selected: delete if not at first position
    lda initial_selected
    beq @ret
    lda score_pos
    asl a
    asl a
    asl a
    asl a
    tax
    lda initial_selected
    cmp #1
    bne :+
    sep #$20
    .a8
    lda #$20
    sta f:scores+SC_INIT2,x
    rep #$20
    .a16
    bra :++
:   cmp #2
    bne :+
    sep #$20
    .a8
    lda #$20
    sta f:scores+SC_INIT3,x
    rep #$20
    .a16
:   lda initial_selected
    asl a
    clc
    adc hs_iadr
    ldx #$20
    jsl $C10000+FC_VidWriteText16   ; blank tile
    dec initial_selected
    rts
@char:
    ; normal character selected
    lda letter_selected
    clc
    adc #.loword(TILES_ALPHABET)
    tax
    lda f:R0BANK*$10000,x
    and #$00FF
    sta hs_tile                 ; tile = rom0.read8(TILES_ALPHABET + letter)
    lda score_pos
    asl a
    asl a
    asl a
    asl a
    tax
    lda initial_selected
    bne @i2
    sep #$20
    .a8
    lda hs_tile
    sta f:scores+SC_INIT1,x
    rep #$20
    .a16
    bra @wr
@i2:
    cmp #1
    bne @i3
    sep #$20
    .a8
    lda hs_tile
    sta f:scores+SC_INIT2,x
    rep #$20
    .a16
    bra @wr
@i3:
    cmp #2
    bne @wr
    sep #$20
    .a8
    lda hs_tile
    sta f:scores+SC_INIT3,x
    rep #$20
    .a16
    lda #ENTRIES
    sta letter_selected
@wr:
    lda hs_tile
    ora #$8600
    tax
    lda initial_selected
    asl a
    clc
    adc hs_iadr
    jsl $C10000+FC_VidWriteText16   ; initial tile
    inc initial_selected        ; final initial (hiscore_delete = 0: 3)
    lda initial_selected
    sec
    sbc #3
    bvc :+
    eor #$8000
:   bmi :+
    lda #STATE_DONE
    sta state
    lda #FRAME_RESET
    sta frame_counter
    lda #2
    sta time_counter
:   rts

;----------------------------------------------------------------------------
; read_controls (ohiscore.cpp 387, source $D4DA): -> A = movement (int8:
; 0 none, -1 left, 1 right)
;----------------------------------------------------------------------------
ReadControls:
    lda input_acc               ; accelerator pressed then released
    sec
    sbc #$30
    bvc :+
    eor #$8000
:   bpl @n30
    lda acc_curr                ; < 0x30
    sta acc_prev
    stz acc_curr
    bra @steer
@n30:
    lda input_acc
    sec
    sbc #$60
    bvc :+
    eor #$8000
:   bpl @n60
    lda acc_prev                ; < 0x60
    sta acc_curr
    bra @steer
@n60:
    lda acc_curr
    sta acc_prev
    lda #$FFFF
    sta acc_curr
@steer:
    lda #1
    sta hs_mv                   ; default to right
    lda input_steering
    and #$00FF
    sec
    sbc #$80                    ; steering = (input_steering & 0xFF) - 0x80
    bpl :+
    eor #$FFFF
    inc a                       ; steering = -steering
    ldx #$FFFF
    stx hs_mv                   ; left
:   cmp #$30                    ; (steering 0..$80)
    bcc :+
    lda steer
    clc
    adc #5
    sta steer
    bra @chk
:   cmp #$10
    bcc @chk
    inc steer
@chk:
    lda steer                   ; steer >= 0x14 (int16)
    sec
    sbc #$14
    bvc :+
    eor #$8000
:   bmi :+
    stz steer
    lda hs_mv
    rts
:   lda #0                      ; no movement
    rts

;============================================================================
; display_scores (ohiscore.cpp 432, source $CE84)
;============================================================================
HiDisplayScores:
    lda best_or_state
    beq @init
    cmp #1
    beq @tick
    rts
@init:
    jsl $C10000+FC_VidClearTextRam   
    jsr SetupMinicars
    jsr BlitScoreTable
    lda #1
    sta best_or_state           ; tick
    rts
@tick:
    jsr TickMinicars
    lda dest_total              ; all minicars at their destination?
    sec
    sbc #7
    bvc :+
    eor #$8000
:   bmi :+
    lda #2
    sta best_or_state           ; done
:   rts

;----------------------------------------------------------------------------
; setup_minicars (ohiscore.cpp 464, source $CED2)
;----------------------------------------------------------------------------
SetupMinicars:
    ldx #0
@l: stx hs_mc
    lda #$100
    sta minicars+MC_POS,x
    stz minicars+MC_DST,x
    jsl $C10000+FC_Random   
    and #$0180
    ora #$00F0
    ldx hs_mc
    sta minicars+MC_SPEED,x
    jsl $C10000+FC_Random   
    and #$0007
    ora #$0001
    ldx hs_mc
    sta minicars+MC_BASE,x
    txa
    clc
    adc #MC_SIZE
    tax
    cpx #NO_MINICARS * MC_SIZE
    bcc @l
    rts

;----------------------------------------------------------------------------
; tick_minicars (ohiscore.cpp 477, source $CF0E): move the minicars across
; the text layer, revealing the tile RAM table behind them
;----------------------------------------------------------------------------
TickMinicars:
    lda #.loword($11047C)
    sta hs_dst                  ; dst in text ram
    lda #.loword(TILES_MINICARS1)
    sta hs_tiles                ; tiles_adr (source tile data)
    stz hs_mc
@l: ldx hs_mc
    lda minicars+MC_DST,x       ; (!dst_reached & BIT_0): on-screen
    beq :+
    jmp @next
:   lda minicars+MC_POS,x       ; (pos >> 8) >= 0x5A: reached destination
    jsr Asr8
    sec
    sbc #$5A
    bvc :+
    eor #$8000
:   bmi :+
    lda minicars+MC_DST,x
    ora #1
    sta minicars+MC_DST,x
    inc dest_total
:   lda minicars+MC_SPEED,x
    clc
    adc minicars+MC_BASE,x
    sta minicars+MC_SPEED,x     ; speed += base_speed
    sec
    sbc #$200                   ; speed >= 0x200 (int16)
    bvc :+
    eor #$8000
:   bmi :+
    lda #$180
    sta minicars+MC_SPEED,x
:   lda minicars+MC_POS,x
    clc
    adc minicars+MC_SPEED,x
    sta minicars+MC_POS,x       ; pos += speed
    jsr SetupMinicarsPal
    ldx hs_mc
    lda minicars+MC_POS,x
    jsr Asr8
    sta hs_p8
    and #$FFFE                  ; pos = (pos >> 8) & 0xFFFE
    eor #$FFFF
    sec
    adc hs_dst
    sta hs_ta                   ; textram_adr = dst - pos
    lda #.loword(TILES_MINICARS2)
    sta hs_sm                   ; tiles_smoke_adr
    lda hs_p8
    and #1
    beq @offs
    ; car in 2 tiles
    ldx hs_tiles
    jsr ReadL0
    jsr WrText32                ; write_text32(&textram_adr, read32(tiles_adr))
    bra @smoke
@offs:
    ; car at an offset halfway into the tile (3 tiles)
    lda hs_tiles
    clc
    adc #4
    tax
    jsr ReadL0
    jsr WrText32                ; read32(4 + tiles_adr)
    lda hs_tiles
    clc
    adc #8
    tax
    lda f:R0BANK*$10000,x
    xba
    tax
    jsr WrText16                ; read16(8 + tiles_adr)
@smoke:
    ldx hs_sm
    jsr ReadL0
    lda hs_sm
    clc
    adc #4
    sta hs_sm
    jsr WrText32                ; smoke trail tile 1: read32(&tiles_smoke_adr)
    ldx hs_sm
    lda f:R0BANK*$10000,x
    xba
    tax
    lda hs_sm
    clc
    adc #2
    sta hs_sm
    jsr WrText16                ; smoke trail tile 2: read16(&tiles_smoke_adr)
    ; erase minicar tiles (source $CFB2): copy the tile RAM info to text RAM
    lda hs_ta                   ; bottom line
    sec
    sbc #$2000 - 1
    jsl $C10000+FC_VidReadTile8   
    and #$00FF
    ldx hs_mc
    ora minicars+MC_PROPS,x
    tax
    lda hs_ta
    jsl $C10000+FC_VidWriteText16   
    lda hs_ta                   ; top line
    sec
    sbc #$2000 + $7F
    jsl $C10000+FC_VidReadTile8   
    and #$00FF
    ldx hs_mc
    ora minicars+MC_PROPS,x
    tax
    lda hs_ta
    sec
    sbc #$80
    jsl $C10000+FC_VidWriteText16   
@next:
    lda hs_dst
    clc
    adc #$100                   ; next row in text ram
    sta hs_dst
    lda hs_tiles
    clc
    adc #$0A                    ; next block of minicar data
    sta hs_tiles
    lda hs_mc
    clc
    adc #MC_SIZE
    sta hs_mc
    cmp #NO_MINICARS * MC_SIZE
    bcs :+
    jmp @l
:   rts

; ReadL0: X = rom0 bank 0 address -> X = high word, Y = low word of read32
ReadL0:
    lda f:R0BANK*$10000+2,x
    xba
    tay
    lda f:R0BANK*$10000,x
    xba
    tax
    rts

; WrText32 / WrText16: write_text32 / write_text16(&textram_adr, X:Y / X)
WrText32:
    lda hs_ta
    jsl $C10000+FC_VidWriteText32   
    lda hs_ta
    clc
    adc #4
    sta hs_ta
    rts
WrText16:
    lda hs_ta
    jsl $C10000+FC_VidWriteText16   
    lda hs_ta
    clc
    adc #2
    sta hs_ta
    rts

; Asr8: A = A >> 8 (arithmetic)
Asr8:
    xba
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   rts

;----------------------------------------------------------------------------
; setup_minicars_pal (ohiscore.cpp 555, source $CFCC): X = minicar offset.
; Palette / priority of the tiles revealed behind the car by position.
;----------------------------------------------------------------------------
SetupMinicarsPal:
    lda minicars+MC_POS,x
    xba
    and #$00FF                  ; pos = (uint8)(minicar->pos >> 8)
    ldy #$8400                  ; lap time
    cmp #$20 + 1
    bcc @set
    ldy #$8B00                  ; route
    cmp #$2D + 1
    bcc @set
    ldy #$8200                  ; initials
    cmp #$39 + 1
    bcc @set
    ldy #$8400                  ; score
    cmp #$4A + 1
    bcc @set
    ldy #$8600                  ; 1. 2. 3.
@set:
    tya
    sta minicars+MC_PROPS,x
    rts

;============================================================================
; score table rendering
;============================================================================
; blit_score_table (ohiscore.cpp 584, source $D00C)
BlitScoreTable:
    lda #.loword($10E000)       ; clear tile table 15
    sta hs_t
:   lda hs_t
    ldx #$0020
    ldy #$0020
    jsl $C10000+FC_VidWriteTile32   ; write_tile32(&tile_addr, 0x200020)
    lda hs_t
    clc
    adc #4
    sta hs_t
    cmp #.loword($10E000) + $400*4
    bne :-
    lda #TEXT2_BEST_OR          ; "BEST OUTRUNNERS"
    jsl $C10000+FC_HudBlitText2   
    lda #TEXT1_SCORE_ETC        ; score, name, route, record
    jsl $C10000+FC_HudBlitText1   
    jsr BlitDigit
    jsr BlitScores
    jsr BlitInitials
    jsr BlitRouteMap            ; (cannonball_mode != MODE_CONT)
    jmp BlitLapTime

; blit_digit (ohiscore.cpp 603, source $D03A): 1. 2. 3. ... 7.
BlitDigit:
    lda #.loword($10E438)
    sta hs_dst
    lda score_display_pos
    inc a
    sta hs_pos                  ; pos = score_display_pos + 1 (1..20)
    lda #7
    sta hs_n
@l: lda hs_pos
    ldx #10
    jsl $C10000+FC_SDiv16u   ; (pos > 0: floor = trunc)
    sta hs_q                    ; pos / 10
    stx hs_r                    ; pos % 10
    lda hs_q
    bne @dig
    ldx #$0020                  ; blank: 0x20 : (pos % 10) | 0x30
    lda hs_r
    ora #$0030
    tay
    bra @w
@dig:
    ora #$0030                  ; (pos / 10) | 0x30 : (pos % 10) | 0x30
    tax
    lda hs_r
    ora #$0030
    tay
@w: lda hs_dst
    jsl $C10000+FC_VidWriteTile32   ; number digit
    lda hs_dst
    clc
    adc #4
    ldx #$005B
    jsl $C10000+FC_VidWriteTile16   ; full stop
    lda hs_dst
    clc
    adc #$100
    sta hs_dst
    inc hs_pos
    dec hs_n
    bne @l
    rts

; SdpOfs: hs_x = score_display_pos * SC_SIZE, hs_n = 7
SdpOfs:
    lda score_display_pos
    asl a
    asl a
    asl a
    asl a
    sta hs_x
    lda #7
    sta hs_n
    rts

; NextRow: hs_x += SC_SIZE, hs_dst += $100, --hs_n (Z = done)
NextRow:
    lda hs_x
    clc
    adc #SC_SIZE
    sta hs_x
    lda hs_dst
    clc
    adc #$100
    sta hs_dst
    dec hs_n
    rts

; blit_scores (ohiscore.cpp 641, source $D078)
BlitScores:
    lda #.loword($10E43E)
    sta hs_dst
    jsr SdpOfs
:   ldx hs_x
    lda f:scores+SC_SCORE,x
    sta hud_v32
    lda f:scores+SC_SCORE+2,x
    sta hud_v32+2
    lda hs_dst
    ldy #0
    jsl $C10000+FC_HudDrawScoreTile   ; draw_score_tile(dst, scores[pos++].score, 0)
    jsr NextRow
    bne :-
    rts

; blit_initials (ohiscore.cpp 660, source $D0A4)
BlitInitials:
    lda #.loword($10E452)
    sta hs_dst
    jsr SdpOfs
:   ldx hs_x
    lda f:scores+SC_INIT1,x
    and #$00FF
    tax
    lda hs_dst
    inc a
    jsl $C10000+FC_VidWriteTile8   
    ldx hs_x
    lda f:scores+SC_INIT2,x
    and #$00FF
    tax
    lda hs_dst
    clc
    adc #3
    jsl $C10000+FC_VidWriteTile8   
    ldx hs_x
    lda f:scores+SC_INIT3,x
    and #$00FF
    tax
    lda hs_dst
    clc
    adc #5
    jsl $C10000+FC_VidWriteTile8   
    jsr NextRow
    bne :-
    rts

; blit_route_map (ohiscore.cpp 682, source $D0D8)
BlitRouteMap:
    lda #.loword($10E45E)
    sta hs_dst
    jsr SdpOfs
:   ldx hs_x
    lda f:scores+SC_MAPTILES+2,x
    sta hs_t                    ; tiles >> 16
    lda f:scores+SC_MAPTILES,x
    sta hs_u                    ; tiles & 0xFFFF
    lda hs_t
    xba
    and #$00FF
    tax
    lda hs_dst
    sec
    sbc #$7F
    jsl $C10000+FC_VidWriteTile8   ; (tiles >> 24) & 0xFF
    lda hs_t
    and #$00FF
    tax
    lda hs_dst
    sec
    sbc #$7D
    jsl $C10000+FC_VidWriteTile8   ; (tiles >> 16) & 0xFF
    lda hs_u
    xba
    and #$00FF
    tax
    lda hs_dst
    inc a
    jsl $C10000+FC_VidWriteTile8   ; (tiles >> 8) & 0xFF
    lda hs_u
    and #$00FF
    tax
    lda hs_dst
    clc
    adc #3
    jsl $C10000+FC_VidWriteTile8   ; tiles & 0xFF
    jsr NextRow
    bne :-
    rts

; blit_lap_time (ohiscore.cpp 708, source $D112)
BlitLapTime:
    lda #.loword($10E46A)
    sta hs_dst
    jsr SdpOfs
@l: ldx hs_x
    lda f:scores+SC_TIME,x
    bne :+
    jmp @next
:   jsr ConvertLapTime
    lda laptime
    cmp #TILE_PROPS
    beq :+
    tax
    lda hs_dst
    sec
    sbc #2
    jsl $C10000+FC_VidWriteTile16   ; minutes digit 1
:   lda hs_dst
    ldx laptime+2
    jsl $C10000+FC_VidWriteTile16   ; minutes digit 2
    lda hs_dst
    clc
    adc #2
    ldx #$5E
    jsl $C10000+FC_VidWriteTile16   ; '
    lda hs_dst
    clc
    adc #4
    ldx laptime+4
    jsl $C10000+FC_VidWriteTile16   ; seconds digit 1
    lda hs_dst
    clc
    adc #6
    ldx laptime+6
    jsl $C10000+FC_VidWriteTile16   ; seconds digit 2
    lda hs_dst
    clc
    adc #8
    ldx #$5F
    jsl $C10000+FC_VidWriteTile16   ; "
    lda hs_dst
    clc
    adc #$A
    ldx laptime+8
    jsl $C10000+FC_VidWriteTile16   ; milliseconds digit 1
    lda hs_dst
    clc
    adc #$C
    ldx laptime+10
    jsl $C10000+FC_VidWriteTile16   ; milliseconds digit 2
@next:
    jsr NextRow
    beq :+
    jmp @l
:   rts

;----------------------------------------------------------------------------
; convert_lap_time (ohiscore.cpp 748, source $806C): A = time -> laptime[]
;----------------------------------------------------------------------------
ConvertLapTime:
    sta hs_st                   ; src_time = time (int32)
    stz hs_st+2
    lda #$FFFF
    sta hs_min                  ; minutes = -1
@m: lda hs_st                   ; do { src_time -= MINUTE; minutes++ }
    sec
    sbc #3600
    sta hs_st
    lda hs_st+2
    sbc #0
    sta hs_st+2
    inc hs_min
    lda hs_st+2
    bpl @m                      ; while (src_time >= 0)
    lda hs_st
    clc
    adc #3600
    sta hs_st                   ; (0..3599)
    lda hs_min
    jsr Convert16Dechex
    sta hs_min
    lda hs_st
    and #$003F
    sta hs_ms                   ; ms_lookup
    lda hs_st
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta hs_sec                  ; seconds = src_time >> 6
    lsr a
    lsr a
    lsr a
    lsr a
    sta hs_s2                   ; s2 = seconds >> 4
    lda hs_sec
    and #$000F                  ; s1 > 9
    cmp #10
    bcc :+
    lda hs_sec
    clc
    adc #6
    sta hs_sec
:   lda hs_s2
    sta bcd_a
    sta bcd_b
    stz bcd_a+2
    stz bcd_b+2
    jsl $C10000+FC_BcdAdd   ; s2 = bcd_add(s2, s2)
    sta hs_s2
    sta hs_d3                   ; d3 = s2
    sta bcd_a
    sta bcd_b
    stz bcd_a+2
    stz bcd_b+2
    jsl $C10000+FC_BcdAdd   ; s2 = bcd_add(s2, s2)
    sta bcd_a
    lda hs_d3
    sta bcd_b
    stz bcd_a+2
    stz bcd_b+2                 ; (d3 >= 0)
    jsl $C10000+FC_BcdAdd   ; s2 = bcd_add(s2, d3)
    sta bcd_a
    lda hs_sec
    sta bcd_b
    stz bcd_a+2
    stz bcd_b+2
    jsl $C10000+FC_BcdAdd   ; seconds = bcd_add(s2, seconds)
    sta hs_sec
    ; milliseconds
    ldx hs_ms
    lda f:lap_ms,x              ; ostats.lap_ms[ms_lookup] (LAP_MS_64 table)
    and #$00FF
    pha
    and #$000F
    ora #TILE_PROPS
    sta laptime+10
    pla
    lsr a
    lsr a
    lsr a
    lsr a
    ora #TILE_PROPS
    sta laptime+8
    ; seconds
    lda hs_sec
    and #$000F
    ora #TILE_PROPS
    sta laptime+6
    lda hs_sec
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    ora #TILE_PROPS
    sta laptime+4
    ; minutes
    lda hs_min
    and #$000F
    ora #TILE_PROPS
    sta laptime+2
    lda hs_min
    and #$00F0
    lsr a
    lsr a
    lsr a
    lsr a
    ora #TILE_PROPS
    sta laptime
    rts

; outils::convert16_dechex (outils.cpp 215, ported here): A = value -> A
Convert16Dechex:
    sta hs_lk                   ; lookup = (int16) value
    lda #$FFFF
    sta hs_tb                   ; top_byte = -1
:   lda hs_lk
    sec
    sbc #100
    sta hs_lk
    inc hs_tb
    lda hs_lk
    bpl :-                      ; while (lookup >= 0)
    clc
    adc #100
    tax
    lda hs_tb
    xba
    and #$FF00
    sta hs_tb                   ; top_byte << 8
    lda f:DecToHex,x
    and #$00FF
    ora hs_tb
    rts

.segment "RODATA"
; outils::DEC_TO_HEX (outils.cpp 231)
DecToHex:
    .repeat 100, n
    .byte ((n / 10) << 4) | (n .mod 10)
    .endrepeat
.endif
