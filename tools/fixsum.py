"""Pad ROM to power-of-two-ish size and fix the LoROM header checksum."""
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
# checksum over whole image (mirroring for non power of 2 sizes)
size = len(d)
pow2 = 1
while pow2 * 2 <= size:
    pow2 *= 2
if pow2 != size:
    rem = d[pow2:]
    m = bytearray()
    while len(m) < pow2:
        m += rem
    full = d[:pow2] + m[:pow2]
else:
    full = d
d[0x7FDC:0x7FE0] = b"\xff\xff\x00\x00"
full[0x7FDC:0x7FE0] = b"\xff\xff\x00\x00"
s = sum(full) & 0xFFFF
d[0x7FDE] = s & 0xff
d[0x7FDF] = s >> 8
c = s ^ 0xFFFF
d[0x7FDC] = c & 0xff
d[0x7FDD] = c >> 8
open(p, "wb").write(d)
print("size %d checksum %04x" % (len(d), s))
