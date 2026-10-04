"""Scenery v2: the arcade tile layers (otiles FG / BG) for the SNES road view.

The arcade tilemap hardware (DX hwtiles) shows, per layer, a 1024x512 virtual
area of four 512x256 name-table pages picked by the page-select register;
OutRun fills tile RAM pages with a stage's FG layer (4 pages) and BG layer
(3 pages), rows bottom-aligned (copy_fg_tiles / copy_bg_tiles). The road chip
covers the tile layers on road lines, so the tiles only show on solid (sky)
lines - exactly where the SNES shows them (BG1 = FG layer, BG2 = BG layer).

SNES conversion (per stage = stage_lookup_off, palettes incl. the stage's
init_tilemap_palette overrides):
  - each 512 px page is resampled to 408 px = 51 tiles (x 0.797, pixel
    centres), so page boundaries fall on SNES tile boundaries and any page
    combination the page-select registers make can be shown
  - tiles deduplicated with h/v flips, no reduction (the SA-1 keeps a VRAM
    tile cache of the visible tiles, see src/otiles.s)
  - 2 SNES palettes of 15 colours per stage; every tile fits one of them

Output build/gen/scenery2.s / .inc:
  ScnDir: per stage (40 stage_lookup_off slots, $FF = none) 32 bytes:
    +0  fg_v_tiles, +1 bg_v_tiles, +2 tilemap_v_off (word)
    +4  first global tile (word), +6 tile count (word)
    +8  palettes (24-bit, 2 x 16 SNES colours)
    +11 page maps (24-bit) x 7 (FG 0-3, BG 0-2): 51 columns x v rows,
        column-major, top row first; word = stage tile (0 = blank)
        | pal1 $2000 | hflip $4000 | vflip $8000
  Tiles (4bpp, 32 bytes) of all stages packed from bank SCN_TBANK: global
  tile t at bank SCN_TBANK + (t >> 10), address $8000 + (t & 1023) * 32.
"""
import os
import struct
import sys
import numpy as np
from orroms import Roms, decode_tiles

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "build", "gen")
TILES_DEF_LOOKUP = 0x17E84
TILES_TABLE = 0x17EAC
TILE_PAL_IDX = 0x16FD8
TILE_PAL_DATA = 0x17050
TILEMAP_PALS = 0xDF9C
STAGE_DATA = None
PAGE_W = 408
SCN_DIRSZ = 32
COLS = 51
FIRST_BANK = 0x10
# stage_lookup_off -> internal level number (trackloader.stage_data, USA)
STAGE_LEVEL = {0: 0x3C, 8: 0x1E, 9: 0x3B, 16: 0x20, 17: 0x2F, 18: 0x2A, 24: 0x2D, 25: 0x35, 26: 0x33,
               27: 0x21, 32: 0x32, 33: 0x23, 34: 0x38, 35: 0x22, 36: 0x26}
# init_tilemap_palette: level -> [(blocks, src offset, palette RAM byte address)]
PAL_OVERRIDES = {
    0x1E: [(2, 0xC0, 0x120780), (0, 0x100, 0x1205F0)],
    0x3B: [(0, 0x60, 0x1205F0), (1, 0x20, 0x1205A0)],
    0x25: [(0, 0x60, 0x1205F0), (1, 0x20, 0x1205A0)],
    0x2F: [(3, 0xE0, 0x120600)],
    0x35: [(3, 0x00, 0x1203C0), (7, 0x10, 0x1200C0)],
    0x21: [(3, 0x120, 0x120600), (1, 0x130, 0x1206C0)],
    0x32: [(1, 0xF0, 0x1202A0), (2, 0x40, 0x120780)],
    0x23: [(1, 0x80, 0x1202A0)],
    0x38: [(1, 0x110, 0x1206C0), (1, 0x30, 0x120780)],
    0x22: [(3, 0x50, 0x120600), (7, 0x90, 0x1200C0)],
    0x26: [(1, 0xD0, 0x1202A0), (1, 0xB0, 0x120720), (0, 0xB0, 0x1207B0)],
}


def arc5(w):
    """arcade palette word -> SNES BGR555"""
    r = ((w & 15) << 1) | ((w >> 12) & 1)
    g = (((w >> 4) & 15) << 1) | ((w >> 13) & 1)
    b = (((w >> 8) & 15) << 1) | ((w >> 14) & 1)
    return r | (g << 5) | (b << 10)


def tile_palram(R, level):
    """palette RAM words 0-1023 as set by setup_palette_tilemap + the stage's
    init_tilemap_palette overrides"""
    pal = [0] * 1024
    for i in range(120):
        o = R.rom0[TILE_PAL_IDX + i] << 4
        for k in range(8):
            pal[64 + i * 8 + k] = R.r16(R.rom0, TILE_PAL_DATA + o + 2 * k)
    for blocks, src, dst in PAL_OVERRIDES.get(level, []):
        e = (dst - 0x120000) // 2
        for b in range(blocks + 1):
            for k in range(8):
                pal[e + b * 8 + k] = R.r16(R.rom0, TILEMAP_PALS + src + 2 * k)
    return pal


