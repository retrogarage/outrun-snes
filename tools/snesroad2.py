"""Road renderer v2 model: arcade road RAM -> SNES Mode 1 two-layer road.

The arcade road chip (DX hwroad.cpp) draws, per scanline, either a solid line
(sky/ground above the horizon) or one or two road ROM lines (512 px, 2bpp)
placed by a per-line h-scroll, with colours picked by per-line bits.

SNES version (all Mode 1):
  - road ROM lines resampled x0.8 (512 -> 410 px) into BG tiles; one 64x64
    map: rows 0-255 = lines with phase A palette, rows 256-511 = phase B
  - each road on its own BG layer (top road = BG1), per line HOFS/VOFS by HDMA
  - outside the road = transparent -> backdrop colour per line (HDMA)
  - window per road layer masks the wrapped copy (map is 512 px wide)

This module renders both (arcade from road RAM like hwroad, SNES from the same
data) so the conversion rules can be checked against CannonBall DX frames.
"""
import struct
import numpy as np
from orroms import Roms

SCALE = 0.8
TEXW = 410                      # resampled road line width
X0 = 0x5F8                      # hwroad screen origin (s16_x, no x_offset)

_roads = None


def road_lines():
    """256 decoded road ROM lines (512 px): 0 road, 1 inner, 2 outer stripe,
    3 exterior, 7 centre marker (exterior in x 248-255), as hwroad decode."""
    global _roads
    if _roads is None:
        rom = Roms().road[:0x8000]
        L = np.zeros((256, 512), np.uint8)
        for y in range(256):
            src = y * 0x40
            for x in range(512):
                b = 7 - (x & 7)
                p = ((rom[src + x // 8] >> b) & 1) | (((rom[src + x // 8 + 0x4000] >> b) & 1) << 1)
                if 248 <= x < 256 and p == 3:
                    p = 7
                L[y, x] = p
        _roads = L
    return _roads


def resample_lines():
    """SNES texture: 256 x TEXW, nearest (pixel centres)."""
    L = road_lines()
    u = np.minimum(511, np.floor((np.arange(TEXW) + 0.5) / SCALE).astype(int))
    return L[:, u]


def load_state(fn):
    d = open(fn, "rb").read()
    out = {}
    p = 0
    while p < len(d):
        tag = d[p:p + 4].decode()
        n = struct.unpack_from("<I", d, p + 4)[0]
        out[tag] = d[p + 8:p + 8 + n]
        p += 8 + n
    return out


def pal_rgb(palbytes, idx):
    a = (palbytes[idx * 2] << 8) | palbytes[idx * 2 + 1]
    r = ((a & 0x000f) << 1) | ((a >> 12) & 1)
    g = ((a & 0x00f0) >> 3) | ((a >> 13) & 1)
    b = ((a & 0x0f00) >> 7) | ((a >> 14) & 1)
    return (r * 255 // 31, g * 255 // 31, b * 255 // 31)


def color_tables(ram, data0, data1):
    y0 = data0 & 0x1FF
    y1 = data1 & 0x1FF
    c0 = ram[0x600 + y0]
    c1 = ram[0x600 + y1]
    t = {}
    t[0x00] = 0x400 ^ 0x00 ^ (c0 & 1)
    t[0x01] = 0x400 ^ 0x02 ^ ((c0 >> 1) & 1)
    t[0x02] = 0x400 ^ 0x04 ^ ((c0 >> 2) & 1)
    t[0x03] = t[0x00] if (data0 & 0x200) else (0x420 ^ ((c0 >> 8) & 0xF))
    t[0x07] = 0x400 ^ 0x06 ^ ((c0 >> 3) & 1)
    t[0x10] = 0x400 ^ 0x08 ^ ((c1 >> 4) & 1)
    t[0x11] = 0x400 ^ 0x0a ^ ((c1 >> 5) & 1)
    t[0x12] = 0x400 ^ 0x0c ^ ((c1 >> 6) & 1)
    t[0x13] = t[0x10] if (data1 & 0x200) else (0x420 ^ 0x10 ^ ((c1 >> 8) & 0xF))
    t[0x17] = 0x400 ^ 0x0e ^ ((c1 >> 7) & 1)
    return t


PRI_LOOKUP = [[0, 0, 0, 0, 0, 0, 0, 1], [1, 0, 0, 0, 0, 0, 0, 1], [1, 0, 0, 0, 0, 0, 0, 1],
              [1, 1, 1, 0, 0, 0, 0, 1]] + [[0] * 8] * 4
PRI_MAP1 = [0x81, 0x81, 0x81, 0x8f, 0, 0, 0, 0x80]


def arcade_render(ram, control, pal):
    """Palette-index image 224 x 320 of the road layers (hwroad lores)."""
    L = road_lines()
    img = np.full((224, 320), -1, np.int32)
    for y in range(224):
        d0, d1 = ram[y], ram[0x100 + y]
        col = -1
        c = control & 3
        if c == 0 and d0 & 0x800:
            col = d0 & 0x7f
        elif c == 1:
            col = (d0 & 0x7f) if d0 & 0x800 else ((d1 & 0x7f) if d1 & 0x800 else -1)
        elif c == 2:
            col = (d1 & 0x7f) if d1 & 0x800 else ((d0 & 0x7f) if d0 & 0x800 else -1)
        elif c == 3 and d1 & 0x800:
            col = d1 & 0x7f
        if col != -1:
            img[y, :] = col | 0x780
        if (d0 & 0x800) and (d1 & 0x800):
            continue
        dummy = np.full(512, 3, np.uint8)
        src0 = dummy if d0 & 0x800 else L[(d0 >> 1) & 0xFF]
        src1 = dummy if d1 & 0x800 else L[(d1 >> 1) & 0xFF]
        h0 = (ram[0x200 + (d0 & 0x1FF)] & 0xFFF)
        h1 = (ram[0x400 + (d1 & 0x1FF)] & 0xFFF)
        t = color_tables(ram, d0, d1)
        if c == 0 and d0 & 0x800:
            continue
        if c == 3 and d1 & 0x800:
            continue
        for x in range(320):
            a = (h0 - X0 + x) & 0xFFF
            b = (h1 - X0 + x) & 0xFFF
            p0 = src0[a] if a < 0x200 else 3
            p1 = src1[b] if b < 0x200 else 3
            if c == 0:
                v = t[p0]
            elif c == 3:
                v = t[0x10 + p1]
            elif c == 1:
                v = t[0x10 + p1] if PRI_LOOKUP[p0][p1] else t[p0]
            else:
                v = t[0x10 + p1] if (PRI_MAP1[p0] >> p1) & 1 else t[p0]
            img[y, x] = v
    return img


def snes_lines(ram, control):
    """Per-scanline SNES parameters. Returns list of dicts:
    solid colour index or None; layers = [(road, row, hofs, win_l, win_r)] top
    first; backdrop palette index."""
    out = []
    c = control & 3
    for y in range(224):
        d0, d1 = ram[y], ram[0x100 + y]
        e = {"y": y}
        if (d0 & 0x800) and (d1 & 0x800) or (c == 0 and d0 & 0x800) or (c == 3 and d1 & 0x800):
            col = None
            if c == 0 or (c == 1 and d0 & 0x800):
                col = d0 & 0x7f
            if c == 3 or (c == 2 and d1 & 0x800):
                col = d1 & 0x7f
            if col is None:
                col = (d1 & 0x7f) if c == 1 else (d0 & 0x7f)
            e["solid"] = col | 0x780
            out.append(e)
            continue
        t = color_tables(ram, d0, d1)
        layers = []
        order = [1, 0] if c == 2 else [0, 1]
        for r in order:
            if r == 0 and c == 3:
                continue
            if r == 1 and c == 0:
                continue
            d = d0 if r == 0 else d1
            if d & 0x800:
                continue
            idx = d & 0x1FF
            h = ram[(0x200 if r == 0 else 0x400) + idx] & 0xFFF
            h = (h - X0) & 0xFFF
            if h >= 0x800:
                h -= 0x1000
            s = int(round(h * SCALE))
            cw = ram[0x600 + idx]
            phase = (cw >> (0 if r == 0 else 4)) & 1
            line = (d >> 1) & 0xFF
            wl, wr = max(0, -s), min(255, TEXW - 1 - s)
            layers.append((r, line + 256 * phase, s, wl, wr))
        e["layers"] = layers
        top = 1 if c == 2 else 0
        e["backdrop"] = t[0x13] if top == 1 else t[0x03]
        e["pal"] = t
        out.append(e)
    return out


def snes_render(ram, control, tex=None):
    """Palette-index image 224 x 256 of the SNES road model."""
    if tex is None:
        tex = resample_lines()
    img = np.full((224, 256), -1, np.int32)
    for e in snes_lines(ram, control):
        y = e["y"]
        if "solid" in e:
            img[y, :] = e["solid"]
            continue
        t = e["pal"]
        img[y, :] = e["backdrop"]
        for (r, row, s, wl, wr) in reversed(e["layers"]):   # bottom layer first
            line, phase = row & 255, row >> 8
            base = 0x00 if r == 0 else 0x10
            for x in range(wl, wr + 1):
                p = tex[line, s + x]
                if p == 3:
                    continue
                if r == 0:
                    v = 0x400 ^ {0: 0, 1: 2, 2: 4, 7: 6}[p] ^ phase
                else:
                    v = 0x400 ^ {0: 8, 1: 0xa, 2: 0xc, 7: 0xe}[p] ^ phase
                img[y, x] = v
    return img


def to_rgb(img, pal):
    h, w = img.shape
    out = np.zeros((h, w, 3), np.uint8)
    cache = {}
    for y in range(h):
        for x in range(w):
            i = img[y, x]
            if i < 0:
                continue
            if i not in cache:
                cache[i] = pal_rgb(pal, i & 0xFFF)
            out[y, x] = cache[i]
    return out


def downscale(img):
    """Arcade 320 wide -> 256 by the same pixel-centre sampling."""
    u = np.floor((np.arange(256) + 0.5) / SCALE).astype(int)
    return img[:, u]
