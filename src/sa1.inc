; SA-1 register definitions
.ifndef SA1_INC
SA1_INC = 1

; ---- S-CPU side (write) ----
CCNT    = $2200     ; SA-1 control: b7 IRQ, b6 wait, b5 reset, b4 NMI, b3-0 msg
SIE     = $2201     ; S-CPU interrupt enable
SIC     = $2202     ; S-CPU interrupt clear
CRV     = $2203     ; SA-1 reset vector (16-bit)
CNV     = $2205     ; SA-1 NMI vector
CIV     = $2207     ; SA-1 IRQ vector
CXB     = $2220
DXB     = $2221
EXB     = $2222
FXB     = $2223
BMAPS   = $2224     ; S-CPU BW-RAM window block
SBWE    = $2226     ; S-CPU BW-RAM write enable (b7)
BWPA    = $2228     ; BW-RAM write protected area
SIWP    = $2229     ; S-CPU I-RAM write protection (1 = writable, per 256 bytes)
; ---- SA-1 side (write) ----
SCNT    = $2209
CIE     = $220A
CIC     = $220B
TMC     = $2210
BMAP    = $2225     ; SA-1 BW-RAM window block (b7 = bitmap)
CBWE    = $2227     ; SA-1 BW-RAM write enable (b7)
CIWP    = $222A     ; SA-1 I-RAM write protection
DCNT    = $2230     ; DMA control
CDMA    = $2231     ; character conversion DMA parameters
SDAL    = $2232     ; DMA source address (24-bit)
DDAL    = $2235     ; DMA destination address (24-bit)
DTCL    = $2238     ; DMA terminal counter
BBF     = $223F     ; BW-RAM bitmap format
BRF     = $2240     ; bitmap register file ($2240-$224F)
MCNT    = $2250     ; arithmetic: 0 multiply, 1 divide, 2 cumulative
MAL     = $2251     ; multiplicand / dividend (16-bit)
MAH     = $2252
MBL     = $2253     ; multiplier / divisor (16-bit), write MBH starts
MBH     = $2254
; ---- SA-1 side (read) ----
CFR     = $2301
HCR     = $2302
VCR     = $2304
MR      = $2306     ; result (40-bit): multiply product / divide quotient(16) + remainder(16)
OF      = $230B

.endif
