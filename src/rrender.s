; Road renderer (SA-1): the arcade road hardware picture as per-scanline HDMA
; tables for the SNES Mode 1 road view (docs/renderer.md; the reference
; model is tools/snesroad2.py snes_lines()).
;
; Arcade road RAM line y (ORoad::blit_road, the same word for both roads):
;   d = road_y[road_p2 + $320 + y]
;   d & $800 (solid line): backdrop = arcade colour $780 | (d & $7F); BG1 and
;       BG2 show the scenery tile layers (FG / BG maps) with their scroll
;   else road: idx = d & $1FF, rom line = (d >> 1) & $FF, for each road r
;       shown: h = road r h-scroll entry (HEval), v = ($5C - h) & $FFF,
;       BG HOFS and window from RoadSTab[v] (x0.8 scale),
;       VOFS = line + 256 * phase_r - y - 1 (phase_r = colour table bit r;
;       the PPU shows BG row VOFS + 1 on the first visible line);
;       backdrop = exterior colour of the top road: d & $200 ? road colour
;       $400 | 8r | phase_r : ground colour $420 | 16r | bg
; rd_hwctl: 0 road 0, 1 both (road 0 on top), 2 both (road 1 on top), 3 road 1
;
; NEWGAME: the S-CPU builds the tables (sroad.s, WRAM $7F): RoadRender only
; posts the frame's inputs (road_p2 line data, car offsets, road control,
; colour phase, scenery scroll) and raises the S-CPU IRQ.  The SA-1 builder
; below is kept for the old game and for SRCHECK builds (reference tables in
; BW-RAM next to the S-CPU's, for tools comparing both).
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "gamevars.inc"
.include "road.inc"
.include "road2.inc"

.import RD_Y, RD_X, rd_co, rd_inv, QueueUpload
.importzp RDB

.export RRInit, RoadRender, PalSet, PalFlushRoad, pal_rdirty
.export sc_fgh, sc_fgv, sc_bgh, sc_bgv

.if .defined(SRCHECK) && (!.defined(NOSPR))
.error "SRCHECK builds need -D NOSPR (SR_STG)"
.endif
.if .defined(NEWGAME) && (!.defined(SRCHECK))
RR_SA1 = 0                  ; tables by the S-CPU only
.else
RR_SA1 = 1                  ; SA-1 builder (old game / SRCHECK reference)
.endif

MARK = $3210                ; road_x "ignore car position" marker

.segment "BSS"
sc_fgh:     .res 2          ; scenery layer scroll (SNES), shown on solid lines
sc_fgv:     .res 2
sc_bgh:     .res 2
sc_bgv:     .res 2
pl_a:       .res 2
pl_o:       .res 2
pl_t:       .res 2
pal_rdirty: .res 2          ; road colours changed: upload them

.segment "IRAMBSS"
rr_dp:      .res 64         ; direct page of RoadRender
RR_Y    = 0                 ; scanline
RR_SRC  = 2                 ; byte offset of the line word in RD_Y
RR_O    = 4                 ; table offset of the line (set + header bytes)
RR_D    = 6                 ; line word
RR_IDX  = 8                 ; distance index
RR_ROW  = 10                ; rom line - y - 1 (VOFS of phase 0)
RR_CW   = 12                ; colour table byte
RR_TOP  = 14                ; top road * 2
RR_BOT  = 16                ; bottom road * 2, $FFFF none
RR_CTO  = 18                ; colour table offset (rd_colph * 512)
RR_CO   = 20                ; car offset per road (2 words)
RR_INV  = 24                ; invert flag per road (2 words)
RR_FGH  = 28                ; scenery scroll
RR_FGV  = 30
RR_BGH  = 32
RR_BGV  = 34
RR_X    = 36                ; road_x[idx]
RR_A6   = 38                ; road_x[idx] >> 6
RR_H    = 40                ; HOFS of the road just evaluated
RR_W    = 42                ; window (lo = left, hi = right)
RR_V    = 44                ; VOFS
RR_H2   = 46                ; bottom road values
RR_W2   = 48
RR_V2   = 50
RR_R    = 52                ; road * 2 being evaluated
RR_N    = 54                ; lines left in this table
RR_T    = 56
RR_Y0   = 58                ; RrSplit / RrLines: first line built by the SA-1
RR_T2   = 60

; table addresses in bank $40 (DB = $40 inside the line loop)
T_BG1 = .loword(HT_BASE) + HT_BG1
T_BG2 = .loword(HT_BASE) + HT_BG2
T_WIN = .loword(HT_BASE) + HT_WIN
T_COL = .loword(HT_BASE) + HT_COL
T_SC  = .loword(HT_BASE) + HT_SC

; RR_ROAD: X = road * 2 -> RR_H / RR_W / RR_V (RrRoad below)
.macro RR_ROAD
    stx z:RR_R
    lda z:RR_CO,x
    bne @rr_scan
    ; car centred
    lda z:RR_INV,x
    bne @rr_c1
    lda z:RR_A6
    bra @rr_hv
@rr_c1: lda z:RR_X
    eor #$FFFF
    inc a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    cmp #$8000
    ror a
    bra @rr_hv
@rr_scan:
    lda z:RR_IDX
    sta f:MAL
    lda z:RR_CO,x
    sta f:MBL               ; writing MBH starts idx * car offset
    lda z:RR_X
    cmp #MARK
    beq @rr_mark
    lda z:RR_INV,x
    beq @rr_c2
    lda z:RR_A6
    eor #$FFFF
    inc a
    bra @rr_c3
@rr_c2: lda z:RR_A6
@rr_c3: sta z:RR_T
    sep #$20
    .a8
    lda f:MR+3
    lsr a                   ; carry = bit 24
    rep #$20
    .a16
    lda f:MR+1
    ror a                   ; (idx * co) >> 9
    clc
    adc z:RR_T
    bra @rr_hv
@rr_mark:
    lda z:RR_INV,x
    beq @rr_c4
    lda #($10000 - (MARK >> 6)) & $FFFF
    bra @rr_hv
@rr_c4: lda #MARK >> 6
@rr_hv:
    ; v = ($5C - h) & $FFF -> RoadSTab[v]: HOFS, window
    eor #$FFFF
    sec
    adc #$005C
    and #$0FFF
    asl a
    asl a
    tax
    lda f:RoadSTab,x
    sta z:RR_H
    lda f:RoadSTab+2,x
    sta z:RR_W
    ; VOFS = row + 256 * phase (colour bit r)
    lda z:RR_CW
    ldx z:RR_R
    beq @rr_c5
    lsr a
@rr_c5: and #1
    xba
    clc
    adc z:RR_ROW
    and #$01FF
    sta z:RR_V
.endmacro

; RRBODY: road line A = d (RR_Y = y, rr_dp per frame values, DB = table
; bank, Y = table offset of the line) -> H / V of both roads, windows and
; backdrop colour at tb1 / tb2 / twin / tcol (4 bytes per line)
.macro RRBODY tb1, tb2, twin, tcol
    .local nobot, top, gnd, col
    sta z:RR_D
    and #$01FF
    sta z:RR_IDX
    clc
    adc z:RR_CTO
    tax
    lda f:RoadColTab,x
    and #$00FF
    sta z:RR_CW
    lda z:RR_D
    lsr a
    and #$00FF
    clc                     ; - 1: screen line y shows BG row y + 1 + VOFS
    sbc z:RR_Y
    sta z:RR_ROW
    ; road_x[idx] and road_x >> 6 (arithmetic): shared by both roads
    lda z:RR_IDX
    asl a
    tax
    lda f:RDB*$10000+RD_X,x
    sta z:RR_X
    sta f:MAL
    lda #1024
    sta f:MBL               ; road_x * 1024 (signed): >> 16 = road_x >> 6
    ; bottom road first (its values go to BG2 / window 2)
    ldx z:RR_BOT
    lda f:MR+2
    sta z:RR_A6             ; road_x >> 6 (arithmetic)
    txa
    bmi nobot
    jsr RrRoad
    lda z:RR_H
    sta z:RR_H2
    lda z:RR_W
    sta z:RR_W2
    lda z:RR_V
    sta z:RR_V2
    bra top
nobot:
    lda #$00FF              ; empty window: BG2 masked
    sta z:RR_W2
top:
    ldx z:RR_TOP
    RR_ROAD
    ; backdrop: exterior colour of the top road
    lda z:RR_D
    and #$0200
    beq gnd
    ; road colour: entry $400 | 8r | phase
    lda z:RR_CW
    ldx z:RR_TOP
    beq :+
    lsr a
:   and #1
    ora f:RrRoadCol,x
    bra col
gnd:
    ldx z:RR_TOP
    lda z:RR_CW
    lsr a
    lsr a
    lsr a
    lsr a
    ora f:RrGndCol,x
col:
    asl a
    tax
    lda f:PALSN,x
    sta tcol+2,y
    lda z:RR_H
    sta tb1,y
    lda z:RR_V
    sta tb1+2,y
    lda z:RR_H2
    sta tb2,y
    lda z:RR_V2
    sta tb2+2,y
    lda z:RR_W
    sta twin,y
    lda z:RR_W2
    sta twin+2,y
.endmacro

.segment "SA1CODE"
.a16
.i16

.ifdef NEWGAME
;----------------------------------------------------------------------------
; RoadRender (NEWGAME): hand the frame's road inputs to the S-CPU (shared.inc
; SH_RLN..; sroad.s builds the tables of set SH_BUILD).  All of them stay
; unchanged until the next logic tick, which waits for SH_RPEND = 0
; (RoadSnapWait).
;----------------------------------------------------------------------------
.segment "BWBSS": far
TitleRoadLines: .res 224*2
.segment "SA1CODE"
RoadRender:
    .import scn_pmode
    ; The title uses a complete BG page. Feed solid lines to the existing
    ; HDMA path so the live attract road cannot cut through that picture.
    lda scn_pmode
    cmp #3
    bne :+
    ldx #446
    lda #$0800
