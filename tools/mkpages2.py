#!/usr/bin/env python3
"""BG pages for the engine port (NEWGAME builds): static full-screen pictures
the arcade builds from tiles or sprites and the SNES shows on BG1 (the FG
scenery map, src/otiles.s page mode) instead of OBJ pieces.

  1 music select   tile RAM page 15 (omusic blit_music_select): the compressed
                   tilemap TILEMAP_MUSIC_SELECT; radio / hand sprites and the
                   text stay live
  2 course map     the sand fill (fill_tilemap_color $ABD) and the backdrop
                   map pieces, jump table entries 26-60 (omap load_sprites);
                   the road pieces 0-24 (coloured as the car moves) and the
                   mini car stay live sprites (sprv2 skips 26-60 on page 2)
  3 logo           all seven original components, composed on a blue field

Pictures are rendered at arcade resolution, scaled to 256 px like the rest of
the port, and packed (tools/tilepal.py) into up to 6 BG palettes (CGRAM
palettes 2-7: the scenery palettes and the road palettes, whose colours 8-11
the road renderer re-sends when the page goes).  Tiles go to the scenery tile
slots (tile 245+), overflow to road tiles 1+ (restored from RoadTiles).

Output build/gen/pages2.s / pages2.inc: per page a ROM bank ($32+) with the
tiles at $8000, the map (28 x 32 BG entries) and the palettes; PgDesc (per
page: bank, palettes, tiles, map, palette addresses); PgZero (map rows 0-28).
"""
import collections
import os
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mkpages import (Arcade, Converter, scale_x, TILEMAP_MUSIC_SELECT, map_entries, draw_entry, draw_sprite,
                     MAP_BG, pal_to_rgb)
from tilepal import pack

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "build", "gen")
SLOT_T0 = 245           # src/otiles.s: first scenery tile slot
NSLOT = 523
PAL0 = 2                # first BG palette
BANK0 = 0x32


