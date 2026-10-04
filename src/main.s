; OutRun SNES (SA-1) - S-CPU: header, reset, SA-1 boot, NMI uploads
.p816
.smart
.include "snes.inc"
.include "sa1.inc"
.include "shared.inc"

.import SA1Entry, VideoInit, SndBoot, SndService
.ifdef NEWGAME
.import SrInit              ; road HDMA tables built by the S-CPU (sroad.s)
.endif
.ifdef SA1_NMI_DBG
.import Sa1DbgNmi
.endif
.export ScpuNmi
.import __NMICODE_LOAD__, __NMICODE_RUN__, __NMICODE_SIZE__

FXB_RESET = 3               ; FXB (never changed: sprite runs write EXB + FXB)
; [W4 vblank] upload stream constants (see Stream)
NDESC    = 64               ; descriptors in flight (ring of indexes)
DR_SIZE  = 1400             ; descriptor ring bytes
DMAXD    = 18               ; largest descriptor (H_RUN)
.assert (NDESC - 1) * DMAXD + 2 * DMAXD + 8 <= DR_SIZE, error, "DR_SIZE too small"
OVH_RUN  = 104              ; handler S-CPU time per descriptor (units; Mesen p95)
OVH_EXB  = 9                ; (sprite runs: EXB written: block changed)
OVH_A1T  = 8                ; (sprite runs: bottom halves not right after the top ones)
OVH_ROM  = 56
OVH_BW   = 70
EXEC_OVH = 190              ; Exec: from the time reading to the first handler
SWF_U    = 100              ; StreamRun: the ready frame's swap-follows check
STRY_U   = 90               ; SwapTry before its time reading
SWAP_OVH = 340              ; DoSwap, OAM DMA setup, SwapRegs (units)
QRUN_SH  = 7                ; RunQueue per entry beyond QOVH: 128 units (Mesen: ~110)
REGS_U   = 180              ; after the last upload: H_END, SwapTry's checks
DIR_OVH  = 250              ; Direct: a FIFO entry run without a descriptor (units)
CONV_L   = 4                ; lines before vblank: no tick conversion starts
AV_MARGIN = 64              ; units kept before the deadline
BIGQ     = 34 * 1364 / 8    ; a swap that never fits a vblank: forced blank

.segment "HEADER"
    .byte "SG"              ; maker code
    .byte "ORUN"            ; game code
    .byte 0,0,0,0,0,0,0     ; reserved
    .byte 0                 ; expansion RAM
    .byte 0                 ; special version
    .byte 0                 ; cartridge sub-type
    .byte "OUTRUN SNES PORT     "
    .byte $23               ; map mode: SA-1
    .byte $35               ; SA-1 + RAM + battery
    .ifdef NEWGAME
    .byte $0D               ; ROM 8MB (pre-shrunk sprites, src/sprv3.s) [W1 sprv3]
    .else
    .byte $0C               ; ROM 4MB
    .endif
    .byte $07               ; BW-RAM 128KB
    .byte $01               ; USA
    .byte $33
    .byte $00
    .word $FFFF
    .word $0000

.segment "VECTORS"
    .word 0, 0
    .word .loword(EmptyHandler)    ; COP
    .word .loword(EmptyHandler)    ; BRK
    .word .loword(EmptyHandler)    ; ABORT
    .word .loword(ScpuNmi)         ; NMI
    .word 0
    .word .loword(ScpuIrq)         ; IRQ
    .word 0, 0
    .word .loword(EmptyHandler)
    .word 0
    .word .loword(EmptyHandler)
    .word .loword(EmptyHandler)
    .word .loword(ResetStub)
    .word .loword(EmptyHandler)

.segment "SZEROPAGE": zeropage
s_tmp: .res 6
s_dbgtick: .res 2
s_dbgn: .res 2
s_fblank: .res 2
s_qpass:  .res 2
; [W4 vblank] upload stream state (see Stream): the converter (ConvAll)
; turns FIFO entries into DMA descriptors outside vblank, the NMI runs them
s_wake:   .res 2            ; 1: the idle loop runs SndService (NMI / SA-1 IRQ)
st_bw:    .res 2            ; 1: a converter is between its entries
cv_k:     .res 2            ; descriptors published (index * 2, ring of NDESC)
cv_fifo:  .res 2            ; next FIFO entry to convert
cv_cum:   .res 2            ; cost sum of the converted descriptors (units)
cv_sz:    .res 2            ; (converter scratch)
cv_t:     .res 2
cv_t2:    .res 2
cv_h:     .res 2
cv_o:     .res 2
cv_blk:   .res 2            ; first 64-unit block (di_blk) not assigned yet
cv_lblk:  .res 2            ; EXB block of the last sprite run converted / run
cv_v:     .res 2            ; (run variant: 2 EXB written, 1 A1T written)
ex_k:     .res 2            ; next descriptor to run (index * 2)
ex_cum:   .res 2            ; cost sum of the descriptors run
ex_uqr:   .res 2            ; = SH_UQR (FIFO entries uploaded)
ex_trig:  .res 2            ; MDMAEN = 1 | HDMAEN << 8
ex_av:    .res 2            ; units left for this run
ex_lim:   .res 2            ; descriptor to stop at (index * 2)
ex_n:     .res 2
ex_c:     .res 2            ; descriptors run
ex_lo:    .res 2
ex_hi:    .res 2
ex_stop:  .res 2
ex_sp:    .res 2            ; position of the patched end marker
ex_sw:    .res 2            ; the word it replaced
ex_s:     .res 2            ; stack pointer outside the descriptor ring
ex_t:     .res 2
sw_u:     .res 2            ; swap cost (units)
s_v:      .res 2            ; ReadAvail: V / H counters
s_h:      .res 2            ; (H / 2: high byte 0)
s_r:      .res 2            ; ReadAvail: units kept before the deadline
tk_i:     .res 2            ; converter tick (V timer IRQ) index * 2
rg_mode:  .res 2            ; display registers written for: 0 road, 1 page, $FFFF none
hd_disp:  .res 2            ; SH_DISP of the HDMA table addresses written ($FFFF none)
sw_ok:    .res 2            ; this NMI: 1 = the ready frame may be swapped (SwapTry)
    .ifdef W4STAT
st_v0:    .res 2            ; (test builds: time model check)
st_h0:    .res 2
st_pl:    .res 2
    .endif
ex_ch0:   .res 2            ; 1: DMA channel 0 is set up for VRAM words

.segment "SBSS"
; idle wait stub (WAI / RTS), run from WRAM: while the S-CPU is halted its
; address bus must not point at ROM, or every SA-1 ROM access waits a cycle
s_wait:   .res 2
; [W4 vblank] descriptor rings (low WRAM, bank $00: the NMI runs the
; descriptors with the stack pointer, see Exec)
di_off:   .res NDESC*2      ; position of descriptor k
di_cum:   .res NDESC*4      ; cost sum up to and including descriptor k (twice)
dr_buf:   .res DR_SIZE      ; descriptors (variable size)
di_blk:   .res 1024+16      ; per 64 units of the cost sum (mod 65536): the
                            ; descriptor (index * 2) that holds its start
    .ifdef DEBUG_BW
; debug frame statistics (copied to BW-RAM DBG_AREA+$C00 by the idle loop)
d_vend:   .res 16           ; NMI end line buckets: (V-225)/8 (0-6), 7 = overran
d_lastsw: .res 2
d_swap:   .res 2            ; frames with a swap
d_busy:   .res 2            ; no swap: SA-1 frame not ready
d_upl:    .res 2            ; no swap: streamed uploads pending
d_pace:   .res 2            ; no swap: pacing interval
d_vbl:    .res 2            ; no swap: not enough vblank left
    .endif

