; Console settings and pause screen. Settings are validated on boot and saved
; in the battery-backed area preserved by SA1Entry. Menu controls stay fixed.
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "ogame.inc"
.import HudBlitTextNew, hud_col, txt_dirty
.import txt_lo, txt_hi
.import txt_ram: far
.import game_state, freeze_timer, TrafficSetMax
.export SettingsInit, SettingsTick, SettingsRace, SettingsTime
.export cfg_active, cfg_diff, cfg_keys, cfg_cursor, cfg_capture, race_diff
CFG_SAVE = $407A80
CFG_BACK = $40D800       ; 28 x 32 visible text words; ends at $40DEFF
                        ; gap between OB_PIMG and ST_OAM in sprv3.s
.segment "BSS"
cfg_active: .res 2
cfg_diff: .res 2         ; relaxed / easy / normal / hard
cfg_keys: .res 6         ; B A Y X L R indices: accelerate, brake, gear
cfg_masks: .res 6
cfg_cursor: .res 2
cfg_capture: .res 2
cfg_oldjoy: .res 2
cfg_edges: .res 2
cfg_raw: .res 2
cfg_row: .res 2
cfg_index: .res 2
cfg_oldkey: .res 2
race_diff: .res 2        ; difficulty changes take effect at the next start
.export cfg_masks
.segment "SA1CODE"
.a16
.i16
CfgTraffic:
    jsr TrafficSetMax
    rtl
CfgBlit:
    jsr HudBlitTextNew
    rtl

.segment "SA1CODE2"
.a16
.i16
SettingsInit:
    jsr Defaults
    .ifndef LOCKSTEP
    lda f:CFG_SAVE
    cmp #$534F             ; OS, version 1 and checksum
    bne @done
    lda f:CFG_SAVE+2
    cmp #1
    bne @done
    lda f:CFG_SAVE+4
    cmp #4
    bcs @done
    ldx #0
@check:
    lda f:CFG_SAVE+6,x
    cmp #6
    bcs @done
    inx
    inx
    cpx #6
    bcc @check
    lda f:CFG_SAVE+6
    cmp f:CFG_SAVE+8
    beq @done
    cmp f:CFG_SAVE+10
    beq @done
    lda f:CFG_SAVE+8
    cmp f:CFG_SAVE+10
    beq @done
    lda f:CFG_SAVE+4
    eor f:CFG_SAVE+6
    eor f:CFG_SAVE+8
    eor f:CFG_SAVE+10
    eor #$A591
    cmp f:CFG_SAVE+12
    bne @done
    ldx #6
@load:
    lda f:CFG_SAVE+4,x
    sta cfg_diff,x
    dex
    dex
    bpl @load
@done:
    .endif
    jsr MakeMasks
    rtl
Defaults:
    lda #1                 ; console Easy, 99 seconds and light traffic
    .ifdef LOCKSTEP
    lda #2
    .endif
    sta cfg_diff
    stz cfg_keys
    lda #1
    sta cfg_keys+2
    lda #2
    sta cfg_keys+4
    rts
MakeMasks:
    ldx #4
@key:
    lda cfg_keys,x
    asl a
    tay
    lda CfgButtonBits,y
    sta cfg_masks,x
    dex
    dex
    bpl @key
    ; Retain the familiar shoulder gear shortcuts while they are unassigned.
    lda cfg_keys+4
    cmp #2
    bne @done
    lda cfg_masks
    ora cfg_masks+2
    eor #$FFFF
    and #$0030
    ora cfg_masks+4
    sta cfg_masks+4
@done:
    rts
Save:
    jsr MakeMasks
    lda #0
    sta f:CFG_SAVE
    ldx #6
@copy:
    lda cfg_diff,x
    sta f:CFG_SAVE+4,x
    dex
    dex
    bpl @copy
    lda cfg_diff
    eor cfg_keys
    eor cfg_keys+2
    eor cfg_keys+4
    eor #$A591
    sta f:CFG_SAVE+12
    lda #1
    sta f:CFG_SAVE+2
    lda #$534F
    sta f:CFG_SAVE
    rts

; A=1 consumes the tick, including the closing button; sound keeps running.
SettingsTick:
    lda SH_JOY
    sta cfg_raw
    eor cfg_oldjoy
    and cfg_raw
    sta cfg_edges
    lda cfg_raw
    sta cfg_oldjoy
    lda cfg_active
    bne @menu
    lda cfg_edges
    bit #$2000
    beq @run
    ; Avoid opening during engine/scene initialization and grid warm-up.
    lda game_state
    cmp #GS_INIT_GAME
    beq @run
    .import grid_warm
    lda grid_warm
    bne @run
    jsr Backup
    lda #1
    sta cfg_active
    stz cfg_cursor
    stz cfg_capture
    jsr Draw
    bra @pause
