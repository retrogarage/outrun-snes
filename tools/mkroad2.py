"""Road v2 assets: arcade road ROM lines -> SNES Mode 1 BG tiles + 64x64 map.

See docs/renderer.md. The 256 road ROM lines (512 px, identical for both road
generators) are resampled to 410 px (x0.8, pixel centres). Pixel values
0/1/2/7 (road / inner stripe / outer stripe / centre marker) become colours
8/9/10/11 of the road palette, exterior (3) is transparent. Tiles are
deduplicated with horizontal flips.

Map (64x64 words): rows 0-255 = lines 0-255 with palette ROAD_PAL_A (stripe
phase bit 0), rows 256-511 = the same lines with ROAD_PAL_B (phase bit 1).
Columns 52-63 and the right part of column 51 are transparent.

Outputs build/gen/road2.s (+ .inc): RoadTiles, RoadMap, RoadColTab
(32 pos_fine phases x 512 road indices: bit0 road 0 phase, bit1 road 1
phase, bits 4-7 ground colour index), sizes and constants.
"""
import os
import struct
import numpy as np
from orroms import Roms
import snesroad2 as SR
from roadsim import Track

GEN = os.path.join(os.path.dirname(__file__), "..", "build", "gen")
os.makedirs(GEN, exist_ok=True)

ROAD_PAL_A = 6              # BG palettes used by the road (colours 8-11)
ROAD_PAL_B = 7
ROAD_BGCOLOR = 0x109EE      # rom1: 32 phases x 512 words
PATH_BANK0 = 0x38           # raw path tables: banks $38..
PIX = {0: 8, 1: 9, 2: 10, 7: 11, 3: 0}


def planar4(tile):
    """8x8 of colour indices -> 32 bytes SNES 4bpp."""
    out = bytearray(32)
    for y in range(8):
        for bp in range(4):
            v = 0
            for x in range(8):
                v |= ((int(tile[y][x]) >> bp) & 1) << (7 - x)
            out[(bp >> 1) * 16 + y * 2 + (bp & 1)] = v
    return bytes(out)