.segment "CODE"

EmptyHandler:
    rti

ResetStub:
    sei
    clc
    xce
    rep #$38
    .a16
    .i16
    ldx #$1FFF
    txs
    lda #$0000
    tcd
    sep #$20
    .a8
    lda #$00
    pha
    plb
    lda #$8F
    sta INIDISP
    stz NMITIMEN
    stz HDMAEN
    stz MDMAEN
    jsr InitRegisters
    jsr ClearMemory
    ; ---------------- SA-1 setup ----------------
    lda #$20
    sta CCNT                ; hold SA-1 in reset
    stz SIE
    stz CXB
    lda #1
    sta DXB
    lda #2
    sta EXB
    lda #FXB_RESET
    sta FXB
    lda #1
    sta BMAPS
    lda #$80
    sta SBWE
    stz BWPA
    lda #$FF
    sta SIWP
    ; clear shared I-RAM page
    rep #$20
    .a16
    ldx #0
:   stz $3700,x
    inx
    inx
    cpx #$100
    bne :-
    lda #$0000
    sta f:SND_QW            ; empty sound queue, engine off
    sta f:SND_QR
    sta f:SND_ENGP
    lda #$0080
    sta SH_BRIGHT           ; forced blank until SA-1 is ready
    sta SH_BRIGHTN
    lda #HT_SETSZ
    sta SH_BUILD
    stz SH_DISP
    lda #.loword(SA1Entry)
    sta CRV
    sta CNV
    sta CIV
    .ifdef SA1_NMI_DBG
    lda #.loword(Sa1DbgNmi)
    sta CNV
    .endif
    sep #$20
    .a8
    stz CCNT                ; release SA-1
    ; ---------------- PPU ----------------
    rep #$20
    .a16
    ; [W1 sprv3] NMI / upload code to low WRAM (NMICODE, see ScpuNmi)
    ldx #0
:   lda f:__NMICODE_LOAD__,x
    sta f:__NMICODE_RUN__,x
    inx
    inx
    cpx #__NMICODE_SIZE__ + 1
    bcc :-
    jsr VideoInit
    jsr SndBoot
    rep #$20
    .a16
    .ifdef NEWGAME
    jsr SrInit              ; (sroad.s: WRAM code / tables, HDMA channels, SA-1 IRQ)
    .endif
    ; wait for SA-1 boot flag
:   lda SH_BOOT
    cmp #$55AA
    bne :-
    lda #$60CB              ; WAI / RTS
    sta s_wait
    ; [W4 vblank] upload stream: empty descriptor rings, converter ticks
    jsr StreamReset
    stz z:s_h               ; (ReadAvail writes the low byte only)
    lda #$FFFF
    sta z:rg_mode           ; (display registers: all at the first NMI)
    sta z:hd_disp
    stz z:tk_i
    lda f:TickLines
    sta VTIMEL
    sep #$20
    .a8
    lda #$A1                ; NMI, V timer IRQ (converter ticks), joypad
    sta NMITIMEN
    cli                     ; ScpuIrq: converter ticks, the SA-1 road hand-over
@idle:
    jsr SndService
    .ifdef DEBUG_BW
    ; debug: shared I-RAM page and S-CPU zero page -> BW-RAM DBG_AREA (so an
    ; emulator's battery save file shows them)
    rep #$30
    .a16
    .i16
    ldx #0
:   lda $3700,x
    sta f:DBG_AREA,x
    inx
    inx
    cpx #$100
    bne :-
    ldx #0
:   lda $0000,x
    sta f:DBG_AREA+$100,x
    inx
    inx
    cpx #$40
    bne :-
    ldx #0
:   lda $0100,x
    sta f:DBG_AREA+$C00,x
    inx
    inx
    cpx #$40
    bne :-
    sep #$20
    .a8
    .endif
    .ifdef SA1_NMI_DBG
    ; debug: after SA1_NMI_DBG idle-loop frames (counted in S-CPU WRAM only,
    ; so the SA-1 timing is untouched), interrupt the SA-1 once so it
    ; records where it is (see Sa1DbgNmi)
    rep #$20
    .a16
    inc s_dbgn
    lda s_dbgn
    cmp #SA1_NMI_DBG
    bne :+
    sep #$20
    .a8
    lda #$10
    sta CCNT
    stz CCNT
:   sep #$20
    .a8
    .endif
    .ifdef IRAM_MIRROR
    ; debug: copy SA-1 I-RAM to WRAM $7EF800 from the idle loop (no NMI change)
    rep #$30
    .a16
    .i16
    ldx #0
:   lda $3000,x
    sta f:$7EF800,x
    inx
    inx
    cpx #$800
    bne :-
    sep #$20
    .a8
    .endif
    .ifdef DEBUG_IRAM
    ; profiling service: stamp SA-1 mark requests with the PPU V counter
    rep #$20
    .a16
    lda SH_MREQ
    cmp SH_MACK
    beq @idle8
    sep #$20
    .a8
    lda SLHV
    lda OPVCT
    xba
    lda OPVCT
    and #$01
    xba
    rep #$20
    .a16
    ldx SH_MSLOT
    sta SH_PROF+2,x
    lda SH_FRAME
    sta SH_PROF,x
    lda SH_MREQ
    sta SH_MACK
@idle8:
    sep #$20
    .a8
    .else
:   jsr s_wait              ; WAI in WRAM (see s_wait)
    lda z:s_wake            ; [W4 vblank] (a converter tick: sleep on)
    beq :-
    stz z:s_wake
    .endif
    bra @idle

;----------------------------------------------------------------------------
; [W1 sprv3] The NMI handler and the upload routines below (up to
; InitRegisters) run from low WRAM (segment NMICODE, copied at reset): while
; the S-CPU works in vblank it no longer fetches from ROM, where every access
; stalls the SA-1's own ROM accesses (code, tables).
;
;
; [W4 vblank] Upload stream.  The streaming FIFO (UQ_BUF, SA-1 -> S-CPU) is
; turned into DMA descriptors outside vblank by ConvAll (V timer IRQ ticks
; at TickLines; not while the road IRQ handler builds tables), so in vblank
; the S-CPU only loads DMA registers:
; - a descriptor = its handler's address - 1 and the register words.  Exec
;   points the stack at the first one and RTS starts it: the handlers pull
;   the words into EXB, BMAPS, VMADD, A1T0, A1B0 + DAS0 and start the DMA
;   (STX MDMAEN: MDMAEN = 1, HDMAEN unchanged), then RTS starts the next;
;   H_WRAP goes back to the ring start; H_END (patched in at the descriptor
;   to stop at, restored after) returns to the NMI.  Sprite runs: no EXB
;   word when the block is the previous run's, no second source when the
;   bottom halves follow the top ones in ROM (H_RUNS / H_RUNC / H_RUNSC).
; - costs in units of 8 master cycles (= one DMA byte): bytes * 33 / 32
;   (DRAM refresh) + the handler's S-CPU time (Mesen, conservative).  di_cum
;   is the running sum: one compare tells whether all pending descriptors
;   fit before the deadline (ReadAvail: V / H counters; line 261, 680
;   master cycles in, minus AV_MARGIN and REGS_U); else di_blk (the
;   descriptor at each 64-unit position of the sum) gives the count.
; - the NMI: display registers (on change), a complete frame's swap first
;   (queue + OAM + registers), the descriptors that fit (when the ready
;   frame's uploads and its swap fit together, only those: the swap
;   follows), FIFO entries not converted yet run directly (Direct) while
;   there is time, the swap when its uploads are now done.
; - one converter at a time: ConvAll (ticks) sets st_bw while it works; the
;   NMI runs Direct only when st_bw is clear and the rings are empty.  A
;   published descriptor is complete: its handler word is written last (one
;   store), after the end marker behind it.
;----------------------------------------------------------------------------

.segment "NMICODE"

;----------------------------------------------------------------------------
; NMI (S-CPU): swap to the SA-1's ready frame, stream uploads, registers,
; HDMA, joypad
;----------------------------------------------------------------------------
ScpuNmi:
    rep #$30
    .a16
    .i16
    pha
    phx
    phy
    phb
    phd
    lda #$0000
    tcd
    sep #$20
    .a8
    lda #$00
    pha
    plb
    lda RDNMI
    .ifdef DEBUG_BW
    jsr DbgReadback
    stz z:ex_ch0
    .endif
    rep #$20
    .a16
    lda #1
    sta z:s_wake            ; (idle loop: SndService after the NMI)
    ; 0) bulk load (screen changes, forced blank): nothing else this frame
    lda SH_LOAD
    beq :+
    jsr BulkLoad
    lda #$FFFF
    sta z:rg_mode           ; (display registers: all again)
    sta z:hd_disp
    stz z:ex_ch0
    jmp @joy
