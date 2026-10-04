; Road renderer, S-CPU part (NEWGAME): the road view HDMA tables (docs/
; renderer.md "Road", arcade semantics in rrender.s) are built by the S-CPU,
; which otherwise idles.  The SA-1 only posts the frame's inputs (rrender.s
; RoadRender: SH_RLN.., SH_RPEND, SH_RBUSY, then the SA-1 -> S-CPU IRQ).
;
; The IRQ handler (SrIrq) runs from WRAM $7F and reads only WRAM, so the
; S-CPU bus stays off the SA-1's ROM / BW-RAM / I-RAM while it works:
;  1. snapshot: DMA the inputs into WRAM (road_y[road_p2 + $320 + y] line
;     words, road_x[512], PALSN $400-$43F and $780-$7FF), clear SH_RPEND.
;     The next logic tick rewrites those arrays: ngmain does not start a
;     tick before SH_RPEND is clear (RoadSnapWait).
;  2. tables of set SH_BUILD, clear SH_RBUSY (TrySwap swaps only after it).
; NMIs interrupt the build (the IRQ runs with I set, NMI preempts it).
;
; Tables (bank $7F, indirect HDMA with data bank $7F), per set:
;  BG1 / BG2 / WIN / SC: one entry per run of up to 127 lines.  Solid lines:
;    non-repeat entries pointing at records (scenery scroll of the frame,
;    windows open, scenery screen bases).  Road lines: repeat entries into
;    the per-line data BG1D / BG2D (HOFS, VOFS) and WIND (WH0-WH3), 4 bytes
;    per line; SC: the road screen bases.  Without a bottom road BG2 points
;    at a zero record (BG2 is masked by the empty window 2 there).
;  COL: fixed: repeat over COLD, per line 0, 0, colour (CGADD x2, CGDATA x2).
;
; Road line, road r in slot s (T = top road -> BG1 / window 1, B = bottom
; road -> BG2 / window 2), idx = d & $1FF, x = road_x[idx], co / inv = the
; road's car offset / invert flag (oroad.s HEval):
;   h = co != 0: ((idx * co) >> 9) + (inv ? -(x >> 6) : x >> 6)
;       co == 0: inv ? (-x) >> 6 : x >> 6;   x == MARK, co != 0: +-200
;   v = ($5C - h) & $FFF -> HOFS, window = RoadSTab[v]
;   VOFS = ((d >> 1) & $FF) - y - 1 + 256 * (colour byte bit r), & $1FF
; Fast path (co != 0 or not inverted, x != MARK): per road a 32-bit value
;   W(idx) = $FFFF + C * $10000 - idx * co * 128,  C = $5C + $200 (inv: - $200)
; gives v = (W >> 16) - A6'  (inv: + A6'),  A6' = (x ^ $8000) >> 6 = (x >> 6)
; + $200 (-floor(y / $10000) = floor(($FFFF - y) / $10000); only bits 16-27
; of W matter).  Road lines come in increasing idx order with small steps:
; W is updated with DT[idx - previous idx] = -delta * co * 128 (0 <= delta
; < 16, table per frame); other steps re-seed W with the PPU multiplier (M7A
; 16 bit x M7B 8 bit signed, usable outside Mode 7): j = idx >> 1, b = idx &
; 1, M7B = j ^ $80 = j - 128, P = co * (j - 128):
;   W = E_b - 256 P,  E_b = $FFFF + C * $10000 - 32768 co - 128 b co.
; M7W: M7A is written as two bytes through the PPU's mode 7 latch, which
; BG1HOFS / BG1VOFS writes also set: an HDMA transfer of channel 1 between
; the two writes replaces M7A's low byte.  Every M7A write is checked (M7B =
; 1: the product is M7A) and repeated if needed; M7B writes are one byte.
; Lines with x == MARK and inverted roads with co = 0 take the exact generic
; code (GLine / GRoad).
.ifdef NEWGAME
.p816
.smart
.include "snes.inc"
.include "sa1.inc"
.include "shared.inc"

.import RoadSTab, RoadColTab
.export SrInit

MARK = $3210                ; road_x "ignore car position" marker

; ---- WRAM bank $7F ----
W_STAB  = $0000             ; RoadSTab copy (v -> HOFS word, window word)
W_CTAB  = $4000             ; RoadColTab copy ([colph][idx] colour byte)
W_CODE  = $8000             ; the code below (SR_IRQ = its entry)
W_CODEMAX = $1000
; snapshot, filled by one DMA stream in this order
W_PS4   = $9000             ; PALSN $400-$43F (road / ground colours)
W_PS7   = $9080             ; PALSN $780-$7FF (solid colours)
W_RX    = $9180             ; road_x[512]
W_LN    = $9580             ; line words, y = 0..223
W_SENT  = $9740             ; $FFFF after the last line
W_VAR   = $9780             ; variables (128 bytes)
W_REC   = $9800             ; constant HDMA records
R_ZERO  = W_REC+0           ; 0, 0, 0, 0
R_WINS  = W_REC+4           ; windows [0, 255] (nothing masked)
R_SCS   = W_REC+8           ; BGnSC of solid lines (scenery maps)
R_SCR   = W_REC+12          ; BGnSC of road lines
R_SCO   = W_REC+16          ; [W1c] BGnSC of road lines with overhead structures on BG2
; per frame road constants (fast path), slot T / B
W_DTT   = $9900             ; DT[0..15], 32 bit
W_DTB   = $9940
W_ET    = $9980             ; E_0, E_1 (32 bit)
W_EB    = $9988
W_WT    = $9990             ; W at the last fast line (32 bit)
W_WB    = $9994
; constant tables indexed by 2 * colour byte (built by SrInit)
W_PH0   = $E000             ; (cb & 1) << 8: VOFS phase of road 0
W_PH1   = $E200             ; (cb & 2) << 7: road 1
W_CIR0  = $E400             ; road colour of top road 0: 2 * (cb & 1)  (PS4 offset)
W_CIR1  = $E600             ; top road 1: 2 * (8 + ((cb >> 1) & 1))
W_CIG0  = $E800             ; ground colour of top road 0: 2 * ($20 + (cb >> 4))
W_CIG1  = $EA00             ; top road 1: 2 * ($30 + (cb >> 4))
W_PX    = $EC00             ; ((cb ^ (cb >> 1)) & 1) << 8: phase of road 0 xor road 1
; table set (SR_SETA + 0 / SR_SETSZ)
S_BG1D  = $0000             ; per line: BG1HOFS, BG1VOFS (top road)
S_BG2D  = $0380             ; per line: BG2HOFS, BG2VOFS (bottom road)
S_WIND  = $0700             ; per line: WH0, WH1, WH2, WH3
S_COLD  = $0A80             ; per line: 0, 0, backdrop colour
S_YR    = $0E00             ; per line (constant): -y - 1, -y - 2
S_RBG1  = SR_TCOL+8         ; record: scenery scroll FG (solid lines)
S_RBG2  = SR_TCOL+12        ; record: scenery scroll BG
.assert S_RBG2 + 4 = SR_SETSZ, error, "set layout"
.assert SR_TBG1 = S_YR + 224 * 4, error, "set layout"
.assert SR_TBG2 - SR_TBG1 >= 3 * 224 + 1, error, "entry table size"
.assert SR_TWIN - SR_TBG2 = SR_TBG2 - SR_TBG1, error, "set layout"
.assert SR_TSC - SR_TWIN = SR_TBG2 - SR_TBG1, error, "set layout"
.assert SR_TCOL - SR_TSC = SR_TBG2 - SR_TBG1, error, "set layout"
.assert SR_SETA + 2 * SR_SETSZ <= W_PH0, error, "WRAM $7F"
W_OHBT  = $D900             ; [W1c] OhbRoad: window words of the lines (staging copy)
.assert SR_SETA + 2 * SR_SETSZ <= W_OHBT && W_OHBT + 224 * 4 <= W_PH0, error, "WRAM $7F (W_OHBT)"

