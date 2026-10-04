"""Survey scenery objects per stage: routines, sprite types, palettes, LOD1 sizes."""
from collections import Counter, defaultdict
from orroms import Roms
from roadsim import Track
from sprites import frame_lods

MASTER = 0x1A43C
TYPE_TABLE = 0x11ED2

R = Roms()
T = Track(R)


def scenery_entries(addr):
    out = []
    a = addr
    last = -1
    while True:
        pos = R.r16(R.rom0, a)
        if pos == 0xFFFF or pos < last or len(out) > 2000:
            break
        cnt = R.rom0[a + 2]
        pat = R.rom0[a + 3]
        out.append((pos, cnt, pat))
        last = pos
        a += 4
    return out


def pattern(pat):
    a0 = R.r32(R.rom0, MASTER + pat * 4)
    freq = R.r16(R.rom0, a0)
    reload = R.r16(R.rom0, a0 + 2)
    ents = []
    for o in range(0, reload + 8, 8):
        e = R.rom0[a0 + 4 + o:a0 + 4 + o + 8]
        ents.append(dict(flags=e[0], x=e[1], y=(e[2] << 8) | e[3], type=e[5], pal=e[7]))
    return freq, reload, ents


if __name__ == "__main__":
    allty = Counter()
    for si, L in enumerate(T.levels + [T.split] + T.ends):
        name = "stage%02d" % si if si < 15 else ("split" if si == 15 else "end%d" % (si - 16))
        ents = scenery_entries(L.scenery)
        rout = Counter(); types = Counter(); pals = set(); tp = Counter()
        for pos, cnt, pat in ents:
            freq, reload, pe = pattern(pat)
            for e in pe:
                r = e["flags"] >> 4
                rout[r] += 1
                types[(e["type"], r)] += 1
                tp[(e["type"], e["pal"])] += 1
                pals.add(e["pal"])
        print("%-8s scen@%06x n=%3d routines=%s" % (name, L.scenery, len(ents), dict(sorted(rout.items()))))
        print("   pals(%d)=%s" % (len(pals), " ".join("%02x" % p for p in sorted(pals))))
        s = []
        for (t, r), n in sorted(types.items()):
            fa = R.r32(R.rom0, TYPE_TABLE + (t << 2))
            l = frame_lods(R, fa)[0]
            s.append("%02x/r%d:%dx%d" % (t, r, l["w"], l["h"]))
            allty[t] += 1
        print("   types:", " ".join(s))