:   .ifdef NEWGAME
    lda SH_MENU
    beq :+
    lda #$0001
    sta z:ex_trig
    jsr MenuRegs
    jsr SwapTry
    jsr Stream
    jsr SwapTry
    bra @joy
:
    .endif
    lda SH_VMODE
    beq @road
    ; ---- page mode: static Mode 1 picture on BG1, no HDMA ----
    lda #$0001              ; (MDMAEN; HDMAEN off)
    sta z:ex_trig
    jsr PageRegs            ; registers
    jsr SwapTry             ; 1) a complete frame: swap first
    jsr Stream              ; 2) uploads
    jsr SwapTry             ; 3) its last uploads just done: swap now
    bra @joy
@road:
    lda #$3E01              ; (MDMAEN; HDMAEN channels 1-5)
    sta z:ex_trig
    jsr RoadRegs            ; registers, HDMA tables of the frame shown
    jsr SwapTry             ; 1) a complete frame: swap first
    jsr Stream              ; 2) uploads
    jsr SwapTry             ; 3) its last uploads just done: swap now
@joy:
    ; joypad (auto-read is over by now)
    sep #$20
    .a8
:   lda HVBJOY
    and #$01
    bne :-
    rep #$20
    .a16
    lda JOY1L
    sta SH_JOY
    .ifdef DEBUG_BW
    jsr DbgFrameClass
    .endif
    inc SH_FRAME
    .ifdef DEBUG_IRAM
    ; mirror SA-1 I-RAM ($3000-$37FF) into WRAM $7EF800 for debugging dumps
    lda #$F800
    sta WMADDL
    sep #$20
    .a8
    stz WMADDH
    stz DMAP0
    lda #<WMDATA
    sta BBAD0
    ldx #$3000
    stx A1T0L
    stz A1B0
    ldx #$0800
    stx DAS0L
    lda #$01
    sta MDMAEN
    stz z:ex_ch0
    rep #$20
    .a16
    .endif
    pld
    plb
    ply
    plx
    pla
    rti

;----------------------------------------------------------------------------
; RoadRegs / PageRegs: display registers of the road view / the page mode,
; written when the mode changed; INIDISP (brightness of the frame shown)
; every NMI; RoadRegs: HDMA table addresses when the set shown changed
;----------------------------------------------------------------------------
.a16
.i16
RoadRegs:
    lda z:rg_mode
    beq @m
    stz z:rg_mode
    lda #$FFFF
    sta z:hd_disp
    sep #$20
    .a8
    lda #$09                ; Mode 1, BG3 on top
    sta BGMODE
    stz BG12NBA
    lda #(VR_BG3T >> 12)
    sta BG34NBA
    lda #$17                ; OBJ + BG3 + BG2 + BG1
    sta TM
    lda #$03                ; windows on BG1 / BG2
    sta TMW
    lda #$C3
    sta W12SEL
    stz WBGLOG
    rep #$20
    .a16
@m:
    sep #$20
    .a8
    lda SH_BRIGHT
    sta INIDISP
    rep #$20
    .a16
    lda SH_DISP
    cmp z:hd_disp
    bne :+
    rts
:   sta z:hd_disp
    jmp HdmaSet

.ifdef NEWGAME
MenuRegs:
    lda #2
    sta z:rg_mode
    lda #$0001
    sta z:ex_trig
    sep #$20
    .a8
    stz HDMAEN
    lda #$09
    sta BGMODE
    lda #(VR_BG3T >> 12)
    sta BG34NBA
    lda #SC_BG3
    sta BG3SC
    lda #$04
    sta TM
    stz TMW
    stz CGADD
    stz CGDATA
    stz CGDATA
    lda SH_BRIGHT
    sta INIDISP
    rep #$20
    .a16
    rts
.endif

PageRegs:
    lda z:rg_mode
    cmp #1
    beq @m
    lda #1
    sta z:rg_mode
    lda #$FFFF
    sta z:hd_disp
    sep #$20
    .a8
    stz HDMAEN
    lda #$09
    sta BGMODE
    lda #$40
    sta BG12NBA             ; BG1 tiles at word $0000
    sta BG1SC               ; BG1 map at word $4000
    stz BG1HOFS
    stz BG1HOFS
    lda #$11                ; OBJ + BG1
    sta TM
    stz TMW
    rep #$20
    .a16
@m:
    sep #$20
    .a8
    lda SH_BG1VOFS
    sta BG1VOFS
    lda SH_BG1VOFS+1
    sta BG1VOFS
    lda SH_BRIGHT
    sta INIDISP
    rep #$20
    .a16
    rts

;----------------------------------------------------------------------------
; BulkLoad: run the DMA list at SH_LOADB:SH_LOAD with the screen forced
; blank (lists hold whole screens: tiles, maps, palettes)
;----------------------------------------------------------------------------
.a16
.i16
BulkLoad:
    lda SH_LOAD
    sta s_tmp
    lda SH_LOADB
    sta s_tmp+2
    sep #$20
    .a8
    lda #$80
    sta INIDISP
    stz HDMAEN
    ldy #0
@next:
    lda [s_tmp],y
    cmp #$FF
    beq @done
    sta s_tmp+3             ; type
    iny
    rep #$20
    .a16
    lda [s_tmp],y           ; dest
    tax
    iny
    iny
    lda [s_tmp],y           ; source address
    sta A1T0L
    iny
    iny
    sep #$20
    .a8
    lda [s_tmp],y           ; source bank
    sta A1B0
    iny
    rep #$20
    .a16
    lda [s_tmp],y           ; size
    sta DAS0L
    iny
    iny
    sep #$20
    .a8
    lda s_tmp+3
    cmp #BL_CGRAM
    beq @cg
    cmp #BL_COLUMN
    lda #$80
    bcc :+
    lda #$81                ; column: increment 32
:   sta VMAIN
    stx VMADDL
    lda #<VMDATAL
    sta BBAD0
    lda s_tmp+3
    cmp #BL_FILL
    beq :+
    lda #$01
    bra :++
:   lda #$09                ; fixed source: fill
:   sta DMAP0
    bra @go
@cg:
    txa
    sta CGADD
    stz DMAP0
    lda #<CGDATA
    sta BBAD0
@go:
    lda #$01
    sta MDMAEN
    bra @next
@done:
    rep #$20
    .a16
    stz SH_LOAD
    rts

;----------------------------------------------------------------------------
; HdmaSet: road view HDMA channels 1-5 -> tables of the displayed set
;----------------------------------------------------------------------------
.a16
.i16
HdmaSet:
    .ifdef NEWGAME
    ; tables in WRAM $7F (sroad.s; bank and modes set by SrInit)
    lda SH_DISP
    beq :+
    lda #SR_SETSZ
