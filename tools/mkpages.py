"""Full-screen "pages" (music select, ...) for the SNES port.

A page is a 256x224 Mode 1 BG1 picture (4bpp, 8 palettes) converted from the
arcade tile layers (320 px wide, scaled by 205/256 like the rest of the port)
with the arcade text layer composited on top at its scaled position (text is
not scaled). Text that changes at runtime is handled with map patches: each
variant image is converted together with the base picture, and the map rows
that differ are stored as a patch the SA-1 can queue for upload.

Outputs build/gen/pages.s (data in PAGE_BANK), pages.inc.
"""
import os
import sys
import numpy as np
from orroms import Roms, decode_tiles, pal_to_rgb
from sprites import frame_lods, decode_lod, SPRITE_PALS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "build", "gen")
XSCALE = 205 / 256
TEXT_COL0 = 24                 # first visible text layer column
PAGE_BANK = 0x32               # first ROM bank used for page data

HUD_PAL = 0x16ED8
TILE_PAL_IDX = 0x16FD8
TILE_PAL_DATA = 0x17050
TILEMAP_MUSIC_SELECT = 0x383F2

TEXT2_SELECT_MUSIC = 0xBCBE
TEXT2_MAGICAL = 0xCE04
TEXT2_BREEZE = 0xCE1E
TEXT2_SPLASH = 0xCE38
TEXT1_PRESS_START = 0xBBD0
MUSIC_EQ_PAL = 0xCCAA
SPRITE_RADIO = 0x118D8
SPRITE_FM = (0x11892, 0x1189C, 0x118A6)
SPRITE_DIAL = (0x118B0, 0x118BA, 0x118C4)


class Arcade:
    def __init__(self):
        self.R = Roms()
        self.tiles = decode_tiles(self.R)
        R = self.R
        pal = [(0, 0, 0)] * 1024
        for i in range(64):
            pal[i] = pal_to_rgb(R.r16(R.rom0, HUD_PAL + 2 * i))
        for i in range(120):
            off = R.rom0[TILE_PAL_IDX + i] << 4
            for k in range(8):
                pal[64 + i * 8 + k] = pal_to_rgb(R.r16(R.rom0, TILE_PAL_DATA + off + 2 * k))
        self.pal = pal

    # ---------------- tile layers ----------------
    def tilemap_rle(self, addr, rows=28, cols=40):
        R = self.R
        cells = []
        a = addr
        for _ in range(rows):
            row = []
            while len(row) < cols:
                d = R.r16(R.rom0, a)
                a += 2
                if d:
                    row.append(d)
                else:
                    v = R.r16(R.rom0, a)
                    c = R.r16(R.rom0, a + 2)
                    a += 4
                    row += [v] * (c + 1)
            cells.append(row[:cols])
        return cells

    def render_cells(self, img, mask, cells, x0=0, y0=0, textlayer=False):
        """Draw tile words onto img (H,W,3) / mask (H,W) (True = opaque)."""
        H, W = mask.shape
        for r, row in enumerate(cells):
            for c, w in enumerate(row):
                if w is None:
                    continue
                if textlayer:
                    t = w & 0x1FF
                    p = (w >> 9) & 7
                else:
                    t = w & 0x1FFF
                    p = (w >> 6) & 0x7F
                px = self.tiles[t]
                for yy in range(8):
                    y = y0 + r * 8 + yy
                    if not (0 <= y < H):
                        continue
                    for xx in range(8):
                        x = x0 + c * 8 + xx
                        v = int(px[yy, xx])
                        if v and 0 <= x < W:
                            img[y, x] = self.pal[p * 8 + v]
                            mask[y, x] = True

    # ---------------- text layer blocks ----------------
    def text2_cells(self, addr):
        """blit_text2 block -> (row, col, 2-row cells)."""
        R = self.R
        off = R.r16(R.rom0, addr)
        pal = R.rom0[addr + 2]
        cnt = R.rom0[addr + 3]
        base = 0x80A0 | ((pal << 9) & 0xFFFF) | ((pal >> 7) & 1)
        top, bot = [], []
        for i in range(cnt + 1):
            ch = R.rom0[addr + 4 + i]
            if ch == 0x20:
                top.append(None)
                bot.append(None)
            else:
                d = ((ch - 0x41) * 2 + base) & 0xFFFF
                top.append(d)
                bot.append(d + 1)
        cell = off // 2
        return cell // 64, cell % 64, [top, bot]

    def text1_cells(self, addr):
        R = self.R
        dst = R.r32(R.rom0, addr)
        cnt = R.r16(R.rom0, addr + 4)
        data = R.r16(R.rom0, addr + 6)
        row = []
        for i in range(cnt + 1):
            w = (data & 0xFF00) | R.rom0[addr + 8 + i]
            row.append(w if (w & 0x1FF) else None)
        cell = (dst - 0x110000) // 2
        return cell // 64, cell % 64, [row]