; variables
V_DV    = W_VAR+0           ; line word
V_A6P   = W_VAR+6           ; (road_x ^ $8000) >> 6
V_SB    = W_VAR+8           ; set offset (0 / SR_SETSZ)
V_RUN   = W_VAR+10          ; first line (Y) of the current run
V_TP    = W_VAR+12          ; entry offset in the tables (set offset included)
V_EN    = W_VAR+14          ; Emit: lines left
V_EC    = W_VAR+16          ; Emit: lines of this entry
V_EP    = W_VAR+18          ; Emit: data offset of this entry
V_ET    = W_VAR+20          ; Emit: 0 solid, 1 road
V_HASB  = W_VAR+22          ; bottom road present
V_GX    = W_VAR+24          ; GRoad: road_x
V_GT    = W_VAR+26          ; temp
V_TOP   = W_VAR+28          ; top road (0 / 1)
V_BOT   = W_VAR+30          ; bottom road (0 / 1, $FFFF none)
V_PAR   = W_VAR+32          ; SH_RLN.. copy (SH_RPARN words)
V_LNS   = V_PAR+0
V_CO    = V_PAR+2           ; per road
V_INV   = V_PAR+6
V_CTL   = V_PAR+10
V_PH    = V_PAR+12
V_SCR   = V_PAR+14          ; fgh, fgv, bgh, bgv
V_GCO   = W_VAR+56          ; per slot (T, B): car offset
V_GINV  = W_VAR+60          ; invert flag
V_GR    = W_VAR+64          ; road number
V_PIDX  = W_VAR+68          ; 2 * idx of the last fast line (W_WT / W_WB)
V_EB    = W_VAR+70          ; Reseed: 4 * b
V_JX    = W_VAR+72          ; Reseed: j - 128 (M7B)
V_C     = W_VAR+74          ; SlotSet: C
V_K     = W_VAR+76          ; SlotSet: 32 bit temp
V_RSA   = W_VAR+96          ; first line built by the SA-1 (SH_RSA, 224: none)
V_BUSY  = W_VAR+98          ; set offset + 1 while building (debug / tools)
V_OHBN  = W_VAR+100         ; [W1c] SH_OHBN: lines s..n-1 with the SA-1's BG1 / window data
V_OHBS  = W_VAR+102         ; [W1c] SH_OHBS: s
.assert V_OHBS + 2 <= W_VAR + 128, error, "variables"

; PPU registers with D = $2100
DM7A    = <M7A
DM7B    = <M7B
DMPYL   = <MPYL
DMPYM   = <MPYM

OP_SEC  = $38
OP_CLC  = $18
OP_SBC  = $ED               ; sbc abs
OP_ADC  = $6D               ; adc abs

;----------------------------------------------------------------------------
; macros
;----------------------------------------------------------------------------

; PATCHBR site, target: set the displacement of the bra at site (A8)
.macro PATCHBR site, target
    lda #<(target - (site + 2))
    sta a:site+1
.endmacro

; PATCHBR2 site, target: the same in both road line instances (RLINE 0 / 1)
.macro PATCHBR2 site, target
    PATCHBR .ident(.concat(site, "0")), .ident(.concat(target, "0"))
    PATCHBR .ident(.concat(site, "1")), .ident(.concat(target, "1"))
.endmacro

; STA2 site, off: store A at site + off in both instances
.macro STA2 site, off
    sta a:.ident(.concat(site, "0"))+off
    sta a:.ident(.concat(site, "1"))+off
.endmacro

; M7CO slot: M7A = the slot's car offset (checked, see M7W), then M7B = V_JX
; (A8 inside, A16 out)
.macro M7CO slot
    .local w
    sep #$20
    .a8
w:  lda a:V_GCO+slot*2
    sta z:DM7A
    lda a:V_GCO+slot*2+1
    sta z:DM7A
    lda #1
    sta z:DM7B
    lda z:DMPYL
    cmp a:V_GCO+slot*2
    bne w
    lda a:V_JX
    sta z:DM7B
    rep #$20
    .a16
.endmacro

; RESEED slot, wv, ev: wv = E_b - 256 * co * (j - 128)
.macro RESEED slot, wv, ev
    M7CO slot
    lda z:DMPYL
    xba
    and #$FF00              ; (P & $FF) << 8
    sta a:V_GT
    ldx a:V_EB
    lda a:ev,x
    sec
    sbc a:V_GT
    sta a:wv
    lda a:ev+2,x
    sbc z:DMPYM             ; P >> 8
    sta a:wv+2
.endmacro

; SLOTSET slot, dt, ev: A = the slot's road (0 / 1, $FFFF none): per frame
; values and patches (slot 0 = T, 1 = B)
.macro SLOTSET slot, dt, ev
    .local have, slow, fast, fin, inv0
    sta a:V_GR+slot*2
    cmp #$FFFF
    bne have
    ; (slot B only) no bottom road
    sep #$20
    .a8
    PATCHBR2 "RB", "RT"
    PATCHBR2 "RB2", "RB2none"
    PATCHBR2 "PB", "PBnone"
    PATCHBR RSB, RSBend
    rep #$20
    .a16
    stz a:V_HASB
    jmp fin