:   clc
    adc #SR_SETA+SR_TBG1
    sta $4312
    adc #SR_TBG2-SR_TBG1
    sta $4322
    adc #SR_TWIN-SR_TBG2
    sta $4332
    adc #SR_TSC-SR_TWIN
    sta $4352
    adc #SR_TCOL-SR_TSC
    sta $4342
    .else
    lda SH_DISP
    clc
    adc #.loword(HT_BASE)+HT_BG1
    sta $4312
    adc #HT_BG2-HT_BG1
    sta $4322
    adc #HT_WIN-HT_BG2
    sta $4332
    adc #HT_COL-HT_WIN
    sta $4342
    adc #HT_SC-HT_COL
    sta $4352
    .endif
    sep #$20
    .a8
    lda #$3E
    sta HDMAEN
    rep #$20
    .a16
    rts

;----------------------------------------------------------------------------
; ReadV: A16 = current PPU V counter
;----------------------------------------------------------------------------
.a16
.i16
ReadV:
    sep #$20
    .a8
    lda SLHV
    lda STAT78              ; reset the OPHCT/OPVCT byte flip-flops
    lda OPVCT
    xba
    lda OPVCT
    and #$01
    xba
    rep #$20
    .a16
    rts

;----------------------------------------------------------------------------
; ReadAvail: A = units left before the deadline (line 261, 680 master
; cycles in; HDMA starts at line 0), AV_MARGIN and REGS_U (the checks after
; the last upload) kept; 0 when past.  ReadAvailS: for a swap (nothing
; but its own register writes follows it: REGS_U not kept).  s_v = V
; counter (X changed)
;----------------------------------------------------------------------------
.a16
.i16
ReadAvailS:
    lda #AV_MARGIN
    bra :+
ReadAvail:
    lda #AV_MARGIN+REGS_U
:   sta z:s_r
    sep #$20
    .a8
    lda SLHV
    lda STAT78              ; reset the OPHCT/OPVCT byte flip-flops
    lda OPHCT
    sta z:s_h
    lda OPHCT
    lsr a                   ; (C = H bit 8)
    ror z:s_h               ; H / 2: dots * 4 master / 8
    lda OPVCT
    sta z:s_v
    lda OPVCT
    and #$01
    sta z:s_v+1
    rep #$20
    .a16
    lda z:s_v
    sec
    sbc #225
    cmp #261-225+1
    bcs @zero
    asl a
    tax
    lda a:LineUnits,x
    sec
    sbc z:s_h
    bcc @zero
    sbc z:s_r
    bcc @zero
    rts
@zero:
    lda #0
    rts

; units from the start of line 225 + i to the deadline
LineUnits:
    .repeat 37, I
    .word ((261 - 225 - I) * 1364 + 680) / 8
    .endrepeat

;----------------------------------------------------------------------------
; SwapTry: swap to the SA-1's ready frame if its streamed uploads are done,
; its road tables built (NEWGAME), the pacing interval elapsed and the swap
; (queue, OAM, registers) ends before the deadline.  C = 1: swapped.
; sw_ok / sw_u: the frame may be swapped (uploads not checked) / its cost
;----------------------------------------------------------------------------
.a16
.i16
SwapTry:
    stz z:sw_ok
    lda SH_READY
    beq @no
    .ifdef NEWGAME
    lda SH_RBUSY            ; road tables still being built (sroad.s)
    bne @no
    .endif
    lda SH_FRAME
    sec
    sbc SH_LASTSW
    cmp SH_PACE
    bcc @no
    inc z:sw_ok
    ; cost: the queue (SH_QBYTES: bytes + QOVH per entry), RunQueue's own
    ; time, OAM, the rest
    lda #544+SWAP_OVH
    ldx SH_QN
    beq :+
    lda SH_QN
    .repeat QRUN_SH
    asl a
    .endrepeat
    clc
    adc SH_QBYTES
    clc
    adc #544+SWAP_OVH
:   sta z:sw_u
    lda SH_UQR
    cmp SH_UQT
    beq :+
    inc SH_BLOCKED          ; debug: ready but uploads pending
@no:
    clc
    rts
:   jsr ReadAvailS
    cmp z:sw_u
    bcs @go
    ; a swap bigger than a whole vblank would never be accepted (the SA-1
    ; would wait forever): early in vblank, swap under forced blank instead
    lda z:sw_u
    cmp #BIGQ
    bcc @no
    lda z:s_v
    cmp #232
    bcs @no
    sep #$20
    .a8
    lda #$80
    sta INIDISP
    rep #$20
    .a16
    inc z:s_fblank
@go:
    jsr DoSwap
    stz z:sw_ok
    ; the new frame's brightness, HDMA tables
    sep #$20
    .a8
    lda SH_BRIGHT
    sta INIDISP
    rep #$20
    .a16
    .ifdef NEWGAME
    lda SH_MENU
    beq :+
    jsr MenuRegs
    bra @done
:   lda z:rg_mode
    cmp #2
    bne :+
    lda SH_VMODE
    beq @resume_road
    jsr PageRegs
    bra @done
@resume_road:
    lda #$3E01
    sta z:ex_trig
    jsr RoadRegs
    bra @done
:
    .endif
    lda z:rg_mode
    bne @done
    lda SH_DISP
    sta z:hd_disp
    jsr HdmaSet
@done:
    sec
    rts

; DoSwap: line buffer sets, swap queue (palettes), OAM
DoSwap:
    lda SH_BUILD
    sta SH_DISP
    eor #HT_SETSZ
    sta SH_BUILD
    lda SH_QN
    beq :+
    jsr RunQueue
    stz SH_QN
    stz SH_QBYTES
:
    ; OAM
    stz OAMADDL
    lda SH_OAMSRC
    sta A1T0L
    lda #544
    sta DAS0L
    sep #$20
    .a8
    stz DMAP0
    lda #<OAMDATA
    sta BBAD0
    lda #$40
    sta A1B0
    lda #$01
    sta MDMAEN
    rep #$20
    .a16
    stz z:ex_ch0            ; (channel 0: Exec sets it up again)
    lda SH_FRAME
    sta SH_LASTSW
    inc SH_SWAPS
    stz SH_READY
    .ifdef NEWGAME
    lda SH_MENUN
    sta SH_MENU
    lda SH_BRIGHTN          ; the frame's brightness comes with it
    sta SH_BRIGHT
    .endif
    lda z:s_fblank
    beq @no
    stz z:s_fblank
    sep #$20
    .a8
    lda SH_BRIGHT
    sta INIDISP             ; end of the forced blank
    rep #$20
    .a16
@no:
    rts

;----------------------------------------------------------------------------
; Stream: run the converted descriptors that fit before the deadline, then
; (when no converter is mid-entry) convert what is left while there is
; time, and run those.  When the ready frame's uploads and its swap fit
; together, stop after its uploads (SwapTry follows).
;----------------------------------------------------------------------------
.a16
.i16
Stream:
    lda z:st_bw
    bne StreamRun           ; (a converter is mid-entry: run what it published)
    lda SH_UQR
    cmp z:ex_uqr
    beq :+
    jsr StreamReset         ; (FIFO reset by the SA-1: SprV2Init)
:   jsr StreamRun
    lda z:ex_k
    cmp z:cv_k
    bne @out                ; (the time is up)
    ; the rest of the FIFO (not converted yet; the converter is idle, the
    ; descriptor rings are empty): run the entries directly while they fit
@dir:
    lda z:cv_fifo
    cmp SH_UQW
    beq @out
    jsr Direct
    bcs @dir
@out:
    rts