@page:
    sta f:TitleRoadLines,x
    dex
    dex
    bpl @page
:
    .ifdef SRFUZZ
    jsr RrFuzz              ; (test builds: unusual road inputs)
    .endif
    .if RR_SA1
    lda SH_BUILD            ; (SRCHECK: set being built, cleared by the
    inc a                   ; S-CPU when its tables are done)
    sta f:DBG_AREA+$10
    jsr RoadRenderSA1       ; (SRCHECK: reference tables in BW-RAM)
    .endif
    lda road_p2
    clc
    adc #RD_Y + $0320*2
    sta SH_RLN
    lda scn_pmode
    cmp #3
    bne :+
    lda #.loword(TitleRoadLines)
    sta SH_RLN
:
    lda rd_co
    sta SH_RCO
    lda rd_co+2
    sta SH_RCO+2
    lda rd_inv
    sta SH_RINV
    lda rd_inv+2
    sta SH_RINV+2
    lda rd_hwctl
    sta SH_RCTL
    lda rd_colph
    sta SH_RPH
    lda sc_fgh
    sta SH_RSCR
    lda sc_fgv
    sta SH_RSCR+2
    lda sc_bgh
    sta SH_RSCR+4
    lda sc_bgv
    sta SH_RSCR+6
    lda scn_pmode
    cmp #3
    bne :+
    lda #224
    sta rr_dp+RR_Y0
    bra :++
