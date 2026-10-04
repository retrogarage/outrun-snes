; Main loop of the engine port (NEWGAME): per 30 Hz tick the CannonBall
; frame (main.cpp tick: oinputs.tick, do_gear, outrun.tick, frame_done,
; osoundint.tick), then the SNES renderers (scenery tile layers, road
; HDMA, road colours, sprites, text layer) and the frame hand-over to the
; S-CPU.  When rendering falls behind, logic-only ticks keep the game at
; 30 ticks per second.
;
; LOCKSTEP builds: exactly one tick per frame, inputs from the scripted
; table, and the game stops after STOP_TICK ticks (tools/lockstep.py
; dumps BW-RAM there and compares it with the cbref0 trace).
.ifdef NEWGAME
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "ogame.inc"

.import VideoSa1Init, VidInit, RoadRender, PalFlushRoad, ScnRender, ScnInvalidate
.import RoadSnapWait
.import SprV2Init, SprV2Frame, TextInit, TextRender, OhbFrame
.import SndInit, SndTick, InputsInit, InputsTick, InputsDoGear
.import InUpdate, InFrameDone, OutrunInit, OutrunTick, vid_enabled
.export GameMain, in_tick, frame_debt, disp_tick
.export PfTickEnd, PfRenderEnd, grid_warm, render_skip
.ifndef LOCKSTEP
.export PfText
.endif

.ifdef RENDERGATE
.export RgStop
.segment "RODATA"
RgStop:     .word $FFFF         ; patched: rendered frames before the freeze
.endif

.segment "BSS"
render_skip: .res 2         ; a later logic tick is guaranteed before rendering
grid_warm: .res 2              ; build the starting grid before revealing it
in_tick:    .res 2              ; logic ticks run
last_tf:    .res 2
frame_debt: .res 2
stop_tick:  .res 2
rdy_tick:   .res 2              ; in_tick of the frame handed over
disp_tick:  .res 2              ; in_tick of the frame on screen (debug)

.segment "SA1CODE"
.a16
.i16

GameMain:
    .ifdef ROADKEYCHECK
    .import RoadKeyTest
    jmp RoadKeyTest
    .endif
    rep #$30
    jsr VideoSa1Init
    jsr VidInit
    jsr SprV2Init
    jsr TextInit
    jsr SndInit
    jsr InputsInit
    jsr OutrunInit
    .import SettingsInit, SettingsTick, cfg_active
    jsl $CF0000+SettingsInit
    jsr ScnInvalidate
    stz in_tick
    stz grid_warm
    stz frame_debt
    lda #$FFFF
    sta stop_tick
    .ifdef LOCKSTEP
    .import LsStopTick
    lda f:LsStopTick
    sta stop_tick
    .endif
    jsr GetFrame
    sta last_tf
MainLoop:
    .if .defined(LOCKSTEP) .or .defined(ONETICK)
    jsr WaitSwap
    .else
    ; pipelined: the logic of the next frame runs right after the hand-over,
    ; while the S-CPU still builds the road tables of the frame handed over
    ; and swaps it (a tick does not touch what the pending swap uploads;
    ; RoadSnapWait: the S-CPU has copied the posted road inputs)
    ; frames since the last tick start: catch up with logic-only ticks
    jsr AddDebt
@catch:
    lda frame_debt
    cmp #4
    bcc @run
    sec
    sbc #2
    sta frame_debt
    jsr RoadSnapWait
    lda #1
    sta render_skip
    jsr GameTick
    stz render_skip
    bra @catch
@run:
    lda frame_debt
    sec
    sbc #2
    bpl :+
    lda #0
:   sta frame_debt
    jsr RoadSnapWait
    jsr GameTick
    ; wait for the swap: logic ticks that fall due meanwhile run now
@w: lda SH_READY
    beq @sw
    jsr AddDebt
    lda frame_debt
    cmp #4
    bcc @w
    sec
    sbc #2
    sta frame_debt
    jsr RoadSnapWait            ; (the S-CPU copies the posted road inputs first)
    jsr GameTick
    bra @w