; StreamRun: run the published descriptors that fit
StreamRun:
    lda z:cv_k
    sta z:ex_lim
    jsr ReadAvail
    sta z:ex_av
    .ifdef W4STAT
    lda z:s_v
    sta z:st_v0
    lda z:s_h
    sta z:st_h0
    .endif
    lda z:sw_ok
    beq Exec
    ; the ready frame's entries (to SH_UQT): all converted?
    lda SH_UQT
    sec
    sbc z:ex_uqr
    and #UQ_MASK
    beq Exec
    asl a
    sta z:ex_t              ; descriptors * 2
    lda z:cv_k
    sec
    sbc z:ex_k
    and #NDESC*2-2
    cmp z:ex_t
    bcc Exec                ; (not all: no swap this vblank)
    lda z:ex_t
    clc
    adc z:ex_k
    tax                     ; (mirrored di_cum: no wrap)
    lda a:di_cum-2,x
    sec
    sbc z:ex_cum            ; their cost
    clc
    adc #EXEC_OVH+SWF_U+STRY_U-REGS_U
    clc
    adc z:sw_u
    bcs @max
    cmp z:ex_av
    beq :+
    bcs @max                ; not both: upload as much as fits
:   lda z:ex_t
    clc
    adc z:ex_k
    and #NDESC*2-2
    sta z:ex_lim            ; (the swap follows)
@max:
    lda z:ex_av
    sec
    sbc #SWF_U              ; (the time of this check)
    bcs :+
    lda #0
:   sta z:ex_av
    ; fall through

;----------------------------------------------------------------------------
; Exec: run the descriptors from ex_k (up to ex_lim) that fit before the
; deadline: all of them (one compare of the cost sums), else those before
; the one that holds the cost sum position ex_cum + time left (di_blk: at
; most 64 units given away)
;----------------------------------------------------------------------------
Exec:
    lda z:ex_lim
    sec
    sbc z:ex_k
    and #NDESC*2-2
    bne :+
@none:
    rts
:   sta z:ex_hi             ; pending descriptors * 2
    lda z:ex_av
    sec
    sbc #EXEC_OVH
    bcc @none
    sta z:ex_av
    ; all of them? (di_cum is mirrored: index ex_k + 2 c - 2 without wrap)
    lda z:ex_hi
    clc
    adc z:ex_k
    tax
    lda a:di_cum-2,x
    sec
    sbc z:ex_cum
    cmp z:ex_av
    bcc @all
    beq @all
    ; those before the descriptor at the cost sum position ex_cum + ex_av
    lda z:ex_cum
    clc
    adc z:ex_av
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a                   ; 64-unit block (0-1023)
    tax
    lda a:di_blk,x
    sec
    sbc z:ex_k
    and #NDESC*2-2
    beq @none
    cmp z:ex_hi
    bcs @none               ; (a block before ex_cum: less than 64 units left)
    sta z:ex_lo
    bra @cnt
@all:
    lda z:ex_hi
    sta z:ex_lo
@cnt:
    lda z:ex_lo
    lsr a
    sta z:ex_c              ; descriptors to run
    ; end marker at the descriptor to stop at (restored after)
    lda z:ex_lo
    clc
    adc z:ex_k
    and #NDESC*2-2
    sta z:ex_stop
    tax
    lda a:di_off,x
    sta z:ex_sp
    tax
    lda a:0,x
    sta z:ex_sw
    lda #H_END-1
    sta a:0,x
    ; DMA channel 0: VRAM words
    lda z:ex_ch0
    bne :+
    inc z:ex_ch0
    lda #$0080
    sta VMAIN               ; (VMAIN = $80; VMADDL: set by every descriptor)
    lda #<VMDATAL << 8 | $01
    sta DMAP0               ; DMAP0 = $01, BBAD0 = VMDATAL
:   ; stack = first descriptor - 1, D = DMA registers, X = MDMAEN / HDMAEN
    ldx z:ex_k
    lda a:di_off,x
    dec a
    tay
    phd
    tsc
    sta z:ex_s
    ldx z:ex_trig
    tya
    tcs                     ; (interrupts are off in the NMI)
    lda #$4300
    tcd
    rts                     ; -> the first descriptor's handler

;----------------------------------------------------------------------------
; Direct: run FIFO entry cv_fifo without a descriptor if it fits (NMI, the
; converter idle, the rings empty: cv_fifo = ex_uqr).  C = 1: done
;----------------------------------------------------------------------------
.a16
.i16
Direct:
    lda z:cv_fifo
    asl a
    asl a
    asl a
    tax                     ; FIFO entry offset
    .ifdef NEWGAME
    lda f:UQ_BUF+UQ_BANK,x
    bit #UQ_CLIP << 8
    beq @ordinary
    jsr DirectClip
    bcc :+
    jmp @next
:   rts
@ordinary:
    .endif
    lda f:UQ_BUF+UQ_SIZE,x
    and #$03FF
    sta z:cv_sz             ; bytes (sprite runs: per half)
    lda f:UQ_BUF+UQ_BANK,x
    bpl :+
    lda z:cv_sz
    asl a                   ; (two halves)
    bra :++
:   lda z:cv_sz
:   sta z:cv_t
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc z:cv_t
    adc #DIR_OVH            ; cost
    sta z:cv_t
    phx
    jsr ReadAvail
    plx
    cmp z:cv_t
    bcs :+
    rts                     ; (C = 0: no time)
:   lda z:ex_ch0
    bne :+
    inc z:ex_ch0
    lda #$0080
    sta VMAIN
    lda #<VMDATAL << 8 | $01
    sta DMAP0               ; DMAP0 = $01, BBAD0 = VMDATAL
:   lda f:UQ_BUF+UQ_DEST,x
    sta VMADDL
    lda f:UQ_BUF+UQ_SRC,x
    sta A1T0L
    lda z:cv_sz
    sta DAS0L
    lda f:UQ_BUF+UQ_BANK,x
    sep #$20
    .a8
    sta A1B0
    xba
    bmi @run
    beq :+
    sta BMAPS               ; BW-RAM block at $6000-$7FFF
:   lda #$01
    sta MDMAEN
    bra @next
@run:
    and #$07
    sta EXB                 ; sprite data block at $E0-$EF
    sta z:cv_lblk
    stz z:cv_lblk+1
    lda #$01
    sta MDMAEN              ; top halves
    rep #$20
    .a16
    lda f:UQ_BUF+UQ_DEST,x
    clc
    adc #$0100
    sta VMADDL
    lda f:UQ_BUF+UQ_SIZE,x
    and #$FC00
    lsr a
    lsr a
    lsr a
    lsr a                   ; band pieces * 64 (C = 0)
    adc f:UQ_BUF+UQ_SRC,x
    sta A1T0L
    lda z:cv_sz
    sta DAS0L
    sep #$20
    .a8
    lda #$01
    sta MDMAEN              ; bottom halves
@next:
    rep #$20
    .a16
    lda z:cv_fifo
    inc a
    and #UQ_MASK
    sta z:cv_fifo
    sta z:ex_uqr
    sta SH_UQR
    inc SH_UQDONE
    sec
    rts

;----------------------------------------------------------------------------
; descriptor handlers (D = $4300, DB = $00, X = MDMAEN | HDMAEN << 8)
;----------------------------------------------------------------------------
; H_RUN: sprite run (sprv3.s): EXB | FXB, VMADD, A1T0, A1B0 | DAS0 low,
; DAS0 high, DMA (top halves); VMADD + $100, A1T0, DAS0, DMA (bottom
; halves).  H_RUNS: the same block as the run before (EXB set); H_RUNC /
; H_RUNSC: the bottom halves follow the top ones in ROM (A1T0 is there)
H_RUN:
    pla
    sta a:EXB               ; (EXB = sprite data block, FXB = 3 as set at reset)