@run:
    lda #0
    rtl
@menu:
    lda cfg_capture
    beq @navigate
    lda cfg_edges
    bit #$3000             ; Select/Start cancel capture
    beq :+
    stz cfg_capture
    jsr Draw
    bra @pause
:   ldx #0
@capture:
    lda cfg_edges
    and CfgButtonBits,x
    beq @next
    txa
    lsr a
    jsr Assign
    stz cfg_capture
    jsr Draw
    bra @pause
@next:
    inx
    inx
    cpx #12
    bcc @capture
@pause:
    lda #1
    rtl
@navigate:
    lda cfg_edges
    bit #$B000             ; B, Start or Select saves and resumes
    beq @move
@close:
    jsr Save
    jsr Restore
    stz cfg_active
    bra @pause
@move:
    bit #$0800
    beq :+
    dec cfg_cursor
    bpl @draw
    lda #5
    sta cfg_cursor
    bra @draw
:   bit #$0400
    beq @adjust
    inc cfg_cursor
    lda cfg_cursor
    cmp #6
    bcc @draw
    stz cfg_cursor
@draw:
    jsr Draw
    bra @pause
@adjust:
    bit #$0380             ; Left, Right or A
    beq @pause
    lda cfg_cursor
    beq @difficulty
    cmp #4
    beq @reset
    cmp #5
    beq @close
    lda cfg_edges
    bit #$0080
    beq @cycle
    lda #1
    sta cfg_capture
    bra @draw
@cycle:
    lda cfg_cursor
    dec a
    asl a
    tax
    lda cfg_keys,x
    ; Left decrements; Right increments (six assignable buttons).
    pha
    lda cfg_edges
    bit #$0200
    beq @right
    pla
    clc
    adc #5
    bra @wrap
@right:
    pla
    inc a
@wrap:
    cmp #6
    bcc :+
    sec
    sbc #6
:   jsr Assign
    bra @draw
@reset:
    jsr Defaults
    bra @draw
@difficulty:
    lda cfg_edges
    bit #$0200
    beq :+
    dec cfg_diff
    bra :++
:   inc cfg_diff
:   lda cfg_diff
    and #3
    sta cfg_diff
    bra @draw

; Assign A to the selected action; swap any conflict, never lose an action.
Assign:
    sta cfg_index
    lda cfg_cursor
    dec a
    asl a
    tax
    lda cfg_keys,x
    sta cfg_oldkey
    lda cfg_index
    sta cfg_keys,x
    stx cfg_index
    ldx #4
@find:
    cpx cfg_index
    beq @next
    cmp cfg_keys,x
    bne @next
    pha
    lda cfg_oldkey
    sta cfg_keys,x
    pla
@next:
    dex
    dex
    bpl @find
    rts

; Save/restore the exact columns used by the menu's uniform centered map.
Backup:
    phb
    pea $4141
    plb
    plb
    ldx #0
    ldy #56
    lda #0
    sta f:cfg_row
@row:
    lda #32
    sta f:cfg_index
@word:
    lda .loword(txt_ram),y
    sta f:CFG_BACK,x
    iny
    iny
    inx
    inx
    lda f:cfg_index
    dec a
    sta f:cfg_index
    bne @word
    tya
    clc
    adc #64
    tay
    lda f:cfg_row
    inc a
    sta f:cfg_row
    lda f:cfg_row
    cmp #28
    bcc @row
    plb
    rts
Restore:
    phb
    pea $4141
    plb
    plb
    ldx #0
    ldy #56
    lda #0
    sta f:cfg_row
@row:
    lda #32
    sta f:cfg_index
@word:
    lda f:CFG_BACK,x
    sta .loword(txt_ram),y
    iny
    iny
    inx
    inx
    lda f:cfg_index
    dec a
    sta f:cfg_index
    bne @word
    tya
    clc
    adc #64
    tay
    lda f:cfg_row
    inc a
    sta f:cfg_row
    lda f:cfg_row
    cmp #28
    bcc @row
    plb
    jmp Dirty

Draw:
    ldx #56
    ldy #28
@clearrow:
    lda #32
    sta cfg_index
    lda #0
@clear:
    sta f:txt_ram,x
    inx
    inx
    dec cfg_index
    bne @clear
    txa
    clc
    adc #64
    tax
    dey
    bne @clearrow
    ldy #CfgTitle
    ldx #3
    jsr Line
    ldy #CfgHint
    ldx #5
    jsr Line
    stz cfg_row
