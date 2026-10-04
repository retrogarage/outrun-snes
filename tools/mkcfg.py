"""Generate the ld65 linker config for an SA-1 LoROM cartridge.

ROM (MMC defaults CXB=0 DXB=1 EXB=2 FXB=3):
  file 0-2MB  -> LoROM banks $00-$3F ; file 2-4MB -> banks $80-$BF
  (also HiROM-style $C0-$FF = file 0-4MB linear, 64KB banks)
  file 4-8MB (NBANKS 256, the pre-shrunk sprite data of src/sprv3.s): no
  fixed mapping; the S-CPU reads it through $E0-$EF with EXB switched per
  DMA (main.s UqStream), so its memory areas get unused placeholder
  addresses ($400000 + 32KB * (bank - 128)).
Bank 0 holds shared code + header/vectors. Segment BANKnn = file 32KB bank nn.

RAM:
  SA-1 : direct page $0000 (I-RAM), vars $0100-$05FF (I-RAM), stack $0600-$06FF,
         BSS in BW-RAM window $6000-$7FFF (BMAP=0 -> BW-RAM $40:0000-1FFF),
         manual buffers in BW-RAM bank $40 (see shared.inc), linker BWBSS in bank $41
  S-CPU: WRAM $0000-$1FFF (own direct page / vars / stack), $7E2000+
  Shared sync variables: I-RAM $3700-$37FF (visible to both CPUs)
"""
import sys

NBANKS = int(sys.argv[1]) if len(sys.argv) > 1 else 128
SA1_BANK = 2            # file banks 2-3: SA-1 code (HiROM $C1)
SA1_BANK2 = 0x1E        # file banks $1E-$1F: SA-1 code bank 2 (HiROM $CF)
out = sys.argv[2] if len(sys.argv) > 2 else "snes.cfg"


def bankaddr(b):
    if b >= 128:
        return 0x40 + (b - 128)         # (placeholder: not addressed by name)
    return b if b < 64 else 0x80 + (b - 64)


lines = []
lines.append("MEMORY {")
lines.append("    ZP:     start = $0000, size = $0100, type = rw, define = yes;")
lines.append("    IRAM:   start = $0100, size = $0500, type = rw, define = yes;")
lines.append("    SHARED: start = $3700, size = $0100, type = rw, define = yes;")
lines.append("    BWWIN:  start = $6000, size = $2000, type = rw, define = yes;")
lines.append("    BWRAM:  start = $410000, size = $C000, type = rw, define = yes;")
lines.append("    SZP:    start = $0000, size = $0100, type = rw, define = yes;")
lines.append("    SLORAM: start = $0100, size = $1D00, type = rw, define = yes;")
lines.append("    HIRAM:  start = $7E2000, size = $E000, type = rw, define = yes;")
lines.append("    EXRAM:  start = $7F0000, size = $10000, type = rw, define = yes;")
lines.append("    ROM00:  start = $008000, size = $7FB0, fill = yes, fillval = $FF, file = %O;")
lines.append("    HDR:    start = $00FFB0, size = $0050, fill = yes, fillval = $00, file = %O;")
for b in range(1, NBANKS):
    if b == SA1_BANK:
        # SA-1 code: file banks 2-3 = HiROM bank $C1 (64KB), linked at $0000 so that
        # jsr/jmp operands stay 16-bit (the SA-1 runs it with PB = $C1, DB = $00)
        lines.append("    SA1C:   start = $0000, size = $10000, fill = yes, fillval = $FF, file = %O;")
        continue
    if b == SA1_BANK + 1:
        continue
    if b == SA1_BANK2:
        # SA-1 code bank 2 (segment SA1CODE2): HiROM $CF, linked at $0000 too;
        # calls between the banks go through jsl/rtl trampolines (farcall.s)
        lines.append("    SA1C2:  start = $0000, size = $10000, fill = yes, fillval = $FF, file = %O;")
        continue
    if b == SA1_BANK2 + 1:
        continue
    lines.append("    ROM%02X:  start = $%02X8000, size = $8000, fill = yes, fillval = $FF, file = %%O;" % (b, bankaddr(b)))
lines.append("}")
lines.append("SEGMENTS {")
lines.append("    ZEROPAGE:  load = ZP, type = zp;")
lines.append("    IRAMBSS:   load = IRAM, type = bss, define = yes, optional = yes, align = $40;")
lines.append("    SHAREDBSS: load = SHARED, type = bss, define = yes, optional = yes;")
lines.append("    BSS:       load = BWWIN, type = bss, define = yes;")
lines.append("    BWBSS:     load = BWRAM, type = bss, define = yes, optional = yes;")
lines.append("    SZEROPAGE: load = SZP, type = zp, optional = yes;")
lines.append("    SBSS:      load = SLORAM, type = bss, define = yes, optional = yes;")
# S-CPU NMI / upload code, copied to low WRAM at reset (main.s): no ROM fetches in vblank
lines.append("    NMICODE:   load = ROM00, run = SLORAM, type = ro, define = yes, optional = yes;")
lines.append("    HIBSS:     load = HIRAM, type = bss, define = yes, optional = yes;")
lines.append("    EXBSS:     load = EXRAM, type = bss, define = yes, optional = yes;")
lines.append("    CODE:      load = ROM00, type = ro;")
lines.append("    RODATA:    load = ROM00, type = ro, optional = yes;")
lines.append("    HEADER:    load = HDR, type = ro, start = $00FFB0;")
lines.append("    VECTORS:   load = HDR, type = ro, start = $00FFE0;")
lines.append("    SA1CODE:   load = SA1C, type = ro;")
lines.append("    SA1CODE2:  load = SA1C2, type = ro, optional = yes;")
for b in range(1, NBANKS):
    if b in (SA1_BANK, SA1_BANK + 1, SA1_BANK2, SA1_BANK2 + 1):
        continue
    lines.append("    BANK%02X:    load = ROM%02X, type = ro, optional = yes;" % (b, b))
lines.append("}")
open(out, "w").write("\n".join(lines) + "\n")