:   jsr RrSplit             ; lines the SA-1 builds itself (RrLines)
:
    lda rr_dp+RR_Y0
    sta SH_RSA
    cmp #224
    lda #0
    rol a
    sta SH_RSAD             ; (1: none)
    lda #1
    sta SH_RBUSY
    sta SH_RPEND
    sep #$20
    .a8
    lda #$80
    sta SCNT                ; IRQ to the S-CPU
    rep #$20
    .a16
    lda SH_RSAD
    bne :+
    jsr RrLines             ; (while the S-CPU builds the lines above)
RrlRet:
    lda #1
    sta SH_RSAD
:   rts

;----------------------------------------------------------------------------
; RrSplit: the SA-1 builds the bottom of a long road run itself, so the
; S-CPU's share stays within RR_NS road lines (hill frames: up to 224).  The
; lines of the bottom road run are found by a binary search (road lines below
; solid lines), then verified.  -> rr_dp+RR_Y0 = first SA-1 line (224: none)
;----------------------------------------------------------------------------
.ifdef SRNS
RR_NS   = SRNS              ; (test builds)
.else
RR_NS   = 50                ; road lines of the bottom run the S-CPU builds
.endif
RR_KMIN = 8                 ; fewer lines are not worth the hand-over
    .ifdef RRADAPT