have:
    .if slot = 0
    ; VOFS phase table of the top road (bottom road: W_PX)
    xba
    asl a                   ; road * $200
    adc #W_PH0              ; (C = 0)
    STA2 "PT", 1
    .else
    lda #1
    sta a:V_HASB
    .endif
    lda a:V_GR+slot*2
    asl a
    tax
    lda a:V_CO,x
    sta a:V_GCO+slot*2
    lda a:V_INV,x
    sta a:V_GINV+slot*2
    beq fast
    lda a:V_GCO+slot*2
    bne fast
slow:
    ; inverted road, car centred: exact code
    sep #$20
    .a8
    .if slot = 0
    PATCHBR2 "RT", "RTslow"
    PATCHBR RST, RSTend
    .else
    PATCHBR2 "RB", "RBslow"
    PATCHBR2 "RB2", "RB2go"
    PATCHBR2 "PB", "PBgo"
    PATCHBR RSB, RSBend
    .endif
    rep #$20
    .a16
    jmp fin
fast:
    sep #$20
    .a8
    .if slot = 0
    PATCHBR2 "RT", "RTgo"
    PATCHBR RST, RSTgo
    .else
    PATCHBR2 "RB", "RBgo"
    PATCHBR2 "RB2", "RB2go"
    PATCHBR2 "PB", "PBgo"
    PATCHBR RSB, RSBgo
    .endif
    lda a:V_GINV+slot*2
    beq inv0
    lda #OP_CLC
    .if slot = 0
    STA2 "RTci", 0
    .else
    STA2 "RBci", 0
    .endif
    lda #OP_ADC
    .if slot = 0
    STA2 "RTas", 0
    .else
    STA2 "RBas", 0
    .endif
    rep #$20
    .a16
    lda #($5C - $200) & $FFFF
    bra :+
inv0:
    .a8
    lda #OP_SEC
    .if slot = 0
    STA2 "RTci", 0
    .else
    STA2 "RBci", 0
    .endif
    lda #OP_SBC
    .if slot = 0
    STA2 "RTas", 0
    .else
    STA2 "RBas", 0
    .endif
    rep #$20
    .a16
    lda #$5C + $200
:   sta a:V_C
    ; E_0 = $FFFF + C << 16 - 32768 co
    lda a:V_GCO+slot*2
    lsr a                   ; C = co & 1
    lda #0
    ror a                   ; (co & 1) << 15
    eor #$FFFF              ; $FFFF - it (no borrow)
    sta a:ev+0
    lda a:V_GCO+slot*2
    cmp #$8000
    ror a                   ; co >> 1
    eor #$FFFF
    sec
    adc a:V_C               ; C - (co >> 1)
    sta a:ev+2
    ; 128 co (32 bit) -> V_K
    lda a:V_GCO+slot*2
    xba
    and #$FF00
    sta a:V_K+0             ; co << 8 (low word)
    lda a:V_GCO+slot*2
    xba
    and #$00FF
    cmp #$0080
    bcc :+
    ora #$FF00
:   cmp #$8000
    ror a
    sta a:V_K+2
    lda a:V_K+0
    ror a
    sta a:V_K+0             ; (co << 8) >> 1
    ; E_1 = E_0 - 128 co
    lda a:ev+0
    sec
    sbc a:V_K+0
    sta a:ev+4
    lda a:ev+2
    sbc a:V_K+2
    sta a:ev+6
    ; DT[k] = -k * 128 co (low words in A, high words through the table)
    stz a:dt+0
    stz a:dt+2
    lda #0
    .repeat 15, i
    sec
    sbc a:V_K+0
    sta a:dt+i*4+4
    tay
    lda a:dt+i*4+2
    sbc a:V_K+2
    sta a:dt+i*4+6
    tya
    .endrepeat
fin:
.endmacro

; GROAD slot: exact v = $5C - h of the slot's road on line V_DV for the cases
; the fast path does not take: road_x = MARK, or car centred (co = 0).
; -> A = v (not masked).  Y kept.
.macro GROAD slot
    .local co, v
    lda a:V_DV
    and #$01FF
    asl a
    tax
    lda a:W_RX,x
    sta a:V_GX
    lda a:V_GCO+slot*2
    bne co
    ; car centred: h = inv ? (-x) >> 6 : x >> 6
    lda a:V_GX
    ldx a:V_GINV+slot*2
    beq :+
    eor #$FFFF
    inc a
:   eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sec
    sbc #$0200
    bra v
co: ; road_x = MARK (the only other caller): h = inv ? -200 : 200
    lda #MARK >> 6
    ldx a:V_GINV+slot*2
    beq v
    lda #($10000 - (MARK >> 6)) & $FFFF
v:  eor #$FFFF              ; v = $5C - h
    sec
    adc #$005C
.endmacro

.segment "CODE"

;----------------------------------------------------------------------------
; SrInit (boot, forced blank, DB = 0): WRAM copies of the builder code and
; the road tables, constant records and tables of both sets, HDMA channels
; 1-5 (indirect, bank $7F), SA-1 IRQ enable.  The caller then clears I.
;----------------------------------------------------------------------------
.a16
.i16
SrInit:
    php
    rep #$30
    sep #$20
    .a8
    lda #^RoadSTab
    sta A1B0
    rep #$20
    .a16
    lda #W_STAB
    ldx #.loword(RoadSTab)
    ldy #16384
    jsr SrCopy
    sep #$20
    .a8
    lda #^RoadColTab
    sta A1B0
    rep #$20
    .a16
    lda #W_CTAB
    ldx #.loword(RoadColTab)
    ldy #16384
    jsr SrCopy
    sep #$20
    .a8
    lda #^SrImage
    sta A1B0
    rep #$20
    .a16
    lda #W_CODE
    ldx #.loword(SrImage)
    ldy #SrImageEnd - SrImage
    jsr SrCopy
    ; records, end marker
    lda #$FF00
    sta f:$7F0000+R_WINS
    sta f:$7F0000+R_WINS+2
    lda #SC_FG | (SC_BG << 8)
    sta f:$7F0000+R_SCS
    lda #SC_BG3
    sta f:$7F0000+R_SCS+2
    sta f:$7F0000+R_SCR+2
    lda #SC_ROAD | (SC_ROAD << 8)
    sta f:$7F0000+R_SCR
    lda #SC_ROAD | (SC_FG << 8)     ; [W1c] (BG2: the overhead structures' map rows)
    sta f:$7F0000+R_SCO
    lda #SC_BG3
    sta f:$7F0000+R_SCO+2
    lda #$FFFF
    sta f:$7F0000+W_SENT
    ; both sets
    ldx #0
@set:
    ; per line constants: -y - 1, -y - 2
    txy
    lda #$FFFF