def layer_pages(R, addr, vtiles, ntables):
    """copy_fg_tiles / copy_bg_tiles: -> [ntables] arrays vtiles x 64 of tile words"""
    a = addr
    out = []
    for t in range(ntables):
        pg = np.zeros((vtiles, 64), np.int32)
        y = vtiles - 1
        while y >= 0:
            x = 0x3F
            while x >= 0:
                d = R.r16(R.rom0, a)
                a += 2
                if d == 0:
                    v = R.r16(R.rom0, a)
                    c = R.r16(R.rom0, a + 2)
                    a += 4
                    for _ in range(c + 1):
                        pg[y, 0x3F - x] = v
                        x -= 1
                        if x < 0:
                            break
                else:
                    pg[y, 0x3F - x] = d
                    x -= 1
            y -= 1
        out.append(pg)
    return out


def page_image(pg, tiles, pal):
    """tile words -> image (8v x 512) of SNES colours, -1 transparent"""
    v = pg.shape[0]
    img = np.full((v * 8, 512), -1, np.int32)
    for y in range(v):
        for x in range(64):
            w = int(pg[y, x])
            if w & 0x8000:
                continue                    # priority tiles are not drawn (hwtiles)
            t = w & 0x1FFF
            if t == 0:
                continue
            p = (w >> 6) & 0x7F
            px = tiles[t]
            blk = img[y * 8:y * 8 + 8, x * 8:x * 8 + 8]
            for yy in range(8):
                for xx in range(8):
                    c = int(px[yy, xx])
                    if c:
                        blk[yy, xx] = arc5(pal[p * 8 + c])
    return img


def resample(img):
    xs = [min(511, int((x + 0.5) * 512 / PAGE_W)) for x in range(PAGE_W)]
    return img[:, xs]


def flips(t):
    return [(t, 0), (t[:, ::-1], 0x4000), (t[::-1, :], 0x8000), (t[::-1, ::-1], 0xC000)]


def assign_palettes(csets):
    """2 palettes of <= 15 colours covering every tile's colour set"""
    order = sorted(range(len(csets)), key=lambda i: -len(csets[i]))
    pals = [set(), set()]
    which = [0] * len(csets)
    for i in order:
        c = csets[i]
        best = None
        for p in (0, 1):
            u = pals[p] | c
            if len(u) <= 15:
                grow = len(u) - len(pals[p])
                if best is None or grow < best[0]:
                    best = (grow, p)
        if best is None:
            raise SystemExit("tile colour set does not fit the stage palettes")
        pals[best[1]] |= c
        which[i] = best[1]
    return [sorted(p) for p in pals], which


def convert_stage(R, tiles, sid):
    level = STAGE_LEVEL[sid]
    tid = R.rom0[TILES_DEF_LOOKUP + sid]
    a = TILES_TABLE + tid * 12
    fgv, bgv = R.rom0[a], R.rom0[a + 1]
    fga, bga = R.r32(R.rom0, a + 2), R.r32(R.rom0, a + 6)
    voff = R.r16(R.rom0, a + 10)
    pal = tile_palram(R, level)
    pages = layer_pages(R, fga, fgv, 4) + layer_pages(R, bga, bgv, 3)
    imgs = [resample(page_image(pg, tiles, pal)) for pg in pages]
    # unique tiles
    keys = {}
    tdat = [None]                           # tile 0 = blank
    cells = []
    for img in imgs:
        v = img.shape[0] // 8
        m = np.zeros((v, COLS), np.int32)
        for y in range(v):
            for x in range(COLS):
                t = img[y * 8:y * 8 + 8, x * 8:x * 8 + 8]
                if (t < 0).all():
                    continue
                hit = None
                for ft, fl in flips(t):
                    k = ft.tobytes()
                    if k in keys:
                        hit = (keys[k], fl)
                        break
                if hit is None:
                    keys[t.tobytes()] = len(tdat)
                    tdat.append(t.copy())
                    hit = (len(tdat) - 1, 0)
                m[y, x] = hit[0] | hit[1]
        cells.append(m)
    csets = [frozenset(int(c) for c in np.unique(t) if c >= 0) for t in tdat[1:]]
    pals, which = assign_palettes(csets)
    # tile data 4bpp
    tb = bytearray(32)                      # blank tile 0
    for i, t in enumerate(tdat[1:]):
        p = pals[which[i]]
        idx = np.zeros((8, 8), np.int32)
        for y in range(8):
            for x in range(8):
                c = int(t[y, x])
                idx[y, x] = 0 if c < 0 else 1 + p.index(c)
        out = bytearray(32)
        for y in range(8):
            for bp in range(4):
                v = 0
                for x in range(8):
                    v |= ((int(idx[y, x]) >> bp) & 1) << (7 - x)
                out[(bp >> 1) * 16 + y * 2 + (bp & 1)] = v
        tb += out
    # page maps: column-major, top row first
    maps = []
    for m in cells:
        v = m.shape[0]
        b = bytearray()
        for x in range(COLS):
            for y in range(v):
                w = int(m[y, x])
                t = w & 0x1FFF
                if t:
                    w |= which[t - 1] << 13
                b += struct.pack("<H", w)
        maps.append(bytes(b))
    pb = bytearray()
    for p in pals:
        for i in range(16):
            pb += struct.pack("<H", p[i - 1] if 1 <= i <= len(p) else 0)
    return dict(sid=sid, tid=tid, fgv=fgv, bgv=bgv, voff=voff, tiles=bytes(tb), ntiles=len(tdat),
                pals=bytes(pb), maps=maps, ncol=len(set().union(*csets)) if csets else 0)