RR_NSS  = RRADAPT           ; (test builds: frames >= 3 vblanks apart)
RR_LF   = 62                ; SH_FRAME at the previous frame
    .endif
RrSplit:
    .ifdef RRADAPT
    lda SH_FRAME
    tay
    sec
    sbc rr_dp+RR_LF
    sty rr_dp+RR_LF
    cmp #3
    lda #RR_NS
    bcc :+
    lda #RR_NSS
:   sta rr_dp+RR_O
    .endif
    lda road_p2
    clc
    adc #RD_Y + $0320*2
    sta rr_dp+RR_T          ; line words (bank RDB)
    tax
    lda f:RDB*$10000+223*2,x
    bit #$0800
    bne @none               ; bottom line solid: no road run there
    ; smallest y with road lines from y down to 223 (lines are solid above)
    stz rr_dp+RR_Y0         ; lo
    lda #223
    sta rr_dp+RR_T2         ; hi
@bs:
    lda rr_dp+RR_Y0
    cmp rr_dp+RR_T2
    bcs @found
    adc rr_dp+RR_T2         ; (C = 0)
    lsr a                   ; mid
    pha
    asl a
    adc rr_dp+RR_T          ; (C = 0)
    tax
    pla
    tay
    lda f:RDB*$10000,x
    bit #$0800
    bne :+
    sty rr_dp+RR_T2         ; road: hi = mid
    bra @bs
:   iny
    sty rr_dp+RR_Y0         ; solid: lo = mid + 1
    bra @bs
@found:
    ; y0 = ytop + RR_NS; verify y0..223 (road)
    clc
    .ifdef RRADAPT
    adc rr_dp+RR_O
    .else
    adc #RR_NS
    .endif
    ; OHB uses these same staging words for the roof below the horizon.
    ; Leave all posted roof lines to the S-CPU, which combines road + BG2.
    cmp SH_OHBN
    bcs :+
    lda SH_OHBN
:   cmp #224-RR_KMIN+1
    bcs @none
    sta rr_dp+RR_Y0
    asl a
    adc rr_dp+RR_T          ; (C = 0)
    tax
:   lda f:RDB*$10000,x
    bit #$0800
    bne @solid
    inx
    inx
    txa
    sec
    sbc rr_dp+RR_T
    cmp #224*2
    bcc :-
    rts
@solid:
    ; (not one run: start below this line)
    txa
    sec
    sbc rr_dp+RR_T
    lsr a
    inc a
    cmp #224-RR_KMIN+1
    bcs @none
    sta rr_dp+RR_Y0
    asl a
    adc rr_dp+RR_T
    tax
    bra :-
@none:
    lda #224
    sta rr_dp+RR_Y0
    rts