@yr:
    sta f:$7F0000+SR_SETA+S_YR,x
    dec a
    sta f:$7F0000+SR_SETA+S_YR+2,x
    inx
    inx
    inx
    inx
    cmp #$10000-224-1
    bne @yr
    tyx
    ; COL: repeat 127 lines over COLD, repeat 97 lines over COLD + 508
    sep #$20
    .a8
    lda #$FF
    sta f:$7F0000+SR_SETA+SR_TCOL+0,x
    lda #$E1
    sta f:$7F0000+SR_SETA+SR_TCOL+3,x
    lda #0
    sta f:$7F0000+SR_SETA+SR_TCOL+6,x
    ; BG1 / BG2 / WIN / SC until the first build: 224 lines of R_ZERO
    lda #127
    sta f:$7F0000+SR_SETA+SR_TBG1+0,x
    sta f:$7F0000+SR_SETA+SR_TBG2+0,x
    sta f:$7F0000+SR_SETA+SR_TWIN+0,x
    sta f:$7F0000+SR_SETA+SR_TSC+0,x
    lda #97
    sta f:$7F0000+SR_SETA+SR_TBG1+3,x
    sta f:$7F0000+SR_SETA+SR_TBG2+3,x
    sta f:$7F0000+SR_SETA+SR_TWIN+3,x
    sta f:$7F0000+SR_SETA+SR_TSC+3,x
    lda #0
    sta f:$7F0000+SR_SETA+SR_TBG1+6,x
    sta f:$7F0000+SR_SETA+SR_TBG2+6,x
    sta f:$7F0000+SR_SETA+SR_TWIN+6,x
    sta f:$7F0000+SR_SETA+SR_TSC+6,x
    rep #$20
    .a16
    txa
    clc
    adc #SR_SETA+S_COLD
    sta f:$7F0000+SR_SETA+SR_TCOL+1,x
    adc #127*4
    sta f:$7F0000+SR_SETA+SR_TCOL+4,x
    lda #R_ZERO
    sta f:$7F0000+SR_SETA+SR_TBG1+1,x
    sta f:$7F0000+SR_SETA+SR_TBG1+4,x
    sta f:$7F0000+SR_SETA+SR_TBG2+1,x
    sta f:$7F0000+SR_SETA+SR_TBG2+4,x
    sta f:$7F0000+SR_SETA+SR_TWIN+1,x
    sta f:$7F0000+SR_SETA+SR_TWIN+4,x
    sta f:$7F0000+SR_SETA+SR_TSC+1,x
    sta f:$7F0000+SR_SETA+SR_TSC+4,x
    cpx #SR_SETSZ
    beq :+
    ldx #SR_SETSZ
    jmp @set
:
    ; tables indexed by 2 * colour byte: VOFS phase per road, backdrop
    ; colour offsets (in PS4) per top road
    ldx #0
@cb:
    txa
    lsr a                   ; colour byte
    pha
    and #1
    xba
    sta f:$7F0000+W_PH0,x   ; (cb & 1) << 8
    pla
    pha
    and #2
    xba
    lsr a
    sta f:$7F0000+W_PH1,x   ; (cb & 2) << 7
    lda 1,s
    lsr a
    eor 1,s
    and #1
    xba
    sta f:$7F0000+W_PX,x    ; ((cb ^ (cb >> 1)) & 1) << 8
    pla
    pha
    and #1
    asl a
    sta f:$7F0000+W_CIR0,x  ; 2 * (cb & 1)
    pla
    pha
    lsr a
    and #1
    ora #8
    asl a
    sta f:$7F0000+W_CIR1,x  ; 2 * (8 + ((cb >> 1) & 1))
    pla
    lsr a
    lsr a
    lsr a
    lsr a
    pha
    ora #$20
    asl a
    sta f:$7F0000+W_CIG0,x  ; 2 * ($20 + (cb >> 4))
    pla
    ora #$30
    asl a
    sta f:$7F0000+W_CIG1,x  ; 2 * ($30 + (cb >> 4))
    inx
    inx
    cpx #512
    bcc @cb
    ; HDMA channels 1-5: indirect, tables and data in bank $7F (the table
    ; addresses are set by HdmaSet in the NMI)
    sep #$20
    .a8
    lda #$43                ; ch1: BG1HOFS / BG1VOFS, mode 3
    sta $4310
    lda #<BG1HOFS
    sta $4311
    lda #$43                ; ch2: BG2HOFS / BG2VOFS
    sta $4320
    lda #<BG2HOFS
    sta $4321
    lda #$44                ; ch3: WH0-WH3, mode 4
    sta $4330
    lda #<WH0
    sta $4331
    lda #$43                ; ch4: CGADD x2 / CGDATA x2 (backdrop colour)
    sta $4340
    lda #<CGADD
    sta $4341
    lda #$44                ; ch5: BG1SC-BG4SC, mode 4
    sta $4350
    lda #<BG1SC
    sta $4351
    lda #$7F
    sta $4314
    sta $4317
    sta $4324
    sta $4327
    sta $4334
    sta $4337
    sta $4344
    sta $4347
    sta $4354
    sta $4357
    ; SA-1 -> S-CPU IRQ (the road hand-over; a request the SA-1 posted
    ; while the S-CPU was still booting stays pending: no SIC here)
    lda #$80
    sta SIE
    plp
    rts

; SrCopy: A = destination in WRAM $7F, X = source, Y = bytes (A1B0 set)
.a16
SrCopy:
    sta WMADDL
    sep #$20
    .a8
    lda #$01
    sta WMADDH
    stz DMAP0
    lda #<WMDATA
    sta BBAD0
    stx A1T0L
    sty DAS0L
    lda #$01
    sta MDMAEN
    rep #$20
    .a16
    rts

;============================================================================
; WRAM code (assembled for $7F:8000, copied there by SrInit)
;============================================================================
SrImage:
.org W_CODE

;----------------------------------------------------------------------------
; SrIrq: SA-1 -> S-CPU IRQ (main.s ScpuIrq jumps here): the road hand-over
;----------------------------------------------------------------------------
SrIrqEntry:
.assert SrIrqEntry = SR_IRQ, error, "SR_IRQ"
    rep #$30
    .a16
    .i16
    pha
    phx
    phy
    phb
    phd
    sep #$20
    .a8
    lda #$80
    sta f:SIC               ; acknowledge
    rep #$20
    .a16
    lda f:SH_RPEND
    beq :+
    pea $7F7F
    plb
    plb                     ; DB = $7F
    jsr SrSnap
    jsr SrTables
:   rep #$30
    pld
    plb
    ply
    plx
    pla
    rti

;----------------------------------------------------------------------------
; SrSnap: copy the frame's inputs to WRAM (DMA channel 7), clear SH_RPEND
;----------------------------------------------------------------------------
SrSnap:
    ldx #SH_RPARN*2-2