@label:
    lda cfg_row
    asl a
    tax
    lda CfgLabels,x
    tay
    txa
    clc
    adc #8
    tax
    jsr Line
    inc cfg_row
    lda cfg_row
    cmp #6
    bcc @label
    lda cfg_diff
    asl a
    tax
    lda CfgNames,x
    tay
    ldx #8
    jsr Value
    stz cfg_row
@button:
    lda cfg_row
    asl a
    tax
    lda cfg_keys,x
    asl a
    tay
    lda CfgButtons,y
    tay
    txa
    clc
    adc #10
    tax
    jsr Value
    inc cfg_row
    lda cfg_row
    cmp #3
    bcc @button
    lda cfg_cursor
    asl a
    clc
    adc #8
    tax
    ldy #CfgArrow
    lda #6
    jsr Blit
    ldx #21
    ldy #CfgHelp
    lda cfg_capture
    beq :+
    ldy #CfgPress
:   jsr Line
    ldx #23
    ldy #CfgHelp2
    lda cfg_capture
    beq :+
    ldy #CfgCancel
:   jsr Line
    ldx #25
    lda cfg_diff
    asl a
    tay
    lda CfgDescriptions,y
    tay
    jsr Line
Dirty:
    ldx #62
@row:
    lda #0
    sta f:txt_lo,x
    lda #126
    sta f:txt_hi,x
    dex
    dex
    bpl @row
    lda #$FFFF
    sta txt_dirty
    sta txt_dirty+2
    rts
Line:
    lda #8
    bra Blit
Value:
    lda #25
Blit:
    pha
    lda #HUD_GREY
    sta hud_col
    pla
    jsl $C10000+CfgBlit
    rts

; Called at the start of each race, not in the middle of a timed run.
SettingsRace:
    lda cfg_diff
    sta race_diff
    stz freeze_timer
    cmp #0
    bne :+
    inc freeze_timer
:   .ifdef FREEZE_TIMER
    lda #1
    sta freeze_timer
    .endif
    jsl $C10000+CfgTraffic
    lda race_diff
    asl a
    tax
    lda CfgStart,x
    rtl
; A = route/stage lookup offset; result is BCD checkpoint allowance.
SettingsTime:
    pha
    lda race_diff
    asl a
    tax
    lda CfgTimeOff,x
    clc
    adc 1,s
    tax
    pla
    lda f:CfgTimes,x
    and #$FF
    rtl
.segment "RODATA"
CfgButtonBits: .word $8000,$0080,$4000,$0040,$0020,$0010
CfgStart: .word $99,$99,$75,$72
CfgTimeOff: .word 0,0,40,80
CfgTimes:
    .include "asset_CfgTimes.inc"
CfgLabels: .word CfgDifficulty,CfgAccel,CfgBrake,CfgGear,CfgReset,CfgReturn
CfgNames: .word CfgRelaxed,CfgEasy,CfgNormal,CfgHard
CfgDescriptions: .word CfgNoTimer,CfgMoreTime,CfgArcade,CfgHardTime
CfgButtons: .word CfgB,CfgA,CfgY,CfgX,CfgL,CfgR
CfgTitle: .asciiz "        SETTINGS"
CfgHint: .asciiz "DIFFICULTY NEXT RACE"
CfgDifficulty: .asciiz "DIFFICULTY"
CfgAccel: .asciiz "ACCELERATE"
CfgBrake: .asciiz "BRAKE"
CfgGear: .asciiz "CHANGE GEAR"
CfgReset: .asciiz "RESTORE DEFAULTS"
CfgReturn: .asciiz "SAVE AND RETURN"
CfgRelaxed: .asciiz "RELAXED"
CfgEasy: .asciiz "EASY"
CfgNormal: .asciiz "NORMAL"
CfgHard: .asciiz "HARD"
CfgB: .asciiz "B"
CfgA: .asciiz "A"
CfgY: .asciiz "Y"
CfgX: .asciiz "X"
CfgL: .asciiz "L"
CfgR: .asciiz "R"
CfgArrow: .asciiz ">"
CfgHelp: .asciiz "D-PAD CHOOSE / CHANGE"
CfgHelp2: .asciiz "A REMAP  B RETURN"
CfgPress: .asciiz "PRESS B A Y X L OR R"
CfgCancel: .asciiz "START CANCELS"
CfgNoTimer: .asciiz "NO TIMER / LIGHT TRAFFIC"
CfgMoreTime: .asciiz "99 SEC / LIGHT TRAFFIC"
CfgArcade: .asciiz "ARCADE TIME AND TRAFFIC"
CfgHardTime: .asciiz "LESS TIME / MORE TRAFFIC"
.endif
