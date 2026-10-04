; Debug-only SA-1 NMI handler (linked last so it moves nothing when enabled)
.p816
.smart
.segment "CODE"
.ifdef SA1_NMI_DBG
.export Sa1DbgNmi
;----------------------------------------------------------------------------
; debug: SA-1 NMI (sent by the S-CPU) records where the SA-1 was running:
; $407FF0 PC, $407FF2 PB, $407FF4 S, $407FF6 D, stack page -> $407E00,
; direct page -> $407D00
;----------------------------------------------------------------------------
Sa1DbgNmi:
    rep #$30
    .a16
    .i16
    pha
    phx
    phy
    phb
    phd
    lda #0
    tcd
    pea $0000
    plb
    plb
    lda 11,s                ; PC (after D 2, B 1, Y 2, X 2, A 2, P 1)
    sta f:$407FF0
    lda 13,s
    and #$00FF
    sta f:$407FF2
    tsc
    sta f:$407FF4
    lda 1,s
    sta f:$407FF6
    ldx #0
:   lda $0600,x
    sta f:$407E00,x
    lda $0000,x
    sta f:$407D00,x
    inx
    inx
    cpx #$100
    bne :-
    pld
    plb
    ply
    plx
    pla
    rti
.endif