def main():
    tex = SR.resample_lines()                       # 256 x 410
    W = 512
    img = np.zeros((256, W), np.uint8)
    for y in range(256):
        for x in range(SR.TEXW):
            img[y, x] = PIX[int(tex[y, x])]
    tiles = [bytes(32)]                             # tile 0 = transparent
    index = {tuple(map(tuple, np.zeros((8, 8), int))): (0, 0)}
    tmap = np.zeros((32, 64), np.uint16)
    for ty in range(32):
        for tx in range(64):
            t = img[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8]
            key = tuple(map(tuple, t))
            if key in index:
                n, fl = index[key]
            else:
                fkey = tuple(tuple(reversed(r)) for r in key)
                if fkey in index:
                    n, fl = index[fkey][0], index[fkey][1] ^ 1
                else:
                    n, fl = len(tiles), 0
                    tiles.append(planar4(t))
                    index[key] = (n, 0)
            tmap[ty, tx] = n | (fl << 14)
    rmap = np.zeros((64, 64), np.uint16)
    rmap[0:32] = tmap | (ROAD_PAL_A << 10)
    rmap[32:64] = tmap | (ROAD_PAL_B << 10)
    # a 64x64 map is 4 32x32 screens: SC0 top-left, SC1 top-right,
    # SC2 bottom-left, SC3 bottom-right (1K words each)
    mw = bytearray()
    for sy in range(2):
        for sx in range(2):
            for y in range(32):
                for x in range(32):
                    v = int(rmap[sy * 32 + y, sx * 32 + x])
                    mw += bytes([v & 0xFF, v >> 8])
    # road colour table
    R = Roms()
    ct = bytearray()
    for ph in range(32):
        for i in range(512):
            w = R.r16(R.rom1, ROAD_BGCOLOR + ph * 1024 + i * 2)
            ct.append((w & 1) | (((w >> 4) & 1) << 1) | (((w >> 8) & 0xF) << 4))
    # raw arcade path words per section (x, y int16 little endian per road
    # position; the road engine sums pairs and derives the heading itself)
    T = Track(R)
    sections = [L.path for L in T.levels] + [T.split.path] + [e.path for e in T.ends]
    NPOS = 0x904 + 80 + 70
    uniq = []
    for a in sections:
        if a not in uniq:
            uniq.append(a)
    path_asm = []
    bank = PATH_BANK0
    used = 0
    labels = {}
    for a in uniq:
        data = bytearray()
        for k in range(NPOS * 2):
            q = a + k * 2
            v = R.r16(R.rom1, q) if q + 1 < len(R.rom1) else 0
            data += v.to_bytes(2, "little")
        if used + len(data) > 0x8000:
            bank += 1
            used = 0
        lbl = "RawPath_%06X" % a
        labels[a] = lbl
        fnp = "road2_path_%06X.bin" % a
        open(os.path.join(GEN, fnp), "wb").write(data)
        path_asm += ['.segment "BANK%02X"' % bank, "%s: .incbin \"%s\"" % (lbl, fnp)]
        used += len(data)
    path_asm += ['.segment "RODATA"', ".export RawSectionPath", "RawSectionPath:"]
    path_asm += ["    .faraddr %s" % labels[a] for a in sections]
    # per-line road placement: v = (0x5C - h) & 0xFFF (h = road0_h/road1_h
    # entry; hardware hscroll 0x654 - h, screen origin 0x5F8) ->
    # S = round(0.8 * sext12(v)) (BG HOFS), window [max(0,-S), min(255,409-S)]
    st = bytearray()
    for v in range(4096):
        x = v - 4096 if v >= 2048 else v
        S = int(round(x * SR.SCALE))
        a, b = -S, SR.TEXW - 1 - S
        if b < 0 or a > 255:
            wl, wr = 255, 0                 # empty window: layer masked
        else:
            wl, wr = max(a, 0), min(b, 255)
        st += struct.pack("<hBB", S, wl, wr)
    open(os.path.join(GEN, "road2_stab.bin"), "wb").write(bytes(st))
    # arcade palette word -> SNES BGR555: lo[a & 0xFF] | hi[a >> 8]
    # (r = bits 0-3 << 1 | bit 12, g = bits 4-7 << 1 | bit 13, b = bits 8-11 << 1 | bit 14)
    lo = bytearray()
    hi = bytearray()
    for v in range(256):
        r4, g4 = v & 15, v >> 4
        lo += struct.pack("<H", (r4 << 1) | (g4 << 6))
        b4 = v & 15
        w = (b4 << 11) | (((v >> 4) & 1) << 0) | (((v >> 5) & 1) << 5) | (((v >> 6) & 1) << 10)
        hi += struct.pack("<H", w)
    open(os.path.join(GEN, "road2_arcsn.bin"), "wb").write(bytes(lo + hi))
    # H_SCROLL_TABLE (rom0 $30B00): otiles h-scroll target during the road
    # split, indexed by road_pos >> 16 (512 entries, as the arcade reads them)
    hs = b"".join(struct.pack("<H", R.r16(R.rom0, 0x30B00 + 2 * i)) for i in range(512))
    open(os.path.join(GEN, "road2_hscroll.bin"), "wb").write(hs)
    tb = b"".join(tiles)
    open(os.path.join(GEN, "road2_tiles.bin"), "wb").write(tb)
    open(os.path.join(GEN, "road2_map.bin"), "wb").write(bytes(mw))
    open(os.path.join(GEN, "road2_col.bin"), "wb").write(bytes(ct))
    asm = ["; generated by tools/mkroad2.py", ".p816",
           '.segment "BANK35"',
           ".export RoadTiles, RoadMap",
           'RoadTiles: .incbin "road2_tiles.bin"',
           'RoadMap: .incbin "road2_map.bin"',
           ".export ArcSnLo, ArcSnHi, HScrollTab",
           'HScrollTab: .incbin "road2_hscroll.bin"',
           'ArcSnLo: .incbin "road2_arcsn.bin", 0, 512',
           'ArcSnHi: .incbin "road2_arcsn.bin", 512, 512',
           '.segment "BANK36"',
           ".export RoadColTab, RoadSTab",
           'RoadColTab: .incbin "road2_col.bin"',
           'RoadSTab: .incbin "road2_stab.bin"'] + path_asm
    open(os.path.join(GEN, "road2.s"), "w").write("\n".join(asm) + "\n")
    inc = ["; generated by tools/mkroad2.py",
           ".global RoadTiles, RoadMap, RoadColTab, RawSectionPath, RoadSTab, ArcSnLo, ArcSnHi, HScrollTab",
           "ROAD_TILES_SIZE = %d" % len(tb),
           "ROAD_NTILES = %d" % len(tiles),
           "ROAD_MAP_SIZE = %d" % len(mw),
           "ROAD_PAL_A = %d" % ROAD_PAL_A,
           "ROAD_PAL_B = %d" % ROAD_PAL_B,
           "ROAD_TEXW = %d" % SR.TEXW]
    open(os.path.join(GEN, "road2.inc"), "w").write("\n".join(inc) + "\n")
    print("road tiles %d (%d bytes), map %d bytes, coltab %d bytes" % (len(tiles), len(tb), len(mw), len(ct)))


if __name__ == "__main__":
    main()