def scale_x(img, mask):
    """320 -> 256 columns, nearest (same column mapping as the sprites)."""
    xs = np.minimum(319, (np.arange(256) * 256 // 205)).astype(int)
    return img[:, xs], mask[:, xs]


def text_layer(A, blocks):
    """Render text blocks on a 256x224 layer, each block unscaled, centred
    at the scaled position of its arcade centre."""
    img = np.zeros((224, 256, 3), dtype=np.uint8)
    mask = np.zeros((224, 256), dtype=bool)
    for (row, col, cells) in blocks:
        w = max(len(r) for r in cells) * 8
        ax = (col - TEXT_COL0) * 8 + w / 2           # arcade centre x
        sx = int(round((ax - 160) * XSCALE + 128 - w / 2))
        A.render_cells(img, mask, cells, sx, row * 8, textlayer=True)
    return img, mask


# ============================================================================
# SNES conversion
# ============================================================================
def rgb15(c):
    r, g, b = c
    return (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)


def q15(c):
    """Quantize an RGB triple to what the SNES can show (5 bits/channel)."""
    return tuple((v >> 3) for v in c)


class Converter:
    """Convert a set of 256x224 images (base + variants) to 4bpp tiles with
    shared palettes. Transparent pixels -> colour 0 (backdrop)."""

    def __init__(self, npal=8, max_tiles=1000):
        self.npal = npal
        self.max_tiles = max_tiles

    def run(self, images):
        # images: list of (rgb, mask)
        blocks = []                 # per image: list of 28*32 tile blocks
        for rgb, mask in images:
            q = np.zeros((224, 256), dtype=np.int32) - 1
            qc = (rgb >> 3).astype(np.int32)
            code = (qc[:, :, 0] << 10) | (qc[:, :, 1] << 5) | qc[:, :, 2]
            q[mask] = code[mask]
            blocks.append(q)
        # colour sets per distinct tile content
        sets = {}
        for q in blocks:
            for ty in range(28):
                for tx in range(32):
                    t = q[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8]
                    cs = frozenset(int(v) for v in np.unique(t) if v >= 0)
                    if len(cs) > 15:
                        cs = frozenset(sorted(cs)[:15])   # rare; nearest mapping later
                    sets[t.tobytes()] = cs
        pals = self.cluster(list(sets.values()))
        self.pals = pals
        # build tiles
        tiles = [bytes(32)]
        tindex = {bytes(32): 0}
        maps = []
        for q in blocks:
            m = np.zeros((32, 32), dtype=np.int32)
            for ty in range(28):
                for tx in range(32):
                    t = q[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8]
                    cs = sets[t.tobytes()]
                    p = self.best_pal(cs, pals)
                    idx = self.index_tile(t, pals[p])
                    ent = self.add_tile(tiles, tindex, idx)
                    m[ty, tx] = ent | (p << 10)
            maps.append(m)
        if len(tiles) > self.max_tiles:
            raise ValueError("too many tiles: %d" % len(tiles))
        self.tiles = tiles
        self.maps = maps
        return tiles, maps, pals

    @staticmethod
    def cluster(csets, npal=8):
        """Greedy palette packing: each colour set must fit one palette of 15."""
        uniq = sorted(set(csets), key=lambda s: -len(s))
        pals = []
        for cs in uniq:
            if not cs:
                continue
            best, bestadd = None, None
            for i, p in enumerate(pals):
                add = len(cs - p)
                if len(p) + add <= 15 and (bestadd is None or add < bestadd):
                    best, bestadd = i, add
            if best is None:
                if len(pals) < npal:
                    pals.append(set(cs))
                    continue
                # no room: merge into the palette with most overlap (nearest-colour fallback)
                best = max(range(len(pals)), key=lambda i: len(cs & pals[i]))
                room = 15 - len(pals[best])
                for c in sorted(cs - pals[best])[:room]:
                    pals[best].add(c)
                continue
            pals[best] |= cs
        return [sorted(p) for p in pals]

    @staticmethod
    def best_pal(cs, pals):
        best, bc = 0, -1
        for i, p in enumerate(pals):
            n = len(cs & set(p))
            if n > bc or (n == bc and len(p) < len(pals[best])):
                best, bc = i, n
        return best

    @staticmethod
    def index_tile(t, pal):
        lut = {c: i + 1 for i, c in enumerate(pal)}
        out = np.zeros((8, 8), dtype=np.uint8)
        for y in range(8):
            for x in range(8):
                v = int(t[y, x])
                if v < 0:
                    continue
                if v in lut:
                    out[y, x] = lut[v]
                else:
                    r, g, b = v >> 10, (v >> 5) & 31, v & 31
                    out[y, x] = 1 + min(range(len(pal)), key=lambda i: (
                        ((pal[i] >> 10) - r) ** 2 + (((pal[i] >> 5) & 31) - g) ** 2 + ((pal[i] & 31) - b) ** 2))
        return out

    @staticmethod
    def tile4(px):
        out = bytearray(32)
        for r in range(8):
            for c in range(8):
                v = int(px[r, c])
                b = 7 - c
                out[2 * r] |= (v & 1) << b
                out[2 * r + 1] |= ((v >> 1) & 1) << b
                out[16 + 2 * r] |= ((v >> 2) & 1) << b
                out[17 + 2 * r] |= ((v >> 3) & 1) << b
        return bytes(out)

    def add_tile(self, tiles, tindex, px):
        for flip, arr in ((0, px), (0x4000, px[:, ::-1]), (0x8000, px[::-1, :]), (0xC000, px[::-1, ::-1])):
            key = self.tile4(np.ascontiguousarray(arr))
            if key in tindex:
                return tindex[key] | flip
        key = self.tile4(px)
        tindex[key] = len(tiles)
        tiles.append(key)
        return tindex[key]


def pal_bytes(pals, backdrop):
    """8 palettes x 16 colours BGR555 (entries are 15-bit codes rrrrrgggggbbbbb)."""
    out = bytearray(256)
    for p in range(8):
        for i in range(16):
            if i == 0:
                v = rgb15(backdrop) if p == 0 else 0
            elif p < len(pals) and i - 1 < len(pals[p]):
                c = pals[p][i - 1]
                r, g, b = c >> 10, (c >> 5) & 31, c & 31
                v = r | (g << 5) | (b << 10)
            else:
                v = 0
            out[(p * 16 + i) * 2] = v & 0xFF
            out[(p * 16 + i) * 2 + 1] = v >> 8
    return bytes(out)


def map_bytes(m, r0=0, r1=32):
    out = bytearray()
    for r in range(r0, r1):
        for c in range(32):
            v = int(m[r, c])
            out += bytes([v & 0xFF, v >> 8])
    return bytes(out)


def changed_rows(a, b):
    return {r for r in range(28) if not np.array_equal(a[r], b[r])}


def row_ranges(rows):
    out = []
    for r in sorted(rows):
        if out and out[-1][1] == r:
            out[-1][1] = r + 1
        else:
            out.append([r, r + 1])
    return [tuple(x) for x in out]


def diff_rows(base, var):
    rows = [r for r in range(28) if not np.array_equal(base[r], var[r])]
    if not rows:
        return None
    return rows[0], rows[-1] + 1


def composite(bg, text):
    rgb, mask = bg
    trgb, tmask = text
    out = rgb.copy()
    om = mask.copy()
    out[tmask] = trgb[tmask]
    om |= tmask
    return out, om


# ============================================================================
# Pages
# ============================================================================
def draw_sprite(A, img, mask, addr, pal, x, y):
    """Arcade sprite entry at addr, palette pal, centre (160 + x, y), 1:1."""
    lod = frame_lods(A.R, addr)[0]
    px = decode_lod(A.R, lod)
    colours = [pal_to_rgb(A.R.r16(A.R.rom0, SPRITE_PALS + pal * 32 + i * 2)) for i in range(16)]
    x0 = 160 + x - lod["w"] // 2
    y0 = y - lod["h"] // 2
    h, w = px.shape
    for yy in range(h):
        for xx in range(w):
            v = int(px[yy, xx])
            if v and 0 <= y0 + yy < 224 and 0 <= x0 + xx < 320:
                img[y0 + yy, x0 + xx] = colours[v]
                mask[y0 + yy, x0 + xx] = True


def music_select(A):
    img = np.zeros((224, 320, 3), dtype=np.uint8)
    mask = np.zeros((224, 320), dtype=bool)
    A.render_cells(img, mask, A.tilemap_rle(TILEMAP_MUSIC_SELECT))
    draw_sprite(A, img, mask, SPRITE_RADIO, 0xB0, 28, 180)
    sel = A.text2_cells(TEXT2_SELECT_MUSIC)
    notes = {0: 32, 1: 35, 2: 36}
    variants = []
    for k, t in enumerate((TEXT2_MAGICAL, TEXT2_BREEZE, TEXT2_SPLASH)):
        im, mk = img.copy(), mask.copy()
        draw_sprite(A, im, mk, SPRITE_FM[k], 0x87, -8, 176)
        draw_sprite(A, im, mk, SPRITE_DIAL[k], 0x89, 68, 181)
        bg = scale_x(im, mk)
        r, c, cells = A.text2_cells(t)
        nc = notes[k] - c
        cells = [list(cells[0]), list(cells[1])]
        cells[0][nc] = 0x8A7A
        cells[0][nc + 1] = 0x8A7B
        cells[1][nc] = 0x8A7C
        cells[1][nc + 1] = 0x8A7D
        variants.append(composite(bg, text_layer(A, [sel, (r, c, cells)])))
    push = composite(variants[1], text_layer(A, [A.text1_cells(TEXT1_PRESS_START)]))
    return variants, push


# ---------------- course map ----------------
MAP_SPRITES = 0x26BE           # 61 x 20-byte sprite entries (ROM0)
MAP_ROUTE_LOOKUP = 0x3636
MAP_MOVE_LEFT = 0x3A34
MAP_MOVE_RIGHT = 0x3AB4
TEXT2_COURSEMAP = 0xBBC2
MAP_BG = 0xABD                 # sand colour the tilemap is filled with
MAP_HI_PAL = 219               # last palette of the route colouring cycle


def map_entries(R):
    out = []
    for i in range(61):
        a = MAP_SPRITES + 20 * i
        out.append(dict(i=i, ctrl=R.rom0[a], props=R.rom0[a + 1], zoom=R.rom0[a + 3], pal=R.r16(R.rom0, a + 4),
                        pri=R.r16(R.rom0, a + 6), x=R.s16(R.rom0, a + 8), y=R.s16(R.rom0, a + 10),
                        addr=R.r32(R.rom0, a + 12)))
    return out


def draw_entry(A, img, e, pal=None):
    """arcade sprite entry with zoom and anchors onto a 320x224 image"""
    from mksprites import scale_image
    R = A.R
    lod = frame_lods(R, e["addr"])[0]
    px = decode_lod(R, lod)
    full = np.zeros((lod["h"], lod["w"]), dtype=np.uint8)
    hh, ww = min(lod["h"], px.shape[0]), min(lod["w"], px.shape[1])
    full[:hh, :ww] = px[:hh, :ww]
    if e["ctrl"] & 1:
        full = full[:, ::-1]
    sc = (e["zoom"] + 1) / 128.0
    w = max(1, int(round(lod["w"] * sc)))
    h = max(1, int(round(lod["h"] * sc)))
    im = scale_image(full, w, h)
    ya, xa = (e["props"] >> 2) & 3, e["props"] & 3
    top = e["y"] - (h // 2 if ya in (0, 3) else (0 if ya == 1 else h))
    left = e["x"] - (w // 2 if xa in (0, 3) else (0 if xa == 1 else w))
    p = e["pal"] if pal is None else pal
    cols = [pal_to_rgb(R.r16(R.rom0, SPRITE_PALS + p * 32 + k * 2)) for k in range(16)]
    ys, xs = np.nonzero(im)
    for yy, xx in zip(ys, xs):
        X, Y = 160 + left + xx, top + yy
        if 0 <= X < 320 and 0 <= Y < 224:
            img[Y, X] = cols[int(im[yy, xx])]


def course_map(A, highlight=()):
    img = np.zeros((224, 320, 3), dtype=np.uint8)
    img[:] = pal_to_rgb(MAP_BG)
    es = [e for e in map_entries(A.R) if e["ctrl"] & 0x80 and e["i"] != 25]   # 25 = mini car
    for e in sorted(es, key=lambda e: e["pri"]):
        draw_entry(A, img, e, MAP_HI_PAL if e["i"] in highlight else None)
    return img


LOGO_BG = 0x11162             # oval backdrop sprite, drawn at (0, $70), palette $99
LOGO_BG_PAL = 0x99
LOGO_SKY = (0, 148, 255)


def logo_page(A):
    """BG1 page with the logo oval: tiles keep the sprite's colour indices on
    palette 7 so the arcade's palette flashes are CGRAM swaps"""
    from mksprites import scale_image
    R = A.R
    lod = frame_lods(R, LOGO_BG)[0]
    px = decode_lod(R, lod)
    full = np.zeros((lod["h"], lod["w"]), dtype=np.uint8)
    full[:min(lod["h"], px.shape[0]), :min(lod["w"], px.shape[1])] = px[:lod["h"], :lod["w"]]
    w = int(round(lod["w"] * XSCALE))
    im = scale_image(full, w, lod["h"])
    canvas = np.zeros((224, 256), dtype=np.uint8)
    x0 = 128 - w // 2
    y0 = 0x70 - lod["h"] // 2
    canvas[y0:y0 + lod["h"], x0:x0 + w] = im
    tiles = [bytes(32)]
    tidx = {bytes(32): 0}
    tmap = np.zeros((32, 32), dtype=np.uint16)
    for ty in range(28):
        for tx in range(32):
            t = canvas[ty * 8:ty * 8 + 8, tx * 8:tx * 8 + 8]
            b = Converter.tile4(t)
            if b not in tidx:
                tidx[b] = len(tiles)
                tiles.append(b)
            tmap[ty, tx] = tidx[b] | (7 << 10) if t.any() else 0
    pal = bytearray(256)
    sky = rgb15(LOGO_SKY)
    pal[0] = sky & 0xFF
    pal[1] = sky >> 8
    for i in range(16):
        c = pal_to_rgb(R.r16(R.rom0, SPRITE_PALS + LOGO_BG_PAL * 32 + 2 * i))
        v = rgb15(c)
        pal[(112 + i) * 2] = v & 0xFF
        pal[(112 + i) * 2 + 1] = v >> 8
    return tiles, tmap, bytes(pal)


def build():
    A = Arcade()
    sky = (0, 148, 255)
    pages = []
    variants, push = music_select(A)
    conv = Converter()
    tiles, maps, pals = conv.run(variants + [push])
    print("music select: %d tiles, %d palettes (%s colours)" % (len(tiles), len(pals), [len(p) for p in pals]))
    # selection patches: every row range where the three variants differ
    ranges = row_ranges(set().union(*[changed_rows(maps[0], m) for m in maps[1:3]]))
    patches = []
    for k in range(3):
        for i, (r0, r1) in enumerate(ranges):
            patches.append(("sel%d_%d" % (k, i), (r0, r1), maps[k]))
    pr = diff_rows(maps[1], maps[3])
    patches.append(("push", pr, maps[3]))
    patches.append(("pushoff", pr, maps[1]))
    pages.append(dict(name="Music", tiles=tiles, map=maps[1], pals=pal_bytes(pals, sky), patches=patches,
                      consts={"MUSIC_SEL_N": len(ranges)}))
    # course map: base picture + every road piece highlighted; each piece's
    # tiles (bottom to top) become a list of tilemap words to rewrite
    ones = np.ones((224, 320), dtype=bool)
    title = text_layer(A, [A.text2_cells(TEXT2_COURSEMAP)])
    base = composite(scale_x(course_map(A), ones), title)
    hi = composite(scale_x(course_map(A, range(25)), ones), title)
    conv = Converter()
    mtiles, mmaps, mpals = conv.run([base, hi])
    print("course map: %d tiles, %d palettes" % (len(mtiles), len(mpals)))
    b0 = base[0]
    pieces = []
    for i in range(25):
        one = scale_x(course_map(A, [i]), ones)[0]
        d = (one != b0).any(axis=2)
        cells = sorted({(y // 8, x // 8) for y, x in zip(*np.nonzero(d))}, key=lambda c: (-c[0], c[1]))
        pieces.append([(0x4000 + ty * 32 + tx, int(mmaps[1][ty, tx])) for ty, tx in cells])
    lt, lm, lp = logo_page(A)
    print("logo: %d tiles" % len(lt))
    pages.append(dict(name="Logo", tiles=lt, map=lm, pals=lp, patches=[]))
    R = A.R
    pages.append(dict(name="Map", tiles=mtiles, map=mmaps[0], pals=pal_bytes(mpals, pal_to_rgb(MAP_BG)), patches=[],
                      pieces=pieces,
                      tables={"MapRouteLookup": bytes(R.rom0[MAP_ROUTE_LOOKUP:MAP_ROUTE_LOOKUP + 0x80]),
                              "MapMoveLeft": bytes(R.rom0[MAP_MOVE_LEFT:MAP_MOVE_LEFT + 0x80]),
                              "MapMoveRight": bytes(R.rom0[MAP_MOVE_RIGHT:MAP_MOVE_RIGHT + 0x80])}))
    write(pages)
    if len(sys.argv) > 1:
        preview(pages[0], sys.argv[1])


def write(pages):
    os.makedirs(GEN, exist_ok=True)
    out = []
    inc = []
    exports = []
    bank = PAGE_BANK
    used = 0
    lines = ['.segment "BANK%02X"' % bank]

    def blob(name, data):
        nonlocal bank, used, lines
        fn = "page_%s.bin" % name
        open(os.path.join(GEN, fn), "wb").write(data)
        pos = 0
        parts = []
        while pos < len(data):
            if used >= 0x8000:
                bank += 1
                used = 0
                lines.append('.segment "BANK%02X"' % bank)
            n = min(len(data) - pos, 0x8000 - used)
            lab = "%s_%d" % (name, len(parts))
            lines.append('%s: .incbin "%s", %d, %d' % (lab, fn, pos, n))
            parts.append((lab, n))
            used += n
            pos += n
        return parts

    tail = []                  # load lists, patch and lookup tables: own bank at the end
    for pg in pages:
        n = pg["name"]
        tparts = blob(n + "Tiles", b"".join(pg["tiles"]))
        mparts = blob(n + "Map", map_bytes(pg["map"]))
        pparts = blob(n + "Pal", pg["pals"])
        # load list: type, dest, src long, size
        ll = ["Page%sLoad:" % n]
        dest = 0
        for lab, sz in tparts:
            ll.append("    .byte 0\n    .word $%04X\n    .faraddr %s\n    .word %d" % (dest, lab, sz))
            dest += sz // 2
        ll.append("    .byte 0\n    .word $4000\n    .faraddr %s\n    .word %d" % (mparts[0][0], mparts[0][1]))
        ll.append("    .byte 1\n    .word 0\n    .faraddr %s\n    .word %d" % (pparts[0][0], pparts[0][1]))
        ll.append("    .byte $FF")
        exports.append("Page%sLoad" % n)
        # patches: dest (VRAM word), src long, size
        pl = ["Page%sPatch:" % n]
        for i, (pn, (r0, r1), m) in enumerate(pg["patches"]):
            parts = blob("%sP_%s" % (n, pn), map_bytes(m, r0, r1))
            lab, sz = parts[0]
            pl.append("    .word $%04X\n    .faraddr %s\n    .byte 0\n    .word %d   ; %s" % (0x4000 + r0 * 32, lab, sz, pn))
            inc.append("PAGE_%s_%s = %d" % (n.upper(), pn.upper(), i))
        for k, v in pg.get("consts", {}).items():
            inc.append("PAGE_%s = %d" % (k, v))
        exports.append("Page%sPatch" % n)
        tail += ll + pl
        if "pieces" in pg:
            # piece table: offsets into the data; data: count, (VRAM word, tilemap word) pairs
            tail.append("%sPieceTab:" % n)
            off = 0
            data = []
            for pc in pg["pieces"]:
                tail.append("    .word %d" % off)
                data.append("    .word %d" % len(pc))
                for va, ent in pc:
                    data.append("    .word $%04X, $%04X" % (va, ent))
                off += 2 + 4 * len(pc)
            tail.append("%sPieceData:" % n)
            tail += data
            exports += ["%sPieceTab" % n, "%sPieceData" % n]
        for tn, data in pg.get("tables", {}).items():
            tail.append("%s: .byte %s" % (tn, ",".join("$%02X" % b for b in data)))
            exports.append(tn)
    # music select equaliser palette cycle (32 palette indices)
    R = Roms()
    tail.append("MusicEqPal: .byte " + ",".join("$%02X" % R.rom0[MUSIC_EQ_PAL + i] for i in range(32)))
    bank += 1
    lines.append('.segment "BANK%02X"' % bank)
    lines += tail
    exports.append("MusicEqPal")
    hdr = [".export " + ", ".join(exports)]
    open(os.path.join(GEN, "pages.s"), "w").write("\n".join(hdr + lines) + "\n")
    with open(os.path.join(GEN, "pages.inc"), "w") as f:
        f.write(".global " + ", ".join(exports) + "\n")
        f.write("\n".join(inc) + "\n")
    print("pages: banks $%02X-$%02X" % (PAGE_BANK, bank))


def preview(pg, path):
    from PIL import Image
    tiles = pg["tiles"]
    pals = pg["pals"]
    cols = []
    for i in range(128):
        v = pals[2 * i] | (pals[2 * i + 1] << 8)
        cols.append(((v & 31) << 3, ((v >> 5) & 31) << 3, ((v >> 10) & 31) << 3))
    img = np.zeros((224, 256, 3), dtype=np.uint8)
    m = pg["map"]
    for ty in range(28):
        for tx in range(32):
            e = int(m[ty, tx])
            t = tiles[e & 0x3FF]
            p = (e >> 10) & 7
            for y in range(8):
                for x in range(8):
                    b = 7 - x
                    v = ((t[2 * y] >> b) & 1) | (((t[2 * y + 1] >> b) & 1) << 1) | \
                        (((t[16 + 2 * y] >> b) & 1) << 2) | (((t[17 + 2 * y] >> b) & 1) << 3)
                    yy = 7 - y if e & 0x8000 else y
                    xx = 7 - x if e & 0x4000 else x
                    img[ty * 8 + yy, tx * 8 + xx] = cols[p * 16 + v] if v else cols[0]
    Image.fromarray(img).resize((512, 448), Image.NEAREST).save(path)


if __name__ == "__main__":
    build()
