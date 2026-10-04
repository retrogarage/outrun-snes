; Road interface of the previous road module, on top of the exact road engine
; (oroad.s), for the game modules not yet ported from DX (they work in SNES
; x units, x0.8 = 205/256):
;
; RoadYAt(z)     = oroad.get_road_y(z) = 223 - (road_y[road_p0 + z] >> 4)
; RoadH0At(z)    = road0_h[z] * 0.8    RoadH1At(z) = road1_h[z] * 0.8
; RoadCurveAt(z) = road_x[z] * 0.8
; FsValue(z)     = rz0 (32-bit) = road_y[road_p0 + z] << 8 (raw height)
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"
.include "gamevars.inc"

.import RD_Y, RD_X, RD_H0, RD_H1
.importzp RDB
.include "road.inc"
.import HEval, SMul16
.importzp mres

.segment "ZEROPAGE"
rz0:        .res 4          ; scratch shared with crash.s / ferrari.s
.exportzp rz0

.segment "BSS"
; placeholders for the previous renderer (removed with it)
road_top:   .res 2
sky_d7:     .res 2
gnd_pal:    .res 32
lb_ofs:     .res 2
scan_rom:   .res 2
knots:      .res 2
knot_n:     .res 2
sg_n:       .res 2
segs:       .res 2
.export road_top, sky_d7, gnd_pal, lb_ofs, scan_rom, knots, knot_n, sg_n, segs

.export RoadTick, RoadScan, RoadInitSection, RoadReset, RoadLineParams
.export RoadYAt, RoadH0At, RoadH1At, RoadCurveAt, FsValue, RoadBuildLUT
.export RoadYRaw, RoadXRaw

.segment "SA1CODE"
.a16
.i16

RoadTick:
    jmp ORoadTick
RoadReset:
    jmp ORoadInit

; the exact engine loads road paths itself (stage / split / end flags)
RoadInitSection:
    rts

; render-time road setup: replaced by the new HDMA builder
RoadScan:
RoadLineParams:
RoadBuildLUT:
    rts

; A = z (0-511) -> X = byte offset into a road_y buffer (road_p0 + 2z)
.macro ZOFS
    and #$01FF
    asl a
.endmacro

RoadYAt:
    ZOFS
    clc
    adc road_p0
    tax
    lda f:RDB*$10000+RD_Y,x
    eor #$8000              ; y >> 4 (arithmetic) = ((y ^ $8000) >> 4) - $800
    lsr a
    lsr a
    lsr a
    lsr a
    eor #$FFFF
    sec
    adc #223 + $800
    rts

FsValue:
    ZOFS
    clc
    adc road_p0
    tax
    lda f:RDB*$10000+RD_Y,x
    pha
    xba
    and #$FF00
    sta rz0
    pla
    xba
    and #$00FF
    bit #$0080
    beq :+
    ora #$FF00
:   sta rz0+2
    rts

; RoadYRaw: A = z -> A = road_y[road_p0 + z] (arcade units)
RoadYRaw:
    ZOFS
    clc
    adc road_p0
    tax
    lda f:RDB*$10000+RD_Y,x
    rts

; RoadXRaw: A = z -> A = road_x[z] (arcade units)
RoadXRaw:
    ZOFS
    tax
    lda f:RDB*$10000+RD_X,x
    rts

RoadH0At:
    ldx #0
    jsr HEval
    bra Scale08
RoadH1At:
    ldx #2
    jsr HEval
    bra Scale08

RoadCurveAt:
    ZOFS
    tax
    lda f:RDB*$10000+RD_X,x
    ; fall into Scale08

; Scale08: A (signed) * 205 / 256
Scale08:
    ldx #205
    jsr SMul16
    lda mres+1
    rts