:   lda f:SH_RLN,x
    sta a:V_PAR,x
    dex
    dex
    bpl :-
    lda f:SH_OHBN           ; [W1c] overhead structures (lines s..n-1)
    sta a:V_OHBN
    lda f:SH_OHBS
    sta a:V_OHBS
    lda #$4300
    tcd                     ; D = DMA registers (channel 7 at $70)
    lda #W_PS4
    sta f:WMADDL
    sep #$20
    .a8
    lda #$01
    sta f:WMADDH
    stz z:$70               ; A -> B, one register
    lda #<WMDATA
    sta z:$71
    lda #$41                ; BW-RAM bank of PALSN and the road arrays
    sta z:$74
    rep #$20
    .a16
    ; (blocks of at most 256 bytes: an NMI waits for a running DMA)
    lda #.loword(PALSN)
    ldx #128
    jsr SnapDma
    lda #.loword(PALSN)+($780-$400)*2
    ldx #256
    jsr SnapDma
    lda #$F000              ; road_x (oroad.s RD_X)
    ldx #256
    jsr SnapDma
    jsr SnapNext
    jsr SnapNext
    jsr SnapNext
    lda a:V_LNS
    jsr SnapDma
    ldx #192
    jsr SnapNext
    ; lines from SH_RSA on come from the SA-1 (rrender.s RrLines): the line
    ; scan ends there (end marker in the line list)
    lda f:SH_RSA
    sta a:V_RSA
    cmp #224
    bcs :+
    asl a
    tax
    lda #$FFFF
    sta a:W_LN,x
:   lda #0
    sta f:SH_RPEND          ; the SA-1 may run the next tick
SrSnapDone:                 ; (profiling marker, tools: w2 srprof)
    rts
SnapDma:
    sta z:$72               ; A1T7
SnapNext:
    stx z:$75               ; DAS7
    sep #$20
    .a8
    lda #$80
    sta f:MDMAEN
    rep #$20
    .a16
    rts

; RLINE k: fast road line, backdrop colour kind k (0: ground, 1: road
; colour; d & $200), A = d
.macro RLINE k
    and #$01FF
    asl a
    tax                     ; 2 idx
    lda a:W_RX,x
    cmp #MARK
    bne :+
    jmp GLine
:   eor #$8000
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta a:V_A6P             ; (road_x >> 6) + $200
    txa
    sec
    sbc a:V_PIDX            ; 2 (idx - last idx)
    stx a:V_PIDX
    cmp #16*2
    bcc :+
    jsr Reseed              ; (X = 0)
    bra .ident(.sprintf("RB%d", k))
:   asl a
    tax                     ; 4 delta
    ; bottom road (slot B): W += DT[delta], v -> stack
.ident(.sprintf("RB%d", k)): bra .ident(.sprintf("RBgo%d", k))                ; (patched: RBgo / RBslow / RT = no bottom road)
.ident(.sprintf("RBgo%d", k)):
    lda a:W_WB
    clc
    adc a:W_DTB,x
    sta a:W_WB
    lda a:W_WB+2
    adc a:W_DTB+2,x
    sta a:W_WB+2
.ident(.sprintf("RBci%d", k)):
    sec                     ; (patched: sec / clc)
.ident(.sprintf("RBas%d", k)):
    sbc a:V_A6P             ; (patched: sbc / adc)
.ident(.sprintf("RBv%d", k)):
    pha                     ; v of the bottom road
    ; top road (slot T)
.ident(.sprintf("RT%d", k)): bra .ident(.sprintf("RTgo%d", k))                ; (patched: RTgo / RTslow)
.ident(.sprintf("RTgo%d", k)):
    lda a:W_WT
    clc
    adc a:W_DTT,x
    sta a:W_WT
    lda a:W_WT+2
    adc a:W_DTT+2,x
    sta a:W_WT+2
.ident(.sprintf("RTci%d", k)):
    sec
.ident(.sprintf("RTas%d", k)):
    sbc a:V_A6P
.ident(.sprintf("RTv%d", k)):
    and #$0FFF
    asl a
    asl a
    tax
    lda a:W_STAB,x
    sta a:SR_SETA+S_BG1D,y
    lda a:W_STAB+2,x
    sta a:SR_SETA+S_WIND,y
.ident(.sprintf("RB2%d", k)):
    bra .ident(.sprintf("RB2go%d", k))               ; (patched: RB2go / RB2none)
.ident(.sprintf("RB2go%d", k)):
    pla
    and #$0FFF
    asl a
    asl a
    tax
    lda a:W_STAB,x
    sta a:SR_SETA+S_BG2D,y
    lda a:W_STAB+2,x
    sta a:SR_SETA+S_WIND+2,y
    bra .ident(.sprintf("RlTail%d", k))
; exact code for a slot (inverted road, car centred)
.ident(.sprintf("RBslow%d", k)):
    phx
    jsr GRoad1
    plx
    bra .ident(.sprintf("RBv%d", k))
.ident(.sprintf("RTslow%d", k)):
    jsr GRoad0
    bra .ident(.sprintf("RTv%d", k))
.ident(.sprintf("RB2none%d", k)):
    lda #$00FF              ; no bottom road: window 2 empty
    sta a:SR_SETA+S_WIND+2,y
; VOFS of both roads, backdrop colour, next line
.ident(.sprintf("RlTail%d", k)):
    lda a:V_DV
    and #$01FF
    tax
.ident(.sprintf("CT%d", k)):
    lda a:W_CTAB,x          ; (operand: W_CTAB + colour phase * 512)
    and #$00FF
    asl a
    tax                     ; X = 2 * colour byte
    lda a:V_DV
    lsr a
    and #$00FF
    clc
    adc a:SR_SETA+S_YR,y
    and #$01FF              ; rom line - y - 1
.ident(.sprintf("PT%d", k)): eor a:W_PH0,x           ; (operand: phase table of the top road)
    sta a:SR_SETA+S_BG1D+2,y
.ident(.sprintf("PB%d", k)): bra .ident(.sprintf("PBgo%d", k))                ; (patched: PBgo / PBnone)
.ident(.sprintf("PBgo%d", k)):
    eor a:W_PX,x            ; the other road's phase
    sta a:SR_SETA+S_BG2D+2,y
.ident(.sprintf("PBnone%d", k)):
    .ident(.sprintf("CC%d", k)):
    .if k = 0
    lda a:W_CIG0,x          ; (operand: ground colour table of the top road)
    .else
    lda a:W_CIR0,x          ; (operand: road colour table of the top road)
    .endif
    tax
    lda a:W_PS4,x
    sta a:SR_SETA+S_COLD+2,y
    iny
    iny
    iny
    iny
    jmp RoadLoop

.endmacro