@sw:
    .endif
    lda rdy_tick
    sta disp_tick
    .ifdef LOCKSTEP
    lda in_tick
    cmp stop_tick
    bne :+
    ; I-RAM ($0000-$07FF) snapshot at DBG_AREA+$100 for the harness
    ldx #0
@icopy:
    lda a:$0000,x
    sta f:DBG_AREA+$100,x
    inx
    inx
    cpx #$0800
    bcc @icopy
    lda #$4C53                  ; "LS": stopped marker for the test harness
    sta f:DBG_AREA
@stop:
    jsr WaitFrame
    bra @stop
:   jsr GameTick
    .elseif .defined(ONETICK)
    ; renderer test build (tools/rendergate.py): one tick per rendered frame,
    ; so the frames do not depend on the renderer's speed
    jsr GameTick
    .endif
    ; ---- render ----
    .ifndef LOCKSTEP
    lda cfg_active
    beq :+
    jsr TextRender
    jmp PfRenderEnd
:   jsr ScnRender
    .ifndef NOSPR
    jsr OhbFrame                ; [W1c] overhead structures on BG1 (before RoadRender)
    .endif
    .ifndef NOSPR
    .import OhbRoadLate
    jsr OhbRoadLate
    bne @late_road
    .endif
    jsr RoadRender
    jsr PalFlushRoad
@late_road:
    .ifndef NOSPR               ; (debug: no sprites, speed ceiling of the rest)
    jsr SprV2Frame
    jsr OhbRoadLate
    beq :+
    jsr RoadRender
    jsr PalFlushRoad
:
    .endif
    .import sv_txtd
    lda sv_txtd             ; (SprV2Frame may have run it while uploads streamed)
    bne :+
PfText = *                      ; (profiling markers: tools/mesenprof.sh)
    jsr TextRender
:
    .endif
PfRenderEnd = *
    .ifndef LOCKSTEP
    lda cfg_active
    sta SH_MENUN
    beq :+
    lda #15
    bra @brightness
:   lda grid_warm
    beq @reveal
    dec grid_warm
    bne :+
    .import SprGridLock
    jsr SprGridLock
:   lda #0
    bra @brightness
@reveal:
    .endif
    lda vid_enabled
    beq :+
    lda #$0F
:
@brightness:
    sta SH_BRIGHTN          ; (applied at the swap)
    lda in_tick
    sta rdy_tick
    jsr FrameReady
    .if .defined(SPRSTOP) .or .defined(RENDERGATE)
    ; debug: freeze after SPRSTOP rendered frames (consistent memory dumps;
    ; RENDERGATE: the count is RgStop, patched by tools/rendergate.py)
    .import sv_frame
    lda sv_frame
    .ifdef RENDERGATE
    cmp f:RgStop
    .else
    cmp #SPRSTOP
    .endif
    bcc :+
    jsr WaitSwap
@halt:
    jsr WaitFrame
    bra @halt
:
    .endif
    jmp MainLoop

;----------------------------------------------------------------------------
; AddDebt: frame_debt += frames elapsed since the last call (two per tick)
;----------------------------------------------------------------------------
AddDebt:
    jsr GetFrame
    tax
    sec
    sbc last_tf
    stx last_tf
    cmp #61                     ; (a stall over a second: do not catch up)
    bcc :+
    lda #2
:   clc
    adc frame_debt
    sta frame_debt
    rts

;----------------------------------------------------------------------------
; GameTick: one 30 Hz engine tick (cannonball main.cpp tick, STATE_GAME)
;----------------------------------------------------------------------------
GameTick:
    jsr InUpdate
    .ifndef LOCKSTEP
    jsl $CF0000+SettingsTick
    bne @paused
    .endif
    jsr InputsTick
    jsr InputsDoGear
    .ifndef LOCKSTEP
    lda grid_warm
    bne :+
    .endif
    jsr OutrunTick
:
@paused:
    jsr InFrameDone
    jsr SndTick
    inc in_tick
PfTickEnd:                      ; (profiling marker: tools/mesenprof.sh)
    rts
.endif
