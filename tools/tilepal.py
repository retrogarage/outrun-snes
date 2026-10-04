#!/usr/bin/env python3
"""Tile palette packing for SNES 4bpp pictures (BG pages).

pack(tiles, npal) -> (palettes, assignment): each 8x8 tile (a histogram of
15-bit colours) is shown with one of npal palettes of 15 colours.  Greedy
seeding (largest colour sets first, exact fits preferred), then k-means style
refinement: tiles move to the palette with the smallest weighted error, each
palette is recomputed from its tiles (all colours when <= 15, else a weighted
k-medoids reduction that keeps real colours).
"""
import collections


def rgb5(c):
    return (c >> 10) & 31, (c >> 5) & 31, c & 31


def dist(a, b):
    ra, ga, ba = rgb5(a)
    rb, gb, bb = rgb5(b)
    return (ra - rb) ** 2 + (ga - gb) ** 2 + (ba - bb) ** 2


def err(hist, pal):
    if not pal:
        return float('inf')
    return sum(n * min(dist(c, p) for p in pal) for c, n in hist.items())


def reduce(hist, k):
    """weighted k-medoids: <= k colours of hist"""
    cols = sorted(hist, key=lambda c: -hist[c])
    if len(cols) <= k:
        return cols
    # farthest-point seeding from the most frequent colour
    meds = [cols[0]]
    while len(meds) < k:
        meds.append(max(cols, key=lambda c: hist[c] * min(dist(c, m) for m in meds)))
    for _ in range(10):
        groups = collections.defaultdict(list)
        for c in cols:
            groups[min(range(len(meds)), key=lambda i: dist(c, meds[i]))].append(c)
        new = []
        for i in range(len(meds)):
            g = groups.get(i)
            if not g:
                new.append(meds[i])
                continue
            new.append(min(g, key=lambda m: sum(hist[c] * dist(c, m) for c in g)))
        if new == meds:
            break
        meds = new
    return meds


def pack(tiles, npal, maxc=15, iters=12):
    """tiles: list of Counter(colour -> pixels) -> (palettes, assign)"""
    order = sorted(range(len(tiles)), key=lambda i: -len(tiles[i]))
    pals = []
    assign = [0] * len(tiles)
    for i in order:
        cs = set(tiles[i])
        if not cs:
            continue
        best = None
        for k, p in enumerate(pals):
            miss = len(cs - set(p))
            if len(set(p) | cs) <= maxc and (best is None or miss < best[0]):
                best = (miss, k)
        if best is not None:
            k = best[1]
            pals[k] = sorted(set(pals[k]) | cs)
        elif len(pals) < npal:
            pals.append(sorted(cs) if len(cs) <= maxc else reduce(tiles[i], maxc))
        else:
            pass
    while len(pals) < npal:
        pals.append([])
    for it in range(iters):
        changed = 0
        for i, h in enumerate(tiles):
            if not h:
                continue
            k = min(range(npal), key=lambda j: err(h, pals[j]))
            if k != assign[i]:
                changed += 1
                assign[i] = k
        new = []
        for k in range(npal):
            hist = collections.Counter()
            for i, h in enumerate(tiles):
                if h and assign[i] == k:
                    hist.update(h)
            new.append(reduce(hist, maxc) if hist else pals[k])
        if new == pals and not changed:
            break
        pals = new
    total = sum(err(h, pals[assign[i]]) for i, h in enumerate(tiles) if h)
    return pals, assign, total
