# -*- coding: utf-8 -*-
"""A shuffle that feels random: each artist's songs spread evenly through the
list (random starting point, a little jitter), then a final pass keeps the
same artist from playing twice in a row wherever possible.

A plain shuffle is truly random, and true randomness clumps (Nov 11, 2026:
four Phil Collins / Genesis songs in seven, Sussudio straight into One More
Night). Same method as the app's lib/utils/balanced_shuffle.dart.
"""
import random as _random


def balanced_shuffle(items, artist_of=lambda s: s.get("artist_name"), rnd=None):
    """Return a new list; items without an artist count as unique."""
    rnd = rnd or _random
    items = list(items)
    if len(items) < 3:
        rnd.shuffle(items)
        return items

    def key_of(item, index):
        a = (artist_of(item) or "").strip().lower()
        return a or f"\0{index}"

    groups = {}
    for i, it in enumerate(items):
        groups.setdefault(key_of(it, i), []).append(it)

    placed = []
    for key, songs in groups.items():
        rnd.shuffle(songs)
        gap = 1.0 / len(songs)
        offset = rnd.random() * gap
        for i, s in enumerate(songs):
            jitter = (rnd.random() - 0.5) * gap * 0.4
            placed.append((offset + i * gap + jitter, key, s))
    placed.sort(key=lambda p: p[0])
    keys = [p[1] for p in placed]
    out = [p[2] for p in placed]

    def fits(pos, key):
        return ((pos == 0 or keys[pos - 1] != key)
                and (pos == len(keys) - 1 or keys[pos + 1] != key))

    for i in range(1, len(out)):
        if keys[i] != keys[i - 1]:
            continue
        for j in range(i + 1, len(out)):
            if keys[j] == keys[i - 1]:
                continue
            ki, kj = keys[i], keys[j]
            keys[i], keys[j] = kj, ki
            if fits(i, kj) and fits(j, ki):
                out[i], out[j] = out[j], out[i]
                break
            keys[i], keys[j] = ki, kj
    return out
