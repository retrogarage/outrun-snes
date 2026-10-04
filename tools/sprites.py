"""OutRun sprite frame decoding.

A "frame" in ROM0 is 5 consecutive 10-byte LOD entries (largest first):
  +1 width(px)  +3 height(lines)  +5 pitch(32-bit words/line)  +7 bank  +8.w offset(words)
Line data: 4bpp nibbles, MSB first within a little-endian 32-bit word,
pixel 0 = transparent, 15 = end-of-line marker/transparent.
"""
import numpy as np
from PIL import Image
from orroms import Roms, pal_to_rgb

SPRITE_PALS = 0x14ED8   # 32 bytes per palette in ROM0


def frame_lods(R, addr):
    out = []
    for i in range(5):
        a = addr + i * 10
        out.append(dict(w=R.rom0[a + 1], h=R.rom0[a + 3], pitch=R.rom0[a + 5],
                        bank=R.rom0[a + 7], off=R.r16(R.rom0, a + 8)))
    return out


def decode_lod(R, lod, height=None):
    """Return 2D numpy array of 4bpp pixels (0 = transparent)."""
    h = lod["h"] if height is None else height
    pitch = lod["pitch"]
    if pitch >= 128:
        pitch -= 256
    base = (lod["bank"] & 3) * 0x10000
    rows = []
    maxw = 0
    for y in range(h):
        a = lod["off"] + y * pitch
        pix = []
        for n in range(64):
            w = int(R.sprites[base + ((a + n) & 0xFFFF)])
            nib = [(w >> s) & 0xF for s in (28, 24, 20, 16, 12, 8, 4, 0)]
            pix.extend(nib)
            if (w & 0xF0) == 0xF0:
                break
        rows.append(pix)
        maxw = max(maxw, len(pix))
    img = np.zeros((h, maxw), dtype=np.uint8)
    for y, r in enumerate(rows):
        r = [0 if p == 15 else p for p in r]
        img[y, :len(r)] = r
    # trim fully transparent right columns
    cols = np.where(img.any(axis=0))[0]
    if len(cols):
        img = img[:, :cols.max() + 1]
    return img


def sprite_palette(R, idx):
    return [R.r16(R.rom0, SPRITE_PALS + idx * 32 + i * 2) for i in range(16)]


def to_image(img, pal=None):
    h, w = img.shape
    out = np.zeros((h, w, 4), dtype=np.uint8)
    for y in range(h):
        for x in range(w):
            v = img[y, x]
            if v:
                if pal:
                    r, g, b = pal_to_rgb(pal[v])
                else:
                    r = g = b = v * 17
                out[y, x] = (r, g, b, 255)
    return Image.fromarray(out, "RGBA")


if __name__ == "__main__":
    import sys
    R = Roms()
    base = 0x11ED2
    ims = []
    for t in range(int(sys.argv[1]) if len(sys.argv) > 1 else 16):
        a = R.r32(R.rom0, base + t * 4)
        L = frame_lods(R, a)
        row = [to_image(decode_lod(R, l)) for l in L]
        ims.append(row)
    W = sum(max(r[i].width for r in ims) for i in range(5)) + 50
    H = sum(r[0].height for r in ims) + 5 * len(ims)
    sheet = Image.new("RGBA", (W, H), (60, 60, 120, 255))
    y = 0
    colx = [0]
    for i in range(5):
        colx.append(colx[-1] + max(r[i].width for r in ims) + 10)
    for r in ims:
        for i, im in enumerate(r):
            sheet.paste(im, (colx[i], y), im)
        y += r[0].height + 5
    sheet.save("../build/preview/sprite_types.png")
    print(sheet.size)