H_RUNS:
    pla
    sta a:VMADDL
    pla
    sta z:<A1T0L
    pla
    sta z:<A1B0             ; (A1B0, DAS0 low)
    pla
    sta z:<A1B0+2           ; (DAS0 high; DASB0 unused)
    stx a:MDMAEN
    pla
    sta a:VMADDL
    pla
    sta z:<A1T0L
    pla
    sta z:<DAS0L
    stx a:MDMAEN
    rts
H_RUNC:
    pla
    sta a:EXB
H_RUNSC:
    pla
    sta a:VMADDL
    pla
    sta z:<A1T0L
    pla
    sta z:<A1B0
    pla
    sta z:<A1B0+2
    stx a:MDMAEN
    pla
    sta a:VMADDL
    pla
    sta z:<DAS0L
    stx a:MDMAEN
    rts
; H_BW: BW-RAM source through the $6000 window: BMAPS, then as H_ROM
H_BW:
    pla
    sep #$20
    .a8
    sta a:BMAPS
    rep #$20
    .a16
; H_ROM: VMADD, A1T0, A1B0 | DAS0 low, DAS0 high, DMA
H_ROM:
    pla
    sta a:VMADDL
    pla
    sta z:<A1T0L
    pla
    sta z:<A1B0
    pla
    sta z:<A1B0+2
    stx a:MDMAEN
    rts
.ifdef NEWGAME
.include "streamclip.inc"
.endif
H_WRAP:
    lda #dr_buf-1
    tcs
    rts
H_END:
    lda a:ex_s
    tcs
    pld                     ; D = 0
    lda z:ex_sw
    ldx z:ex_sp
    sta a:0,x               ; (the patched word back)
    lda z:ex_lo             ; (descriptors run * 2)
    clc
    adc z:ex_k
    tax
    lda a:di_cum-2,x
    .ifdef W4STAT
    pha
    sec
    sbc z:ex_cum
    clc
    adc #EXEC_OVH
    sta z:st_pl             ; planned units (from the StreamRun time reading)
    jsr ReadAvail
    lda z:s_v
    cmp #225
    bcs :+
    lda f:$7EF004
    inc a
    sta f:$7EF004     ; count: ended after line 261
    and #7
    asl a
    asl a
    asl a
    tax
    lda z:st_v0
    sta f:$7EF010,x
    lda z:st_h0
    sta f:$7EF012,x
    lda z:st_pl
    sta f:$7EF014,x
    lda z:ex_c
    xba
    ora z:s_v
    sta f:$7EF016,x
    lda z:s_v
    clc
    adc #262
:   sec
    sbc z:st_v0
    sta z:st_v0             ; lines
    lda z:s_h
    sec
    sbc z:st_h0
    asl a
    asl a                   ; dots * 4 master
    sta z:st_h0
    lda z:st_v0
    xba                     ; * 256
    sta z:ex_t
    lda z:st_v0
    asl a
    asl a
    asl a
    asl a
    asl a                   ; * 32 ... lines * 1364 = * 1024 + 256 + 64 + 16 + 4
    pha
    lda z:ex_t
    asl a
    asl a                   ; * 1024
    clc
    adc z:ex_t              ; + 256
    clc
    adc 1,s                 ; + 32 ... (approximation: * 1312 + ...)
    sta z:ex_t
    pla
    asl a                   ; * 64
    clc
    adc z:ex_t
    sta z:ex_t              ; lines * 1376 (~1364)
    lda z:ex_t
    clc
    adc z:st_h0
    lsr a
    lsr a
    lsr a                   ; elapsed units
    sec
    sbc z:st_pl
    bmi :+
    cmp f:$7EF000
    bcc :+
    sta f:$7EF000     ; max (elapsed - planned)
:   lda f:$7EF002
    inc a
    sta f:$7EF002     ; runs
    pla
    .endif
    sta z:ex_cum
    lda z:ex_stop
    sta z:ex_k
    lda z:ex_uqr
    clc
    adc z:ex_c
    and #UQ_MASK
    sta z:ex_uqr
    sta SH_UQR
    lda SH_UQDONE
    clc
    adc z:ex_c
    sta SH_UQDONE           ; (debug count)
    rts

;----------------------------------------------------------------------------
; ConvAll: FIFO entries cv_fifo.. SH_UQW -> descriptors (until the ring of
; indexes is full).  D = 0, DB = $00, A16 / I16.  (V timer IRQ ticks, and
; the NMI when no converter is mid-entry)
;----------------------------------------------------------------------------
.a16
.i16
ConvAll:
    lda #1
    sta z:st_bw
@next:
    lda z:cv_fifo
    cmp SH_UQW
    beq @done
    lda z:cv_k
    inc a
    inc a
    and #NDESC*2-2
    cmp z:ex_k
    beq @done               ; (one index kept free)
    ; not across the start of vblank (the NMI converts what is left)
    jsr ReadV
    cmp #225-CONV_L
    bcc :+
    cmp #225
    bcc @done
:   jsr Conv1
    bra @next
@done:
    stz z:st_bw
    rts

; Conv1: FIFO entry cv_fifo -> descriptor cv_k (at di_off[cv_k], which
; holds an end marker), published.  Cost: bytes * 33 / 32 + handler time
Conv1:
    lda z:cv_fifo
    asl a
    asl a
    asl a
    tax                     ; FIFO entry offset
    ldy z:cv_k
    lda a:di_off,y
    tay                     ; descriptor position
    lda f:UQ_BUF+UQ_BANK,x  ; bank | type << 8
    bpl @plain
    .ifdef NEWGAME
    bit #UQ_CLIP << 8
    beq :+
    jmp ConvClip
:
    .endif
    jmp @run
@plain:
    ; plain: [H_ROM][dest][src][bank | size lo][size hi], H_BW: BMAPS first
    sta z:cv_t
    cmp #$0100
    bcs @bw
    lda f:UQ_BUF+UQ_DEST,x
    sta a:2,y
    lda f:UQ_BUF+UQ_SRC,x
    sta a:4,y
    lda f:UQ_BUF+UQ_SIZE,x
    and #$03FF
    sta z:cv_sz
    xba
    tax                     ; size hi | size lo << 8
    and #$FF00
    ora z:cv_t              ; | bank (type 0)
    sta a:6,y
    txa
    and #$00FF
    sta a:8,y
    lda #10
    sta z:cv_t
    ldx #H_ROM-1
    lda z:cv_sz
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc z:cv_sz
    adc #OVH_ROM            ; (C = 0)
    jmp ConvFin
@bw:
    xba
    and #$00FF
    sta a:2,y               ; BMAPS block
    lda f:UQ_BUF+UQ_DEST,x
    sta a:4,y
    lda f:UQ_BUF+UQ_SRC,x
    sta a:6,y
    lda f:UQ_BUF+UQ_SIZE,x
    and #$03FF
    sta z:cv_sz
    xba
    tax
    and #$FF00
    sta z:cv_t2
    lda z:cv_t
    and #$00FF              ; bank
    ora z:cv_t2
    sta a:8,y
    txa
    and #$00FF
    sta a:10,y
    lda #12
    sta z:cv_t
    ldx #H_BW-1
    lda z:cv_sz
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc z:cv_sz
    adc #OVH_BW             ; (C = 0)
    jmp ConvFin
@run:
    ; [H_RUN][EXB | FXB][dest][src][bank | half lo][half hi][dest + $100]
    ; [src + band pieces * 64][half]; no EXB word when the block is the
    ; last run's, no second source when the bottom halves follow the top ones
    sta z:cv_t              ; bank | type
    stz z:cv_v
    phy
    xba
    and #$0007
    cmp z:cv_lblk
    beq :+
    sta z:cv_lblk
    ora #FXB_RESET << 8     ; (FXB written with it: its reset value)
    sta a:2,y
    iny
    iny
    lda #2
    sta z:cv_v
