; S-CPU: PPU / VRAM initialisation for the road view (Mode 1, see
; docs/renderer.md and the VR_* layout in shared.inc)
;   BG1 / BG2: the two arcade roads on road lines, the arcade FG / BG tile
;              layers on solid (sky) lines (screen base switched per line)
;   BG3: HUD      OBJ: sprites
.p816
.smart
.include "snes.inc"
.include "shared.inc"
.include "road2.inc"

.export VideoInit, RoadVram
.ifndef NEWGAME
.include "hud.inc"
.else
; Retained legacy DMA helpers use only the bank constant, not HUD assets.
HUD_BANK = $0D
.endif

.segment "CODE"

.a16
.i16
VideoInit:
    sep #$20
    .a8
    lda #$8F
    sta INIDISP
    rep #$20
    .a16
    jsr RoadVram
    .ifndef NEWGAME
    ; HUD: BG3 tiles, map rows 1-2, HUD sprite tiles (canvas lines 6-9)
    lda #VR_BG3T
    ldx #.loword(Hud_bg3tiles)
    ldy #HUD_BG3TILES_SIZE
    jsr VramFromHud
    lda #VR_BG3MAP+$20
    ldx #.loword(Hud_bg3map)
    ldy #128
    jsr VramFromHud
    lda #$6600
    ldx #.loword(Hud_objstatic)
    ldy #2048
    jsr VramFromHud
    sep #$20
    .a8
    ; palettes: BG3 -> CGRAM 0-31, HUD sprites -> OBJ palette 0 (CGRAM 128)
    stz CGADD
    ldx #.loword(Hud_bg3pal)
    ldy #64
    jsr CgramFromHud
    lda #128
    sta CGADD
    ldx #.loword(Hud_objpal)
    ldy #32
    jsr CgramFromHud
    .else
    sep #$20
    .a8
    .endif
    ; sprites: 16x16 / 32x32, tiles at VRAM word $6000
    .ifdef NEWGAME
    lda #$03                ; 8/16: distant pillars use narrow OBJ columns
    .else
    lda #$63
    .endif
    sta OBSEL
    ; Mode 1, BG3 on top; BG1/BG2 characters at $0000, BG3 at $5000
    lda #$09
    sta BGMODE
    stz BG12NBA
    lda #(VR_BG3T >> 12)
    sta BG34NBA
    lda #SC_ROAD
    sta BG1SC
    sta BG2SC
    lda #SC_BG3
    sta BG3SC
    stz BG3HOFS
    stz BG3HOFS
    stz BG3VOFS
    stz BG3VOFS
    ; windows: BG1 inside window 1, BG2 inside window 2 (per line by HDMA)
    lda #$C3
    sta W12SEL
    stz WBGLOG
    lda #$03
    sta TMW
    lda #$17                ; OBJ + BG3 + BG2 + BG1
    sta TM
    stz TS
    ; HDMA channels (tables in BW-RAM bank $40, set by the NMI)
    lda #$03                ; ch1: BG1HOFS/BG1VOFS, mode 3
    sta $4310
    lda #<BG1HOFS
    sta $4311
    lda #$03                ; ch2: BG2HOFS/BG2VOFS
    sta $4320
    lda #<BG2HOFS
    sta $4321
    lda #$04                ; ch3: WH0-WH3, mode 4
    sta $4330
    lda #<WH0
    sta $4331
    lda #$03                ; ch4: CGADD x2 / CGDATA x2 (backdrop colour)
    sta $4340
    lda #<CGADD
    sta $4341
    lda #$04                ; ch5: BG1SC-BG4SC, mode 4
    sta $4350
    lda #<BG1SC
    sta $4351
    lda #$40
    sta $4314
    sta $4324
    sta $4334
    sta $4344
    sta $4354
    rep #$20
    .a16
    rts

;----------------------------------------------------------------------------
; RoadVram: road tiles and map, empty scenery maps (forced blank)
;----------------------------------------------------------------------------
.a16
.i16
RoadVram:
    sep #$20
    .a8
    lda #$80
    sta VMAIN
    rep #$20
    .a16
    lda #VR_ROADT
    sta VMADDL
    ldx #.loword(RoadTiles)
    lda #^RoadTiles
    ldy #ROAD_TILES_SIZE
    jsr VramDma
    lda #VR_ROADMAP
    sta VMADDL
    ldx #.loword(RoadMap)
    lda #^RoadMap
    ldy #ROAD_MAP_SIZE
    jsr VramDma
    lda #VR_FGMAP           ; FG + BG scenery maps: tile 0 (transparent)
    sta VMADDL
    sep #$20
    .a8
    lda #$09
    sta DMAP0
    lda #<VMDATAL
    sta BBAD0
    ldx #.loword(VZero)
    stx A1T0L
    lda #^VZero
    sta A1B0
    ldx #$2000
    stx DAS0L
    lda #$01
    sta MDMAEN
    rep #$20
    .a16
    rts

; VramDma: X = source address, A = source bank, Y = bytes (VMADD set)
VramDma:
    sep #$20
    .a8
    sta A1B0
    lda #$01
    sta DMAP0
    lda #<VMDATAL
    sta BBAD0
    stx A1T0L
    sty DAS0L
    lda #$01
    sta MDMAEN
    rep #$20
    .a16
    rts

VZero: .word 0

; VramFromHud: A = VRAM word address, X = source (bank HUD_BANK), Y = bytes
.a16
.i16
VramFromHud:
    sta VMADDL
    sep #$20
    .a8
    lda #$80
    sta VMAIN
    lda #$01
    sta DMAP0
    lda #<VMDATAL
    sta BBAD0
    stx A1T0L
    lda #HUD_BANK
    sta A1B0
    sty DAS0L
    lda #$01
    sta MDMAEN
    rep #$20
    .a16
    rts

; CgramFromHud: X = source (bank HUD_BANK), Y = bytes (CGADD already set)
.a8
CgramFromHud:
    stz DMAP0
    lda #<CGDATA
    sta BBAD0
    stx A1T0L
    lda #HUD_BANK
    sta A1B0
    sty DAS0L
    lda #$01
    sta MDMAEN
    rts