;----------------------------------------------------------------------------
; SrTables: HDMA tables of set SH_BUILD from the snapshot
;----------------------------------------------------------------------------
SrTables:
    lda #$2100
    tcd                     ; D = PPU registers (multiplier)
    lda f:SH_BUILD
    beq :+
    lda #SR_SETSZ
:   sta a:V_SB
    inc a
    sta a:V_BUSY
    dec a
    tax
    ; scenery scroll records (solid lines)
    lda a:V_SCR+0
    sta a:SR_SETA+S_RBG1,x
    lda a:V_SCR+2
    sta a:SR_SETA+S_RBG1+2,x
    lda a:V_SCR+4
    sta a:SR_SETA+S_RBG2,x
    lda a:V_SCR+6
    sta a:SR_SETA+S_RBG2+2,x
    jsr OhbCopy             ; [W1c] (lines s..n-1: the SA-1's BG1 / window data)
    ldx a:V_SB
    ; line word reads: Y = set offset + 4 y -> X = Y / 2
    txa
    lsr a
    eor #$FFFF
    sec
    adc #W_LN
    sta a:LN0+1
    sta a:LN1+1
    sta a:LN2+1
    inc a
    inc a
    sta a:LN3+1
    ; colour table phase
    lda a:V_PH
    and #$001F
    xba
    asl a
    adc #W_CTAB             ; (C = 0)
    STA2 "CT", 1
    ; roads: top (slot T) and bottom (slot B)
    lda a:V_CTL
    and #3
    asl a
    tax
    lda a:TopTab,x
    sta a:V_TOP
    lda a:BotTab,x
    sta a:V_BOT
    lda a:V_TOP
    SLOTSET 0, W_DTT, W_ET
    lda a:V_BOT
    SLOTSET 1, W_DTB, W_EB
    ; backdrop colour of road lines: the top road's
    lda a:V_TOP
    xba
    asl a                   ; top * $200
    pha
    adc #W_CIG0             ; (C = 0)
    sta a:CC0+1
    pla
    adc #W_CIR0
    sta a:CC1+1
    lda #$8000
    sta a:V_PIDX            ; W not seeded yet
    ; ---- lines ----
    ldy a:V_SB
    sty a:V_RUN
    sty a:V_TP
    tya
    lsr a
    tax
LN0:
    lda a:W_LN,x            ; (operand: W_LN - set offset / 2)
    bit #$0800
    beq :+
    jmp SolLoop
:   jmp RoadLine

; ---- solid run: backdrop colour $780 | (d & $7F), BG1 / BG2 scenery ----
SolLoop:
    tya
    lsr a
    tax
LN1:
    lda a:W_LN,x
    bmi SolEnd
    bit #$0800
    beq SolToRoad
LN3:
    cmp a:W_LN+2,x          ; (operand: as LN1) next line the same?
    bne @one
    and #$007F              ; (sky lines often come in pairs)
    asl a
    tax
    lda a:W_PS7,x
    sta a:SR_SETA+S_COLD+2,y
    sta a:SR_SETA+S_COLD+6,y
    tya
    clc
    adc #8
    tay
    bra SolLoop
@one:
    and #$007F
    asl a
    tax
    lda a:W_PS7,x
    sta a:SR_SETA+S_COLD+2,y
    iny
    iny
    iny
    iny
    bra SolLoop
SolToRoad:
    jsr EmitSolid
    jmp RoadLoop
SolEnd:
    jsr EmitSolid
    jsr SaTail
    bcc :+
    jsr EmitRoad            ; (the SA-1's lines: one road run)
:   jmp Finish

; ---- road run ----
RoadLoop:
    tya
    lsr a
    tax
LN2:
    lda a:W_LN,x
    bmi RoadEnd
    bit #$0800
    bne :+
    jmp RoadLine
:   jsr EmitRoad
    jmp SolLoop
RoadEnd:
    jsr SaTail              ; (the SA-1's lines continue the run)
    jsr EmitRoad
    jmp Finish

;----------------------------------------------------------------------------
; SaTail: at the end of the line scan (Y): if lines V_RSA..223 come from the
; SA-1, wait until they are ready (SH_RSAD) and DMA them from SR_STG into the
; set, Y = end, C = 1; else C = 0
;----------------------------------------------------------------------------
SaTail:
    lda a:V_RSA
    cmp #224
    bcc :+
    clc
    rts
:
@wait:
    lda f:SH_RSAD
    bne @ready
    ldx #64                 ; (do not keep the bus on the SA-1's I-RAM)
:   dex
    bne :-
    bra @wait
@ready:
    lda #$4300
    tcd                     ; D = DMA registers (channel 7)
    sep #$20
    .a8
    lda #^SR_STG
    sta z:$74
    lda #$01
    sta f:WMADDH
    rep #$20
    .a16
    lda #224
    sec
    sbc a:V_RSA
    asl a
    asl a
    sta a:V_EN              ; bytes per array
    lda a:V_RSA
    asl a
    asl a
    sta a:V_EP              ; 4 * first line
    ldx #0
@arr:
    lda a:V_EP
    clc
    adc a:SaOff,x
    sta a:V_EC
    clc
    adc #.loword(SR_STG)
    sta z:$72               ; A1T7: staging
    lda a:V_EC
    clc
    adc a:V_SB
    adc #SR_SETA            ; (C = 0)
    sta f:WMADDL            ; set array
    lda a:V_EN
    sta z:$75
    sep #$20
    .a8
    lda #$80
    sta f:MDMAEN
    rep #$20
    .a16
    inx
    inx
    cpx #8
    bcc @arr
    lda #$2100
    tcd
    lda a:V_SB
    clc
    adc #224*4
    tay                     ; the line scan ends at line 224
    sec
    rts
SaOff:  .word SG_BG1, SG_BG2, SG_WIN, SG_COL

;----------------------------------------------------------------------------
; [W1c] OhbCopy: lines V_OHBS..V_OHBN-1 of the SA-1's BG1 / window data (SR_STG
; SG_BG1 / SG_WIN, sprv3.s ohb.inc) into the set (DMA channel 7, blocks of
; at most 256 bytes); D kept
;----------------------------------------------------------------------------
OhbCopy:
    lda a:V_OHBN
    bne :+
    rts
:   phd
    lda #$4300
    tcd                     ; D = DMA registers (channel 7)
    sep #$20
    .a8
    lda #^SR_STG
    sta z:$74
    lda #$01
    sta f:WMADDH
    rep #$20
    .a16
    ldx #0
@arr:
    lda a:V_OHBN
    sec
    sbc a:V_OHBS
    asl a
    asl a
    sta a:V_EN              ; bytes left
    lda a:V_OHBS
    asl a
    asl a
    sta a:V_GT              ; (4 s)
    clc
    adc a:OhbOff,x
    sta a:V_EP              ; staging offset
    lda a:V_SB
    clc
    adc a:OhbSet,x
    adc a:V_GT              ; (C = 0)
    sta a:V_EC              ; set address
@blk:
    lda a:V_EP
    clc
    adc #.loword(SR_STG)
    sta z:$72               ; A1T7
    lda a:V_EC
    sta f:WMADDL
    lda a:V_EN
    cmp #256
    bcc :+
    lda #256
:   sta z:$75               ; DAS7
    sta a:V_GT
    sep #$20
    .a8
    lda #$80
    sta f:MDMAEN
    rep #$20
    .a16
    lda a:V_EP
    clc
    adc a:V_GT
    sta a:V_EP
    lda a:V_EC
    clc
    adc a:V_GT
    sta a:V_EC
    lda a:V_EN
    sec
    sbc a:V_GT
    sta a:V_EN
    bne @blk
    inx
    inx
    cpx #4
    bcc @arr
    pld
    rts
OhbOff: .word SG_BG1, SG_WIN
OhbSet: .word SR_SETA+S_BG1D, SR_SETA+S_WIND

;----------------------------------------------------------------------------
; [W1c] OhbRoad: road lines [V_RUN, V_GT) (set offsets + 4 y) without a
; bottom road: BG2 scroll <- the SA-1's per-line BG1 words (SR_STG SG_BG1),
; window 2 (WH2 / WH3) <- the low word of its window words (DMA into W_OHBT,
; then copied in WRAM); D kept
;----------------------------------------------------------------------------
OhbRoad:
    phd
    lda #$4300
    tcd
    lda a:V_GT
    sec
    sbc a:V_RUN
    sta a:V_EN              ; bytes
    lda a:V_RUN
    sec
    sbc a:V_SB
    sta a:V_EP              ; 4 * first line
    sep #$20
    .a8
    lda #^SR_STG
    sta z:$74
    lda #$01
    sta f:WMADDH
    rep #$20
    .a16
    ; BG2 scroll words
    lda a:V_EP
    clc
    adc #.loword(SR_STG)+SG_BG1
    sta z:$72
    lda a:V_RUN
    clc
    adc #SR_SETA+S_BG2D
    sta f:WMADDL
    lda a:V_EN
    sta z:$75
    sep #$20
    .a8
    lda #$80
    sta f:MDMAEN
    rep #$20
    .a16
    ; window words -> W_OHBT
    lda a:V_EP
    clc
    adc #.loword(SR_STG)+SG_WIN
    sta z:$72
    lda #W_OHBT
    sta f:WMADDL
    lda a:V_EN
    sta z:$75
    sep #$20
    .a8
    lda #$80
    sta f:MDMAEN
    rep #$20
    .a16
    pld
    ldx a:V_RUN
    ldy #0
:   lda a:W_OHBT,y
    sta a:SR_SETA+S_WIND+2,x
    inx
    inx
    inx
    inx
    iny
    iny
    iny
    iny
    cpx a:V_GT
    bcc :-
    rts
.assert SG_BG2 = S_BG2D - S_BG1D && SG_WIN = S_WIND - S_BG1D && SG_COL = S_COLD - S_BG1D, error, "staging layout"

;----------------------------------------------------------------------------
; RoadLine: A = d (road line), Y = set offset + 4 y
;----------------------------------------------------------------------------
RoadLine:
    sta a:V_DV
    bit #$0200
    beq :+
    jmp RoadLine1
:
RoadLine0:
    RLINE 0
RoadLine1:
    RLINE 1

;----------------------------------------------------------------------------
; GLine: road line with road_x = MARK (V_DV set): exact code for both roads
; (W_WT / W_WB and V_PIDX stay those of the last fast line)
;----------------------------------------------------------------------------
GLine:
    lda a:V_HASB
    bne :+
    lda #$00FF
    sta a:SR_SETA+S_WIND+2,y
    bra @top
:   jsr GRoad1
    and #$0FFF
    asl a
    asl a
    tax
    lda a:W_STAB,x
    sta a:SR_SETA+S_BG2D,y
    lda a:W_STAB+2,x
    sta a:SR_SETA+S_WIND+2,y
@top:
    jsr GRoad0
    and #$0FFF
    asl a
    asl a
    tax
    lda a:W_STAB,x
    sta a:SR_SETA+S_BG1D,y
    lda a:W_STAB+2,x
    sta a:SR_SETA+S_WIND,y
    lda a:V_DV
    bit #$0200
    beq :+
    jmp RlTail1
:   jmp RlTail0

GRoad0:
    GROAD 0
    rts
GRoad1:
    GROAD 1
    rts

;----------------------------------------------------------------------------
; Reseed: X = 2 idx: W_WT / W_WB of this idx (fast slots) -> X = 0
;----------------------------------------------------------------------------
Reseed:
    txa
    lsr a
    lsr a                   ; j, C = b
    eor #$0080
    sta a:V_JX              ; j - 128
    lda #0
    rol a
    asl a
    asl a
    sta a:V_EB              ; 4 b
RST:
    bra RSTgo               ; (patched: RSTgo / RSTend)
RSTgo:
    RESEED 0, W_WT, W_ET
RSTend:
RSB:
    bra RSBgo               ; (patched: RSBgo / RSBend)
RSBgo:
    RESEED 1, W_WB, W_EB
RSBend:
    ldx #0
    rts

;----------------------------------------------------------------------------
; Finish: end the entry tables, the set is complete
;----------------------------------------------------------------------------
Finish:
    ldx a:V_TP
    sep #$20
    .a8
    lda #0
    sta a:SR_SETA+SR_TBG1,x
    sta a:SR_SETA+SR_TBG2,x
    sta a:SR_SETA+SR_TWIN,x
    sta a:SR_SETA+SR_TSC,x
    rep #$20
    .a16
    lda #0
    sta a:V_BUSY
    .ifdef SRCHECK
    sta f:DBG_AREA+$10      ; (SRCHECK: see rrender.s RoadRender)
    .endif
    sta f:SH_RBUSY
SrDone:                     ; (profiling marker)
    rts

;----------------------------------------------------------------------------
; EmitSolid / EmitRoad: entries of the lines [V_RUN, Y); V_RUN = Y after
;----------------------------------------------------------------------------
EmitSolid:
    lda a:V_OHBN            ; [W1c] the top run with overhead structures: its
    beq @sol                ; lines s..n-1 take the SA-1's BG1 / window data
    lda a:V_RUN
    cmp a:V_SB
    bne @sol
    phy
    lda a:V_OHBS            ; lines 0..s-1: solid
    asl a
    asl a
    adc a:V_SB              ; (C = 0)
    cmp 1,s
    bcc :+
    lda 1,s
:   tay
    lda #0
    jsr Emit
    lda a:V_OHBN            ; lines s..n-1: the structures
    asl a
    asl a
    adc a:V_SB              ; (C = 0) set offset + 4 n
    cmp 1,s
    bcc :+
    lda 1,s                 ; (at most the run)
:   tay
    lda #2
    jsr Emit
    ply
@sol:
    lda #0
    bra Emit
EmitRoad:
    lda a:V_OHBN            ; [W1c] overhead structures over road lines (lines
    beq @rd                 ; s..n-1: the SA-1 found BG2 free - no bottom road,
    lda a:V_OHBN            ; or the bottom road the same as the top one)
    asl a
    asl a
    adc a:V_SB              ; (C = 0) set offset + 4 n
    cmp a:V_RUN
    beq @rd
    bcc @rd                 ; (the run starts at line n or below)
    phy
    pha
    lda a:V_OHBS            ; lines of the run before s: road
    asl a
    asl a
    adc a:V_SB              ; (C = 0)
    cmp 3,s
    bcc :+
    lda 3,s
:   cmp a:V_RUN
    bcc :+
    beq :+
    tay
    lda #1
    jsr Emit
:   pla
    cmp 1,s
    bcc :+
    lda 1,s                 ; (at most the run)
:   sta a:V_GT
    cmp a:V_RUN
    beq :+
    bcc :+
    jsr OhbRoad
    ldy a:V_GT
    lda #3
    jsr Emit
:   ply
@rd:
    lda #1
Emit:
    sta a:V_ET
    tya
    sec
    sbc a:V_RUN
    bne :+
    rts                     ; (no lines)
:   lsr a
    lsr a
    sta a:V_EN
    lda a:V_RUN
    sta a:V_EP
    sty a:V_RUN
    ldx a:V_TP
@chunk:
    lda a:V_EN
    cmp #128
    bcc :+
    lda #127
:   sta a:V_EC
    lda a:V_ET
    bne :+
    jmp @solid
:   cmp #3
    bne :+
    jmp @ohbr
:   cmp #2
    bne @road
    ; [W1c] overhead structures: BG1 / WIN per line (the SA-1's data), BG2
    ; and SC as on solid lines
    lda a:V_EP
    clc
    adc #SR_SETA+S_BG1D
    sta a:SR_SETA+SR_TBG1+1,x
    adc #S_WIND-S_BG1D
    sta a:SR_SETA+SR_TWIN+1,x
    lda a:V_SB
    clc
    adc #SR_SETA+S_RBG2
    sta a:SR_SETA+SR_TBG2+1,x
    lda #R_SCS
    sta a:SR_SETA+SR_TSC+1,x
    sep #$20
    .a8
    lda a:V_EC
    sta a:SR_SETA+SR_TBG2,x
    sta a:SR_SETA+SR_TSC,x
    ora #$80
    sta a:SR_SETA+SR_TBG1,x
    sta a:SR_SETA+SR_TWIN,x
    rep #$20
    .a16
    clc
    jmp @next
@road:
    ; road: BG1 / WIN (/ BG2) per line, SC constant
    lda a:V_EP
    clc
    adc #SR_SETA+S_BG1D
    sta a:SR_SETA+SR_TBG1+1,x
    adc #S_WIND-S_BG1D
    sta a:SR_SETA+SR_TWIN+1,x
    lda #R_SCR
    sta a:SR_SETA+SR_TSC+1,x
    sep #$20
    .a8
    lda a:V_EC
    sta a:SR_SETA+SR_TSC,x
    ora #$80
    sta a:SR_SETA+SR_TBG1,x
    sta a:SR_SETA+SR_TWIN,x
    ldy a:V_HASB
    beq @nob
    sta a:SR_SETA+SR_TBG2,x
    rep #$20
    .a16
    lda a:V_EP
    clc
    adc #SR_SETA+S_BG2D
    sta a:SR_SETA+SR_TBG2+1,x
    bra @next
@nob:
    .a8
    lda a:V_EC
    sta a:SR_SETA+SR_TBG2,x
    rep #$20
    .a16
    lda #R_ZERO
    sta a:SR_SETA+SR_TBG2+1,x
    bra @next
@ohbr:
    ; [W1c] road lines with overhead structures: as road lines, BG2 per line
    ; (OhbRoad: the SA-1's data), its screen base the FG map
    lda a:V_EP
    clc
    adc #SR_SETA+S_BG1D
    sta a:SR_SETA+SR_TBG1+1,x
    adc #S_WIND-S_BG1D
    sta a:SR_SETA+SR_TWIN+1,x
    lda a:V_EP
    clc
    adc #SR_SETA+S_BG2D
    sta a:SR_SETA+SR_TBG2+1,x
    lda #R_SCO
    sta a:SR_SETA+SR_TSC+1,x
    sep #$20
    .a8
    lda a:V_EC
    sta a:SR_SETA+SR_TSC,x
    ora #$80
    sta a:SR_SETA+SR_TBG1,x
    sta a:SR_SETA+SR_TWIN,x
    sta a:SR_SETA+SR_TBG2,x
    rep #$20
    .a16
    clc
    jmp @next
@solid:
    sep #$20
    .a8
    lda a:V_EC
    sta a:SR_SETA+SR_TBG1,x
    sta a:SR_SETA+SR_TBG2,x
    sta a:SR_SETA+SR_TWIN,x
    sta a:SR_SETA+SR_TSC,x
    rep #$20
    .a16
    lda a:V_SB
    clc
    adc #SR_SETA+S_RBG1
    sta a:SR_SETA+SR_TBG1+1,x
    adc #S_RBG2-S_RBG1
    sta a:SR_SETA+SR_TBG2+1,x
    lda #R_WINS
    sta a:SR_SETA+SR_TWIN+1,x
    lda #R_SCS
    sta a:SR_SETA+SR_TSC+1,x
@next:
    inx
    inx
    inx
    lda a:V_EC
    asl a
    asl a
    adc a:V_EP              ; (C = 0)
    sta a:V_EP
    lda a:V_EN
    sec
    sbc a:V_EC
    sta a:V_EN
    beq :+
    jmp @chunk
:   stx a:V_TP
    ldy a:V_RUN
    rts


;----------------------------------------------------------------------------
TopTab: .word 0, 0, 1, 1                ; per rd_hwctl: top road
BotTab: .word $FFFF, 1, 0, $FFFF        ; bottom road

.assert * <= W_CODE + W_CODEMAX, error, "S-CPU road code too big"
.reloc
SrImageEnd:

.endif
