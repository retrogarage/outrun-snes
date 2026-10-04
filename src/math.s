; Math helpers for the SA-1 CPU (SA-1 arithmetic unit, MCNT=0 multiply mode)
;
; All routines expect 16-bit A and 16-bit X/Y, DB=$00, and return the same.
; The arithmetic unit stays in multiply mode; division routines switch to
; divide mode and restore multiply mode before returning.
.p816
.smart
.include "sa1.inc"

.export UMul16, SMul16, UMul16x8, UDiv32_16, SDiv32_16, SMul16F, SDiv16u
.exportzp mres, mA, mB, dvd, dvs, drem

.segment "ZEROPAGE"
mres:   .res 4          ; multiply result (32-bit)
mA:     .res 2
mB:     .res 2
dvd:    .res 4          ; dividend / quotient
dvs:    .res 2          ; divisor
drem:   .res 2          ; remainder
msign:  .res 2

.segment "SA1CODE"

;----------------------------------------------------------------------------
; SMul16 / SMul16F: mres = A * X (signed 16x16 -> 32)
;----------------------------------------------------------------------------
.a16
.i16
SMul16:
SMul16F:
    sta MAL
    stx MBL
    nop
    lda MR
    sta z:mres
    lda MR+2
    sta z:mres+2
    rts

;----------------------------------------------------------------------------
; UMul16: mres = A * X (unsigned 16x16 -> 32)
; unsigned = signed + (a<0 ? b : 0)<<16 + (b<0 ? a : 0)<<16
;----------------------------------------------------------------------------
UMul16:
    sta z:mA
    stx z:mB
    sta MAL
    stx MBL
    nop
    lda MR
    sta z:mres
    lda MR+2
    bit z:mA
    bpl :+
    clc
    adc z:mB
:   bit z:mB
    bpl :+
    clc
    adc z:mA
:   sta z:mres+2
    rts

;----------------------------------------------------------------------------
; UMul16x8: mres = A(16, unsigned) * (X & $FF)
;----------------------------------------------------------------------------
UMul16x8:
    sta z:mA
    sta MAL
    txa
    and #$00FF
    sta z:mB
    sta MBL
    nop
    lda MR
    sta z:mres
    lda MR+2
    bit z:mA
    bpl :+
    clc
    adc z:mB
:   sta z:mres+2
    rts

;----------------------------------------------------------------------------
; SDiv16u: A = signed dividend (16), X = unsigned divisor (16)
; -> A = quotient (floor), X = remainder (>= 0). Restores multiply mode.
;----------------------------------------------------------------------------
SDiv16u:
    sep #$20
    .a8
    pha
    lda #1
    sta MCNT
    pla
    rep #$20
    .a16
    sta MAL
    stx MBL
    nop
    nop
    ldx MR+2
    lda MR
    sep #$20
    .a8
    stz MCNT
    rep #$20
    .a16
    rts

;----------------------------------------------------------------------------
; UDiv32_16: dvd(32) / dvs(16) -> dvd = quotient(32), drem = remainder
; (returns A = drem, X = 0).  Divisor 1..$7FFF: the high word through the
; SA-1 divider (when < $8000), then 16 restoring steps on the low word
; (a low word < $8000 under a zero high word: the divider alone).  Divisor
; 0 or >= $8000, high word >= $8000: 32-step shift-subtract.
;----------------------------------------------------------------------------
UDiv32_16:
    ldx z:dvs
    beq @slow
    bmi @slow
    lda z:dvd+2
    beq @h0
    cmp z:dvs
    bcc @hlt                ; high word < divisor: quotient high word 0
    cmp #$8000
    bcc :+
@slow:
    jmp UDiv32_16s
:
    lda #1
    sta MCNT                ; divide
    lda z:dvd+2
    sta MAL
    stx MBL
    nop
    nop
    lda MR
    sta z:dvd+2             ; quotient high word
    lda MR+2                ; remainder (< divisor)
    stz MCNT
    bra @lo
@h0:
    lda z:dvd
    bmi @r0                 ; low word >= $8000: remainder 0, 16 steps
    lda #1
    sta MCNT
    lda z:dvd
    sta MAL
    stx MBL
    nop
    nop
    lda MR
    sta z:dvd
    lda MR+2
    sta z:drem
    stz MCNT
    ldx #0
    rts
@r0:
    lda #0
    bra @lo
@hlt:
    stz z:dvd+2
@lo:
    ; A = remainder r < divisor <= $7FFF (2r + 1 fits 16 bits): quotient
    ; bits rotate into dvd (C = the previous bit)
    clc
    .repeat 16
    rol z:dvd
    rol a
    cmp z:dvs
    bcc :+
    sbc z:dvs
:
    .endrepeat
    rol z:dvd
    sta z:drem
    ldx #0
    rts

; bit loop (divisor 0 or >= $8000, high word >= $8000)
UDiv32_16s:
    stz z:drem
    ldx #32
@loop:
    asl z:dvd
    rol z:dvd+2
    rol z:drem
    bcs @sub
    lda z:drem
    cmp z:dvs
    bcc @next
@sub:
    lda z:drem
    sec
    sbc z:dvs
    sta z:drem
    inc z:dvd
@next:
    dex
    bne @loop
    rts

;----------------------------------------------------------------------------
; SDiv32_16: signed dvd(32) / signed A(16) -> dvd = quotient (trunc toward 0)
;----------------------------------------------------------------------------
SDiv32_16:
    stz z:msign
    cmp #$8000
    bcc :+
    eor #$FFFF
    inc a
    inc z:msign
:   sta z:dvs
    lda z:dvd+2
    bpl :+
    lda z:dvd
    eor #$FFFF
    clc
    adc #1
    sta z:dvd
    lda z:dvd+2
    eor #$FFFF
    adc #0
    sta z:dvd+2
    lda z:msign
    eor #1
    sta z:msign
:   jsr UDiv32_16
    lda z:msign
    beq :+
    lda z:dvd
    eor #$FFFF
    clc
    adc #1
    sta z:dvd
    lda z:dvd+2
    eor #$FFFF
    adc #0
    sta z:dvd+2
:   rts