def main():
    R = Roms()
    tiles = decode_tiles(R)
    stages = []
    for sid in sorted(STAGE_LEVEL):
        st = convert_stage(R, tiles, sid)
        print("stage %02X tilemap %2d: fg %d bg %d rows, voff %d, %4d tiles, %d colours" % (
            sid, st["tid"], st["fgv"], st["bgv"], st["voff"], st["ntiles"], st["ncol"]))
        stages.append(st)
    # tiles of all stages packed contiguously from bank FIRST_BANK: global
    # tile t is at ROM file offset FIRST_BANK * $8000 + t * 32 (LoROM: bank
    # $10 + (t >> 10), address $8000 | (t & 1023) * 32)
    alltiles = bytearray()
    tbase = {}
    for st in stages:
        tbase[st["sid"]] = len(alltiles) // 32
        alltiles += st["tiles"]
    asm = ["; generated by tools/mkscenery2.py", ".p816"]
    nb = (len(alltiles) + 0x7FFF) // 0x8000
    for b in range(nb):
        fn = "scn2_tiles%d.bin" % b
        open(os.path.join(GEN, fn), "wb").write(alltiles[b * 0x8000:(b + 1) * 0x8000])
        asm += ['.segment "BANK%02X"' % (FIRST_BANK + b), 'ScnTiles%d: .incbin "%s"' % (b, fn)]
    # maps and palettes: the rest of the last tile bank, then following banks
    bank = FIRST_BANK + nb - 1
    used = len(alltiles) - (nb - 1) * 0x8000
    blobs = []

    def place(lbl, data):
        nonlocal bank, used
        if used + len(data) > 0x8000:
            bank += 1
            used = 0
        fn = "scn2_%s.bin" % lbl
        open(os.path.join(GEN, fn), "wb").write(data)
        blobs.append((bank, lbl, fn))
        used += len(data)
    for st in stages:
        sx = "%02X" % st["sid"]
        place("p" + sx, st["pals"])
        for i, m in enumerate(st["maps"]):
            place("m%s_%d" % (sx, i), m)
    cur = None
    for b, lbl, fn in blobs:
        if b != cur:
            asm.append('.segment "BANK%02X"' % b)
            cur = b
        asm.append('Scn_%s: .incbin "%s"' % (lbl, fn))
    asm += ['.segment "RODATA"', ".export ScnDir", "ScnDir:"]
    bysid = {st["sid"]: st for st in stages}
    for sid in range(40):
        st = bysid.get(sid)
        if st is None:
            asm.append("    .byte $FF, $FF" + ", 0" * (SCN_DIRSZ - 2))
            continue
        sx = "%02X" % sid
        ents = ["    .byte %d, %d" % (st["fgv"], st["bgv"]),
                "    .word %d, %d, %d" % (st["voff"], tbase[sid], st["ntiles"]),
                "    .faraddr Scn_p%s" % sx]
        ents += ["    .faraddr Scn_m%s_%d" % (sx, i) for i in range(7)]
        asm += ents
    open(os.path.join(GEN, "scenery2.s"), "w").write("\n".join(asm) + "\n")
    inc = ["; generated by tools/mkscenery2.py", ".global ScnDir",
           "SCN_DIRSZ = %d" % SCN_DIRSZ, "SCN_COLS = %d" % COLS, "SCN_TBANK = $%02X" % FIRST_BANK,
           "SCN_NTILES = %d" % (len(alltiles) // 32)]
    open(os.path.join(GEN, "scenery2.inc"), "w").write("\n".join(inc) + "\n")
    print("tiles %d (%d bytes), banks $%02X-$%02X" % (len(alltiles) // 32, len(alltiles), FIRST_BANK, bank))

if __name__ == "__main__":
    main()