:   lda f:UQ_BUF+UQ_DEST,x
    sta a:2,y
    clc
    adc #$0100
    sta a:10,y
    lda f:UQ_BUF+UQ_SRC,x
    sta a:4,y
    lda f:UQ_BUF+UQ_SIZE,x
    sta z:cv_t2             ; (the FIFO size word)
    and #$03FF              ; bytes per half
    sta z:cv_sz
    xba
    tax
    and #$FF00
    sta z:cv_o
    lda z:cv_t
    and #$00FF              ; bank
    ora z:cv_o
    sta a:6,y               ; bank | half lo << 8
    txa
    and #$00FF
    sta a:8,y               ; half hi
    lda z:cv_t2
    and #$FC00
    lsr a
    lsr a
    lsr a
    lsr a                   ; band pieces * 64 (C = 0)
    cmp z:cv_sz
    beq :+
    clc
    adc a:4,y               ; + source
    sta a:12,y              ; bottom halves
    iny
    iny
    inc z:cv_v
:   lda z:cv_sz
    sta a:12,y              ; half
    ply
    lda z:cv_v
    asl a
    tax
    lda a:RunDsize,x
    sta z:cv_t
    lda a:RunOvh,x
    sta z:cv_o
    lda a:RunHandler,x
    tax
    lda z:cv_sz             ; cost = 2 * half * 33 / 32 + time
    lsr a
    lsr a
    lsr a
    lsr a
    clc
    adc z:cv_sz
    adc z:cv_sz             ; (C = 0)
    adc z:cv_o
    ; fall through

; ConvFin: A = cost, X = handler word, cv_t = descriptor size, Y = its
; position: cost sums, di_blk, end marker, next position, publish
ConvFin:
    stx z:cv_h
    clc
    adc z:cv_cum
    sta z:cv_cum
    ldx z:cv_k
    sta a:di_cum,x
    sta a:di_cum+NDESC*2,x  ; (mirror: Exec indexes without wrap)
    ; di_blk: the 64-unit blocks that start inside this descriptor
    clc
    adc #63
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta z:cv_t2             ; first block of the next one
    sec
    sbc z:cv_blk
    and #$03FF
    beq @nb
    phy
    tay                     ; blocks
    ldx z:cv_blk
    sep #$20
    .a8
    lda z:cv_k
:   sta a:di_blk,x
    inx
    dey
    bne :-
    rep #$20
    .a16
    ply
    cpx #1024+1
    bcc :++
    ; (past the table end: those entries belong to blocks 0..)
    sep #$20
    .a8
:   dex
    lda a:di_blk,x
    sta a:di_blk-1024,x
    cpx #1024+1
    bcs :-
    rep #$20
    .a16
:   lda z:cv_t2
    and #$03FF
    sta z:cv_blk
@nb:
    ; next position (back to the ring start when a largest one may not fit)
    tya
    clc
    adc z:cv_t
    cmp #dr_buf+DR_SIZE-DMAXD-4
    bcc :+
    tax
    lda #H_WRAP-1
    sta a:0,x
    lda #dr_buf
:   tax
    lda #H_END-1
    sta a:0,x               ; end marker behind it
    lda z:cv_k
    inc a
    inc a
    and #NDESC*2-2
    sta z:cv_t
    txa
    ldx z:cv_t
    sta a:di_off,x          ; where the next one goes
    lda z:cv_h
    sta a:0,y               ; complete: its handler (one store)
    stx z:cv_k              ; published
    lda z:cv_fifo
    inc a
    and #UQ_MASK
    sta z:cv_fifo
    rts

;----------------------------------------------------------------------------
; StreamReset: empty descriptor rings, FIFO position = SH_UQR
;----------------------------------------------------------------------------
StreamReset:
    lda SH_UQR
    and #UQ_MASK
    sta z:ex_uqr
    sta z:cv_fifo
    stz z:ex_k
    stz z:cv_k
    stz z:ex_cum
    stz z:cv_cum
    stz z:cv_blk
    lda #$FFFF
    sta z:cv_lblk           ; (the next run writes EXB)
    stz z:st_bw
    lda #dr_buf
    sta a:di_off
    lda #H_END-1
    sta a:dr_buf
    rts

;----------------------------------------------------------------------------
; ScpuIrq: V timer IRQ (converter tick) or the SA-1 IRQ (NEWGAME: the road
; hand-over, sroad.s SrIrq)
;----------------------------------------------------------------------------
ScpuIrq:
    rep #$20
    .a16
    pha
    sep #$20
    .a8
    lda f:TIMEUP            ; (read clears)
    bmi @tick
    .ifdef NEWGAME
    lda #1
    sta f:s_wake            ; (idle loop: SndService afterwards)
    rep #$20
    .a16
    pla
    jml $7F0000+SR_IRQ      ; road hand-over from the SA-1 (sroad.s SrIrq)
    .else
    rep #$20
    .a16
    pla
    rti
    .endif
@tick:
    rep #$30
    .a16
    .i16
    phx
    phy
    phb
    phd
    lda #$0000
    tcd
    pea $0000
    plb
    plb
    jsr ConvAll
    ; next tick line
    lda z:tk_i
    inc a
    inc a
    cmp #TICK_N*2
    bcc :+
    lda #0
:   sta z:tk_i
    tax
    lda a:TickLines,x
    sta VTIMEL
    pld
    plb
    ply
    plx
    pla
    rti

; sprite run descriptors by variant (2: EXB written, 1: second source)
RunDsize:   .word 14, 16, 16, 18
RunOvh:     .word OVH_RUN-OVH_EXB-OVH_A1T, OVH_RUN-OVH_EXB, OVH_RUN-OVH_A1T, OVH_RUN
RunHandler: .word H_RUNSC-1, H_RUNS-1, H_RUNC-1, H_RUN-1

; V timer lines of the converter ticks (the last one just before vblank)
TickLines:
    .word 96, 150, 196, 216
TICK_N = (* - TickLines) / 2

    .ifdef DEBUG_BW
;----------------------------------------------------------------------------
; debug: classify this frame (end of NMI work) - A16/I16
;----------------------------------------------------------------------------
.a16
.i16
DbgFrameClass:
    jsr ReadV
    cmp #225
    bcc @over
    sec
    sbc #225
    lsr a
    lsr a
    lsr a
    cmp #7
    bcc @b
    lda #6
    bra @b
@over:
    lda #7
@b: asl a
    tax
    inc d_vend,x
    lda SH_SWAPS
    cmp d_lastsw
    beq @noswap
    sta d_lastsw
    inc d_swap
    rts
@noswap:
    lda SH_READY
    bne :+
    inc d_busy
    rts
:   lda SH_UQR
    cmp SH_UQT
    beq :+
    inc d_upl
    rts
:   lda SH_FRAME
    sec
    sbc SH_LASTSW
    cmp SH_PACE
    bcs :+
    inc d_pace
    rts
:   inc d_vbl
    rts

;----------------------------------------------------------------------------
; debug: every 64 frames, DMA CGRAM, OAM and 1KB of VRAM (BG3 map) back to
; BW-RAM DBG_AREA+$200/$400/$800 (start of vblank)
;----------------------------------------------------------------------------
.a8
.i16
DbgReadback:
    lda SH_FRAME
    and #63
    beq :+
    rts
