; SA-1 core runtime: frame sync with the S-CPU, joypad, profiler
.p816
.smart
.include "sa1.inc"
.include "shared.inc"
.include "globals.inc"

.segment "ZEROPAGE"
frame_count: .res 2
nmi_flag:    .res 2
frame_ready: .res 2
joy_cur:     .res 2
joy_prev:    .res 2
joy_new:     .res 2
tmp0: .res 2
tmp1: .res 2
tmp2: .res 2
tmp3: .res 2
tmp4: .res 2
tmp5: .res 2
tmp6: .res 2
tmp7: .res 2
ptr0: .res 3
ptr1: .res 3
ptr2: .res 3
last_frame: .res 2

.export ProfMark, WaitNmi, WaitFrame, FrameReady, WaitSwap
prof_buf = SH_PROF
.export prof_buf

.segment "SA1CODE"

;----------------------------------------------------------------------------
; ProfMark: X = slot*4 ; records S-CPU frame counter and current V count
;----------------------------------------------------------------------------
.a16
.i16
ProfMark:
    .ifdef DEBUG_IRAM
    stx SH_MSLOT
    lda SH_MREQ
    inc a
    sta SH_MREQ
:   cmp SH_MACK             ; wait for the S-CPU to stamp it
    bne :-
    .endif
    rts

;----------------------------------------------------------------------------
; WaitNmi / WaitFrame: wait for the next S-CPU vblank, update joypad
;----------------------------------------------------------------------------
WaitNmi:
WaitFrame:
    jsr GetFrame
    sta frame_count
:   jsr GetFrame
    cmp frame_count
    beq :-
    sta frame_count
    lda joy_cur
    sta joy_prev
    lda SH_JOY
    sta joy_cur
    eor joy_prev
    and joy_cur
    sta joy_new
    rts

;----------------------------------------------------------------------------
; GetFrame: A = SH_FRAME.  The S-CPU may increment it between the two byte
; reads of a word load (a torn $02FF for $01FF -> $0200), so read until two
; loads agree.
;----------------------------------------------------------------------------
GetFrame:
:   lda SH_FRAME
    cmp SH_FRAME
    bne :-
    rts

;----------------------------------------------------------------------------
; FrameReady: publish the back buffer (S-CPU swaps at next vblank)
; WaitSwap: wait until the S-CPU has consumed it
;----------------------------------------------------------------------------
FrameReady:
    lda SH_UQW
    sta SH_UQT              ; swap only after these streamed uploads
    lda #1
    sta SH_READY
    rts
; FifoWait: wait until the streaming upload FIFO has a free entry (the
; S-CPU drains it every vblank)
.export FifoWait
FifoWait:
:   lda SH_UQR
    sec
    sbc SH_UQW
    dec a
    and #UQ_MASK
    beq :-
    rts

WaitSwap:
:   lda SH_READY
    bne :-
    rts
