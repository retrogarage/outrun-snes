"""Inventory of arcade sprite frames used in-game (scenery, specials, traffic, player)."""
from collections import defaultdict
from orroms import Roms
from roadsim import Track
from scen_survey import scenery_entries, pattern
from sprites import frame_lods

TYPE_TABLE = 0x11ED2
SPECIAL = dict(cloud=0x4246, minitree=0x435C, grass=0x4548, sand=0x4588, stone=0x45C8, water=0x4608)
TRAFFIC_PROPS = 0x4CFA
TRAFFIC_DATA = 0x5424
FERRARI_FRAMES = 0x9ECC
SKID_FRAMES = 0x9F1C
PASS_FRAMES = 0xA6EC
SHDW_FRAMES = 0x7862
SHDW_SMALL = 0x1193C
DEF_PROPS1 = 0x2B70

R = Roms()
T = Track(R)


def r32(a):
    return R.r32(R.rom0, a)


def collect():
    """-> dict frame_addr -> dict(uses=set of (context, pal), zmax=max zoom index, kind)"""
    inv = defaultdict(lambda: dict(uses=set(), zmax=0, kind=set()))

    def add(fa, ctx, pal, zmax, kind):
        e = inv[fa]
        e["uses"].add((ctx, pal))
        e["zmax"] = max(e["zmax"], zmax)
        e["kind"].add(kind)

    secs = [("s%02d" % i, L) for i, L in enumerate(T.levels)] + [("split", T.split)] + \
           [("end%d" % i, L) for i, L in enumerate(T.ends)]
    for ctx, L in secs:
        for pos, cnt, pat in scenery_entries(L.scenery):
            freq, reload, pe = pattern(pat)
            for e in pe:
                rt = e["flags"] >> 4
                pal = e["pal"]
                if rt in (1, 3, 10, 11, 14, 12, 2):
                    tab = {1: "grass", 3: "water", 10: "sand", 14: "sand", 11: "stone",
                           12: "minitree", 2: "cloud"}[rt]
                    for k in range(16):
                        fa = r32(SPECIAL[tab] + k * 4)
                        if fa >= 0x40000 or fa & 1 or fa < 0x10000:
                            break
                        add(fa, ctx, 0xCD if rt == 2 else pal, 255, tab)
                else:
                    fa = r32(TYPE_TABLE + (e["type"] << 2))
                    zshift = 2 if rt in (8, 13) else 1
                    add(fa, ctx, pal, 511 >> zshift, "scen")
    # start-line entries
    a = DEF_PROPS1
    for i in range(68):
        e = R.rom0[a:a + 16]
        pal = e[3]
        ty = (e[4] << 8) | e[5]
        fa = r32(TYPE_TABLE + ty)
        add(fa, "s00", pal, 255, "start")
        a += 16
    # traffic
    for t in range(0x14):
        base = TRAFFIC_PROPS + t * 8
        pal = R.rom0[base + 4]
        vt = R.rom0[base + 7]
        for fr in (1, 2, 3):
            for inc in (0, 0x10):
                fa = r32(TRAFFIC_DATA + (vt << 5) + (fr << 2) + inc)
                for pc in (0, 1):
                    add(fa, "traffic", pal + pc, 254, "traffic")
    return inv


if __name__ == "__main__":
    inv = collect()
    print("frames:", len(inv))
    tot = 0
    for fa, e in sorted(inv.items()):
        l = frame_lods(R, fa)[0]
        pals = sorted(set(p for c, p in e["uses"]))
        tot += l["w"] * l["h"]
    print("sum LOD1 area:", tot)
    kinds = defaultdict(int)
    for fa, e in inv.items():
        for k in e["kind"]:
            kinds[k] += 1
    print(dict(kinds))
    pairs = set()
    for fa, e in inv.items():
        for c, p in e["uses"]:
            pairs.add((fa, p))
    print("frame/pal pairs:", len(pairs), " distinct pals:", len(set(p for f, p in pairs)))