;----------------------------------------------------------------------------
; RrLines: road lines RR_Y0..223 -> SR_STG.  Fast path (RrFast) unless a
; road is centred and inverted (then the per line code of the SA-1 table
; builder, RRBODY)
;----------------------------------------------------------------------------
; fast path per frame values (rr_dp fields of the generic code)
F_COT   = RR_H              ; car offset, top road
F_COB   = RR_W              ; bottom road
F_MT    = RR_V              ; $FFFF: road not inverted (v = C - base - A6')
F_MB    = RR_H2
F_CT    = RR_W2             ; C: $25D / ($5C - $200)
F_CB    = RR_V2
F_PMT   = RR_R              ; colour byte * 2 phase bit of the road (2 / 4)
F_PMB   = RR_N              ; (0: no bottom road)
F_RC    = RR_FGH            ; RrRoadCol / RrGndCol of the top road
F_GC    = RR_FGV

; RRFSET: road rsel (RR_TOP / RR_BOT) -> car offset, mask, C, phase bit;
; branches to gen for a centred inverted road
.macro RRFSET rsel, fco, fm, fc, fpm, gen
    .local inv, set, r0
    ldx z:rsel
    lda z:RR_CO,x
    sta z:fco
    lda z:RR_INV,x
    bne inv
    lda #$FFFF
    sta z:fm
    lda #$025D              ; $5C - base - (A6' - $200)
    bra set
inv:
    lda z:fco
    beq gen                 ; centred + inverted: rounding of -road_x >> 6
    stz z:fm
    lda #($5C - $200) & $FFFF ; $5C - base + (A6' - $200)
set:
    sta z:fc
    lda #2
    cpx #0
    beq r0
    asl a
r0: sta z:fpm
.endmacro

RrLines:
    phb
    phd
    lda #rr_dp
    tcd
    lda rd_co
    sta z:RR_CO
    lda rd_co+2
    sta z:RR_CO+2
    lda rd_inv
    sta z:RR_INV
    lda rd_inv+2
    sta z:RR_INV+2
    lda rd_hwctl
    and #3
    asl a
    tax
    lda f:RrTop,x
    sta z:RR_TOP
    lda f:RrBot,x
    sta z:RR_BOT
    lda rd_colph
    and #$001F
    xba
    asl a
    sta z:RR_CTO
    lda z:RR_Y0
    sta z:RR_Y
    asl a
    adc z:RR_T              ; (C = 0) line word offset
    sta z:RR_SRC
    lda z:RR_Y
    asl a
    asl a
    tay                     ; staging offset
    sep #$20
    .a8
    lda #^SR_STG
    pha
    plb                     ; DB = staging bank
    rep #$20
    .a16
    ; fast path values
    RRFSET RR_TOP, F_COT, F_MT, F_CT, F_PMT, RrlLoop
    lda f:RrRoadCol,x
    sta z:F_RC
    lda f:RrGndCol,x
    sta z:F_GC
    stz z:F_PMB
    lda z:RR_BOT
    bpl :+
    jmp RrFast
:   RRFSET RR_BOT, F_COB, F_MB, F_CB, F_PMB, RrlLoop
    jmp RrFast

RrlLoop:
    ldx z:RR_SRC
    lda f:RDB*$10000,x
    RRBODY .loword(SR_STG)+SG_BG1, .loword(SR_STG)+SG_BG2, .loword(SR_STG)+SG_WIN, .loword(SR_STG)+SG_COL
    inc z:RR_SRC
    inc z:RR_SRC
    iny
    iny
    iny
    iny
    inc z:RR_Y
    lda z:RR_Y
    cmp #224
    bcs RrlEnd
    jmp RrlLoop
RrlEnd:
    pld
    plb
    rts

; fast path: same values as RRBODY.  road_x >> 6 (arithmetic) =
; A6' - $200 with A6' = (road_x ^ $8000) >> 6; v needs 12 bits of
; base = (idx * co) >> 9 (MR bits 9..20); VOFS phase bit: adding 256
; (mod 512) flips bit 8; road_x marker lines: h = +/- MARK >> 6, i.e.
; base 0 (MARK >> 6 = road_x >> 6)
FS_BG1 = .loword(SR_STG)+SG_BG1
FS_BG2 = .loword(SR_STG)+SG_BG2
FS_WIN = .loword(SR_STG)+SG_WIN
FS_COL = .loword(SR_STG)+SG_COL
RrfMk:
    tax                     ; road_x marker line: car offset ignored
    lda #0
    bra RrfMm
RrFast:
    ldx z:RR_SRC
    lda f:RDB*$10000,x
    sta z:RR_D
    and #$01FF
    sta z:RR_IDX
    asl a
    tax
    lda f:RDB*$10000+RD_X,x
    cmp #MARK
    beq RrfMk
    tax
    lda z:RR_IDX
RrfMm:
    sta z:RR_X              ; multiplicand
    sta f:MAL
    lda z:F_COT
    sta f:MBL               ; idx * co (top road)
    txa
    eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta z:RR_A6             ; A6'
    eor z:F_MT
    clc
    adc z:F_CT
    sta z:RR_T
    lda f:MR+1
    lsr a                   ; base
    eor #$FFFF
    sec
    adc z:RR_T              ; v = C -/+ A6' - base
    and #$0FFF
    asl a
    asl a
    tax
    lda f:RoadSTab,x
    sta FS_BG1,y
    lda f:RoadSTab+2,x
    sta FS_WIN,y
    ; colour byte * 2, VOFS row
    lda z:RR_IDX
    clc
    adc z:RR_CTO
    tax
    lda f:RoadColTab,x
    and #$00FF
    asl a
    sta z:RR_CW
    lda z:RR_D
    lsr a
    and #$00FF
    clc                     ; - 1: screen line y shows BG row y + 1 + VOFS
    sbc z:RR_Y
    and #$01FF
    sta z:RR_ROW
    lda z:RR_CW
    and z:F_PMT
    beq :+
    lda #$0100
:   eor z:RR_ROW
    sta FS_BG1+2,y
    ; bottom road
    lda z:F_PMB
    beq @nob
    lda z:RR_X
    sta f:MAL
    lda z:F_COB
    sta f:MBL               ; idx * co (bottom road)
    lda z:RR_CW
    and z:F_PMB
    beq :+
    lda #$0100
:   eor z:RR_ROW
    sta FS_BG2+2,y
    lda z:RR_A6
    eor z:F_MB
    clc
    adc z:F_CB
    sta z:RR_T
    lda f:MR+1
    lsr a
    eor #$FFFF
    sec
    adc z:RR_T
    and #$0FFF
    asl a
    asl a
    tax
    lda f:RoadSTab,x
    sta FS_BG2,y
    lda f:RoadSTab+2,x
    bra @wb
@nob:
    lda #$00FF              ; empty window: BG2 masked
@wb:
    sta FS_WIN+2,y
    ; backdrop: exterior colour of the top road
    lda z:RR_D
    and #$0200
    beq @gnd
    lda z:RR_CW
    and z:F_PMT
    beq :+
    lda #1
:   ora z:F_RC
    bra @col
@gnd:
    lda z:RR_CW
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    ora z:F_GC
@col:
    asl a
    tax
    lda f:PALSN,x
    sta FS_COL+2,y
    inc z:RR_SRC
    inc z:RR_SRC
    inc z:RR_Y
    iny
    iny
    iny
    iny
    cpy #224*4
    bcs :+
    jmp RrFast
:   pld
    plb
    rts

;----------------------------------------------------------------------------
; RoadSnapWait: wait until the S-CPU has copied the posted road inputs (before
; a logic tick that may run ahead of the swap)
;----------------------------------------------------------------------------
.export RoadSnapWait
RoadSnapWait:
:   lda SH_RPEND
    bne :-
    rts

    .ifdef SRFUZZ
;----------------------------------------------------------------------------
; RrFuzz (test builds with SRCHECK): per frame perturbations of the render
; inputs, so that the rare cases (car centred, car offset -32768, inverted
; road, road 1 on top, road_x marker lines) reach both table builders
;----------------------------------------------------------------------------
.import in_tick
RrFuzz:
    lda in_tick
    sta rr_fz
    and #3
    bne :+
    stz rd_co               ; road 0 car centred
:   lda rr_fz
    and #7
    cmp #5
    bne :+
    lda #$8000
    sta rd_co+2
:   lda rr_fz
    and #2
    beq :+
    lda rd_inv+2
    eor #1
    sta rd_inv+2
:   lda rr_fz
    and #1
    beq :+
    lda rd_hwctl
    cmp #1
    bne :+
    lda #2
    sta rd_hwctl
:   lda rr_fz
    and #3
    cmp #2
    bne @x
    ; road_x = MARK for idx = 11 k + (tick & 7)
    lda rr_fz
    and #7
    asl a
    tax
:   lda #MARK
    sta f:RDB*$10000+RD_X,x
    txa
    clc
    adc #22
    tax
    cpx #$0400
    bcc :-
@x: rts
.segment "BSS"
rr_fz: .res 2
.segment "SA1CODE"
    .endif
.endif


;----------------------------------------------------------------------------
; RRInit: both table sets: clear, line headers, constant bytes
;----------------------------------------------------------------------------
RRInit:
    .ifdef NEWGAME
    ; SA-1 staging of the backdrop colours: CGADD bytes 0
    ldx #0
    lda #0
:   sta f:SR_STG+SG_COL,x
    inx
    inx
    cpx #224*4
    bcc :-
    .endif
    .if .not RR_SA1
    stz sc_fgh
    stz sc_fgv
    stz sc_bgh
    stz sc_bgv
    rts
    .else
    ldx #0
    lda #0
:   sta f:HT_BASE,x
    inx
    inx
    cpx #HT_SETSZ*2
    bcc :-
    ldx #0
@hdr:
    sep #$20
    .a8
    lda #$FF                ; repeat mode, 127 lines
    sta f:HT_BASE,x
    lda #$E1                ; repeat mode, 97 lines
    sta f:HT_BASE+1+127*4,x
    lda #$00
    sta f:HT_BASE+2+224*4,x
    rep #$20
    .a16
    txa
    clc
    adc #HT_LEN
    tax
    cmp #HT_LEN*5
    beq :+
    cmp #HT_SETSZ+HT_LEN*5
    bne @hdr
    bra @const
:   ldx #HT_SETSZ
    bra @hdr
@const:
    ; BG3SC / BG4SC bytes of the screen-base table (line bytes 2-3)
    ldx #1
    ldy #0
@c: lda #SC_BG3
    sta f:HT_BASE+HT_SC+2,x
    sta f:HT_BASE+HT_SETSZ+HT_SC+2,x
    inx
    inx
    inx
    inx
    iny
    cpy #127
    bne :+
    inx
:   cpy #224
    bne @c
    stz sc_fgh
    stz sc_fgv
    stz sc_bgh
    stz sc_bgv
    rts
    .endif


.if RR_SA1
;----------------------------------------------------------------------------
; RoadRender: tables of the set SH_BUILD from this tick's road
;----------------------------------------------------------------------------
.ifdef NEWGAME
RoadRenderSA1:
.else
RoadRender:
.endif
    phb
    phd
    lda #rr_dp
    tcd
    ; per frame parameters (DB = $00: BSS reachable)
    lda rd_co
    sta z:RR_CO
    lda rd_co+2
    sta z:RR_CO+2
    lda rd_inv
    sta z:RR_INV
    lda rd_inv+2
    sta z:RR_INV+2
    lda sc_fgh
    sta z:RR_FGH
    lda sc_fgv
    sta z:RR_FGV
    lda sc_bgh
    sta z:RR_BGH
    lda sc_bgv
    sta z:RR_BGV
    lda rd_hwctl
    and #3
    asl a
    tax
    lda f:RrTop,x
    sta z:RR_TOP
    lda f:RrBot,x
    sta z:RR_BOT
    lda rd_colph
    and #$001F
    xba
    asl a
    sta z:RR_CTO
    lda road_p2
    clc
    adc #$0320*2
    sta z:RR_SRC
    lda SH_BUILD
    inc a
    tay                     ; table offset of the line (Y in the line loop)
    stz z:RR_Y
    lda #127                ; lines of the first table
    sta z:RR_N
    sep #$20
    .a8
    lda #$40
    pha
    plb                     ; DB = $40: table stores
    rep #$20
    .a16
RrsLine:
    ldx z:RR_SRC
    lda f:RDB*$10000+RD_Y,x
    bit #$0800
    beq RrsRoad
    ; solid colour line: backdrop entry $780 | c, BG1 / BG2 show the
    ; scenery maps, windows [0, 255]: nothing masked
    and #$007F
    asl a
    tax
    lda f:PALSN+$0780*2-$0400*2,x
    sta T_COL+2,y
    lda z:RR_FGH
    sta T_BG1,y
    lda z:RR_FGV
    sta T_BG1+2,y
    lda z:RR_BGH
    sta T_BG2,y
    lda z:RR_BGV
    sta T_BG2+2,y
    lda #$FF00
    sta T_WIN,y
    sta T_WIN+2,y
    lda #SC_FG | (SC_BG << 8)
    sta T_SC,y
RrsNext:
    lda z:RR_SRC
    inc a
    inc a
    sta z:RR_SRC
    iny
    iny
    iny
    iny
    inc z:RR_Y
    dec z:RR_N
    bne RrsLine
    lda z:RR_Y
    cmp #224
    bcs RrsEnd
    iny                     ; second table header
    lda #224-127
    sta z:RR_N
    bra RrsLine
RrsEnd:
    pld
    plb
    rts
RrsRoad:
    RRBODY T_BG1, T_BG2, T_WIN, T_COL
    lda #SC_ROAD | (SC_ROAD << 8)
    sta T_SC,y
    jmp RrsNext

.endif

;----------------------------------------------------------------------------
; RrRoad: X = road * 2; RR_IDX, RR_X / RR_A6 (road_x[idx], >> 6), RR_ROW,
; RR_CW -> RR_H (HOFS), RR_W (window), RR_V (VOFS).  h = HEval semantics
; (oroad.s):
;   car offset != 0: h = ((idx * co) >> 9) +- (road_x >> 6), marker: +-200
;   car offset == 0: h = inv ? (-road_x) >> 6 : road_x >> 6
; (Y kept: the table offset)
;----------------------------------------------------------------------------

RrRoad:
    RR_ROAD
    rts

;----------------------------------------------------------------------------
; PalSet: X = arcade palette entry ($400-$7FF), A = arcade colour word
;----------------------------------------------------------------------------
PalSet:
    sta pl_a
    txa
    sec
    sbc #$0400
    asl a
    sta pl_o
    tax
    lda pl_a
    sta f:PALAR,x
    and #$00FF
    asl a
    tax
    lda f:ArcSnLo,x
    sta pl_t
    lda pl_a
    xba
    and #$00FF
    asl a
    tax
    lda f:ArcSnHi,x
    ora pl_t
    ldx pl_o
    sta f:PALSN,x
    cpx #$0010              ; entries $400-$407: road colours in CGRAM
    bcs :+
    lda #1
    sta pal_rdirty
:   rts

;----------------------------------------------------------------------------
; PalFlushRoad: queue the road colours when they changed: CGRAM palette 6 / 7
; colours 8-11 = road pixels 0/1/2/7 in stripe phase A / B = arcade entries
; $400/$402/$404/$406 and $401/$403/$405/$407
;----------------------------------------------------------------------------
PAL_ROAD = PAL_BUF + $80
PalFlushRoad:
    .ifdef NEWGAME
    lda scn_pmode
    beq :+
    rts                     ; BG pages own these palette entries until they exit
:
    .endif
    lda pal_rdirty
    bne :+
    rts
:   stz pal_rdirty
    lda f:PALSN+0
    sta f:PAL_ROAD+0
    lda f:PALSN+4
    sta f:PAL_ROAD+2
    lda f:PALSN+8
    sta f:PAL_ROAD+4
    lda f:PALSN+12
    sta f:PAL_ROAD+6
    lda f:PALSN+2
    sta f:PAL_ROAD+8
    lda f:PALSN+6
    sta f:PAL_ROAD+10
    lda f:PALSN+10
    sta f:PAL_ROAD+12
    lda f:PALSN+14
    sta f:PAL_ROAD+14
    lda #.loword(PAL_ROAD)
    sta ptr0
    sep #$20
    .a8
    lda #^PAL_ROAD
    sta ptr0+2
    rep #$20
    .a16
    lda #BL_CGRAM
    ldx #ROAD_PAL_A*16+8
    ldy #8
    jsr QueueUpload
    lda #.loword(PAL_ROAD+8)
    sta ptr0
    lda #BL_CGRAM
    ldx #ROAD_PAL_B*16+8
    ldy #8
    jmp QueueUpload

.segment "RODATA"
RrTop:      .word 0, 0, 2, 2            ; per rd_hwctl: top road * 2
RrBot:      .word $FFFF, 2, 0, $FFFF    ; bottom road * 2
RrRoadCol:  .word $00, $08              ; road colour entry - $400 (per road)
RrGndCol:   .word $20, $30              ; ground colour entry - $400