:   stz CGADD
    lda #$80                ; B -> A, one register
    sta DMAP0
    lda #<RDCGRAM
    sta BBAD0
    ldx #.loword(DBG_AREA+$200)
    stx A1T0L
    lda #^DBG_AREA
    sta A1B0
    ldx #512
    stx DAS0L
    lda #$01
    sta MDMAEN
    stz OAMADDL
    stz OAMADDH
    lda #<RDOAM
    sta BBAD0
    ldx #.loword(DBG_AREA+$400)
    stx A1T0L
    ldx #544
    stx DAS0L
    lda #$01
    sta MDMAEN
    lda #$80
    sta VMAIN
    stz VMADDL
    lda #$5C
    sta VMADDH
    lda #$81                ; B -> A, two registers
    sta DMAP0
    lda #<RDVRAML
    sta BBAD0
    ldx #.loword(DBG_AREA+$800)
    stx A1T0L
    ldx #1024
    stx DAS0L
    lda #$01
    sta MDMAEN
    rts
    .endif

;----------------------------------------------------------------------------
; RunQueue: execute DMA uploads listed in SH_Q (A16/I16): palettes first
; (CGRAM uploads must end before the display starts: HDMA rewrites CGADD
; on every line), then VRAM
;----------------------------------------------------------------------------
.a16
.i16
RunQueue:
    stz s_qpass
    jsr RunQueuePass
    lda #1
    sta s_qpass
RunQueuePass:
    ldy #0
@loop:
    cpy SH_QN
    bcc :+
    rts
:   tya
    asl a
    asl a
    asl a
    tax
    lda f:SH_Q+Q_TYPE,x
    and #$00FF
    cmp #1
    beq @cg
    lda s_qpass             ; VRAM: second pass
    bne @do
    bra @skip
@cg:
    lda s_qpass             ; CGRAM: first pass
    beq @do
@skip:
    iny
    bra @loop
@do:
    tya
    asl a
    asl a
    asl a
    tax                     ; entry offset
    lda f:SH_Q+Q_SRC,x
    sta A1T0L
    lda f:SH_Q+Q_SIZE,x
    sta DAS0L
    sep #$20
    .a8
    lda f:SH_Q+Q_SRC+2,x
    sta A1B0
    ; VRAM transfers from BW-RAM go through the $00:6000 window (a direct
    ; bank $4x source can be taken for an SA-1 character conversion DMA)
    lda f:SH_Q+Q_TYPE,x
    cmp #1
    beq @direct
    lda f:SH_Q+Q_SRC+2,x
    and #$F0
    cmp #$40
    bne @direct
    lda f:SH_Q+Q_SRC+2,x
    and #$0F
    asl a
    asl a
    asl a
    sta s_tmp
    lda f:SH_Q+Q_SRC+1,x
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    ora s_tmp
    sta BMAPS
    lda f:SH_Q+Q_SRC+1,x
    and #$1F
    ora #$60
    sta A1T0H
    stz A1B0
@direct:
    lda f:SH_Q+Q_TYPE,x
    bne @notv
    ; VRAM word transfer
    lda #$80
    sta VMAIN
    lda f:SH_Q+Q_DEST,x
    sta VMADDL
    lda f:SH_Q+Q_DEST+1,x
    sta VMADDH
    lda #$01
    sta DMAP0
    lda #<VMDATAL
    sta BBAD0
    bra @go
@notv:
    cmp #1
    bne @notc
    lda f:SH_Q+Q_DEST,x
    sta CGADD
    stz DMAP0
    lda #<CGDATA
    sta BBAD0
    bra @go
@notc:
    ; 2: VRAM low bytes only (VMAIN inc on low), 3: high bytes only, 4: column
    cmp #4
    bne :+
    lda #$81
    sta VMAIN
    lda f:SH_Q+Q_DEST,x
    sta VMADDL
    lda f:SH_Q+Q_DEST+1,x
    sta VMADDH
    lda #$01
    sta DMAP0
    lda #<VMDATAL
    sta BBAD0
    bra @go
:   cmp #2
    bne @hi
    stz VMAIN
    lda f:SH_Q+Q_DEST,x
    sta VMADDL
    lda f:SH_Q+Q_DEST+1,x
    sta VMADDH
    stz DMAP0
    lda #<VMDATAL
    sta BBAD0
    bra @go
@hi:
    lda #$80
    sta VMAIN
    lda f:SH_Q+Q_DEST,x
    sta VMADDL
    lda f:SH_Q+Q_DEST+1,x
    sta VMADDH
    stz DMAP0
    lda #<VMDATAH
    sta BBAD0
@go:
    lda #$01
    sta MDMAEN
    rep #$20
    .a16
    iny
    jmp @loop

.segment "CODE"

;----------------------------------------------------------------------------
; Reset all PPU registers to sane defaults
;----------------------------------------------------------------------------
.a8
.i16
InitRegisters:
    lda #$8F
    sta INIDISP
    stz OBSEL
    stz OAMADDL
    stz OAMADDH
    stz BGMODE
    stz MOSAIC
    stz BG1SC
    stz BG2SC
    stz BG3SC
    stz BG4SC
    stz BG12NBA
    stz BG34NBA
    ldx #BG1HOFS
:   stz a:0,x
    stz a:0,x
    inx
    cpx #BG4VOFS+1
    bne :-
    lda #$80
    sta VMAIN
    stz VMADDL
    stz VMADDH
    stz M7SEL
    lda #$01
    stz M7A
    sta M7A
    stz M7B
    stz M7B
    stz M7C
    stz M7C
    stz M7D
    sta M7D
    stz M7X
    stz M7X
    stz M7Y
    stz M7Y
    stz CGADD
    stz W12SEL
    stz W34SEL
    stz WOBJSEL
    stz WH0
    stz WH1
    stz WH2
    stz WH3
    stz WBGLOG
    stz WOBJLOG
    stz TM
    stz TS
    stz TMW
    stz TSW
    lda #$30
    sta CGWSEL
    stz CGADSUB
    lda #$E0
    sta COLDATA
    stz SETINI
    lda #$FF
    sta WRIO
    rts

;----------------------------------------------------------------------------
; Clear VRAM, CGRAM, OAM, WRAM via DMA (keeps the stack page)
;----------------------------------------------------------------------------
.a8
.i16
ClearMemory:
    lda #$80
    sta VMAIN
    stz VMADDL
    stz VMADDH
    lda #$09
    sta DMAP0
    lda #<VMDATAL
    sta BBAD0
    ldx #.loword(ZeroWord)
    stx A1T0L
    lda #^ZeroWord
    sta A1B0
    ldx #$0000
    stx DAS0L
    lda #$01
    sta MDMAEN
    stz CGADD
    lda #$08
    sta DMAP0
    lda #<CGDATA
    sta BBAD0
    ldx #.loword(ZeroWord)
    stx A1T0L
    ldx #512
    stx DAS0L
    lda #$01
    sta MDMAEN
    stz OAMADDL
    stz OAMADDH
    lda #$08
    sta DMAP0
    lda #<OAMDATA
    sta BBAD0
    ldx #.loword(ZeroWord)
    stx A1T0L
    ldx #544
    stx DAS0L
    lda #$01
    sta MDMAEN
    stz WMADDL
    stz WMADDH
    stz WMADDM
    lda #$08
    sta DMAP0
    lda #<WMDATA
    sta BBAD0
    ldx #.loword(ZeroWord)
    stx A1T0L
    ldx #$1E00
    stx DAS0L
    lda #$01
    sta MDMAEN
    ldx #$2000
    stx WMADDL
    stz WMADDH
    ldx #$E000
    stx DAS0L
    lda #$01
    sta MDMAEN
    stz WMADDL
    stz WMADDM
    lda #$01
    sta WMADDH
    ldx #$0000
    stx DAS0L
    lda #$01
    sta MDMAEN
    rts

ZeroWord:
    .word 0