def convert(rgb, mask, npal):
    """256x224 picture -> tiles (list of 32-byte 4bpp), map (28x32 entries
    before tile placement: index | pal << 10 | flips), palettes"""
    q = np.zeros((224, 256), dtype=np.int32) - 1
    qc = (rgb >> 3).astype(np.int32)
    code = (qc[:, :, 0] << 10) | (qc[:, :, 1] << 5) | qc[:, :, 2]
    q[mask] = code[mask]
    blocks = []
    hists = []
    for ty in range(28):
        for tx in range(32):
            t = q[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8]
            blocks.append(t)
            hists.append(collections.Counter(int(v) for v in t.flatten() if v >= 0))
    # unique tile contents only (weights: occurrences)
    uniq = {}
    for b, h in zip(blocks, hists):
        k = b.tobytes()
        if k not in uniq:
            uniq[k] = (h, 0)
        uniq[k] = (uniq[k][0], uniq[k][1] + 1)
    keys = list(uniq)
    uh = [collections.Counter({c: n * uniq[k][1] for c, n in uniq[k][0].items()}) for k in keys]
    pals, assign, total = pack(uh, npal)
    kidx = {k: i for i, k in enumerate(keys)}
    tiles = [bytes(32)]
    tindex = {bytes(32): 0}
    m = np.zeros((28, 32), dtype=np.int32)
    conv = Converter()
    for n, b in enumerate(blocks):
        h = hists[n]
        if not h:
            continue
        p = assign[kidx[b.tobytes()]]
        idx = conv.index_tile(b, pals[p])
        ent = conv.add_tile(tiles, tindex, idx)
        m[n // 32, n % 32] = ent | (p << 10)
    return tiles, m, pals, total


def music_select(A):
    img = np.zeros((224, 320, 3), dtype=np.uint8)
    mask = np.zeros((224, 320), dtype=bool)
    A.render_cells(img, mask, A.tilemap_rle(TILEMAP_MUSIC_SELECT))
    return scale_x(img, mask)


def course_map(A):
    img = np.zeros((224, 320, 3), dtype=np.uint8)
    img[:] = pal_to_rgb(MAP_BG)
    es = [e for e in map_entries(A.R) if e["ctrl"] & 0x80 and e["i"] >= 26]
    for e in sorted(es, key=lambda e: e["pri"]):
        draw_entry(A, img, e)
    return scale_x(img, np.ones((224, 320), dtype=bool))


def title_logo(A):
    """Compose all seven original logo parts once, without OBJ overlap limits."""
    img = np.zeros((224, 320, 3), dtype=np.uint8)
    img[:] = (0, 148, 255)
    mask = np.ones((224, 320), dtype=bool)
    for addr, pal, x, y in [(0x11162, 0x99, 0, 0x70),
                            (0x1128e, 0x6e, -3, 0x88),
                            (0x112c0, 0x8b, 8, 0x4e),
                            (0x112f2, 0x8c, -2, 0x52),
                            (0x1125c, 0x6e, -0x20, 0x8f),
                            (0x111c6, 0x65, -0x40, 0x6d),
                            (0x11194, 0x65, 0x11, 0x65)]:
        draw_sprite(A, img, mask, addr, pal, x, y)
    return scale_x(img, mask)


def page_bytes(tiles, m, pals, npal):
    n = len(tiles) - 1
    assert n <= NSLOT + 244, n
    out_map = bytearray()
    for ty in range(28):
        for tx in range(32):
            e = int(m[ty, tx])
            t, p, fl = e & 0x3FF, (e >> 10) & 7, e & 0xC000
            if t == 0:
                w = 0
            else:
                vt = SLOT_T0 + t - 1 if t <= NSLOT else t - NSLOT
                w = vt | ((PAL0 + p) << 10) | fl
            out_map += bytes([w & 0xFF, w >> 8])
    out_pal = bytearray()
    for p in range(npal):
        for i in range(16):
            v = 0
            if i and p < len(pals) and i - 1 < len(pals[p]):
                c = pals[p][i - 1]
                r, g, b = c >> 10, (c >> 5) & 31, c & 31
                v = r | (g << 5) | (b << 10)
            out_pal += bytes([v & 0xFF, v >> 8])
    return b''.join(tiles[1:]), bytes(out_map), bytes(out_pal)


def preview(tiles, m, pals, path):
    from PIL import Image
    prev = np.zeros((224, 256, 3), dtype=np.uint8)
    tl = [np.zeros((8, 8), dtype=np.uint8)]
    for t in tiles[1:]:
        px = np.zeros((8, 8), dtype=np.uint8)
        for r in range(8):
            for c in range(8):
                b = 7 - c
                px[r, c] = (((t[2 * r] >> b) & 1) | (((t[2 * r + 1] >> b) & 1) << 1) |
                            (((t[16 + 2 * r] >> b) & 1) << 2) | (((t[17 + 2 * r] >> b) & 1) << 3))
        tl.append(px)
    for ty in range(28):
        for tx in range(32):
            e = int(m[ty, tx])
            t, p, fl = e & 0x3FF, (e >> 10) & 7, e & 0xC000
            px = tl[t]
            if fl & 0x4000:
                px = px[:, ::-1]
            if fl & 0x8000:
                px = px[::-1, :]
            for r in range(8):
                for c in range(8):
                    v = int(px[r, c])
                    if v:
                        col = pals[p][v - 1]
                        prev[ty * 8 + r, tx * 8 + c] = ((col >> 10) << 3, ((col >> 5) & 31) << 3, (col & 31) << 3)
    Image.fromarray(prev).save(path)


def main():
    A = Arcade()
    pages = [("music", music_select(A), 4), ("coursemap", course_map(A), 6),
             ("logo", title_logo(A), 6)]
    asm = ['; generated by tools/mkpages2.py', '.p816']
    desc = []
    for n, (name, (rgb, mask), npal) in enumerate(pages):
        tiles, m, pals, total = convert(rgb, mask, npal)
        tb, mb, pb = page_bytes(tiles, m, pals, npal)
        bank = BANK0 + n
        for suffix, data in (('tiles', tb), ('map', mb), ('pal', pb)):
            open(os.path.join(GEN, 'pg_%s_%s.bin' % (name, suffix)), 'wb').write(data)
        lab = 'Pg%d' % (n + 1)
        asm += ['.segment "BANK%02X"' % bank,
                '%sTiles: .incbin "pg_%s_tiles.bin"' % (lab, name),
                '%sMap: .incbin "pg_%s_map.bin"' % (lab, name),
                '%sPal: .incbin "pg_%s_pal.bin"' % (lab, name)]
        desc.append((lab, npal, len(tiles) - 1))
        print('page %d %s: %d tiles, %d palettes, error %d' % (n + 1, name, len(tiles) - 1, len([p for p in pals if p]), total))
        try:
            preview(tiles, m, pals, os.path.join(ROOT, 'build', 'pg_%s_preview.png' % name))
        except ImportError:
            pass
    asm += ['.segment "BANK%02X"' % BANK0, 'PgZero: .res 29*64, 0',
            '.segment "RODATA"', '.export PgDesc, PgZero',
            '; per page 1..: tiles (24-bit), palettes, tiles count, map, palettes (bank of the tiles)',
            'PgDesc:']
    for lab, npal, nt in desc:
        asm.append('    .faraddr %sTiles' % lab)
        asm.append('    .byte %d' % npal)
        asm.append('    .word %d, .loword(%sMap), .loword(%sPal)' % (nt, lab, lab))
    open(os.path.join(GEN, 'pages2.s'), 'w').write('\n'.join(asm) + '\n')
    inc = ['; generated by tools/mkpages2.py', 'PG_DESCSZ = 10', 'PG_NPAGES = %d' % len(pages),
           'PG_MUSIC = 1', 'PG_COURSEMAP = 2', 'PG_LOGO = 3', '.global PgDesc, PgZero']
    open(os.path.join(GEN, 'pages2.inc'), 'w').write('\n'.join(inc) + '\n')


if __name__ == '__main__':
    main()
