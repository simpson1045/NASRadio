"""Which MusicBrainz release is this folder? (Import screen "★ Best match")

A release group (e.g. Christopher Cross, 1979) holds every pressing: CDs,
SHM-CDs, vinyl, 8-tracks, standard and hi-res downloads, expanded editions.
The folder being imported carries enough clues to pick one, the same ones a
person would check by hand (Oct 27: the 24/96 "WEBQ" Christopher Cross =
the 2015 hi-res digital release):

  - track count                   -> rules out expanded/deluxe editions
  - bit depth / sample rate       -> 24-bit or >48 kHz can't be a CD
  - track lengths vs MB lengths   -> different masters differ by seconds
  - the .nfo "Source:" / label    -> WEB vs CD vs vinyl, Rhino/Warner...
  - folder-name hints             -> [Flac 24-96], Vinyl, WEB, SACD

score_releases() adds {"match": {"score", "reasons": [{"ok", "text"}]}} to
each release and returns which one (if any) is the clear best match.
"""

import os
import re

from mutagen import File as MutagenFile

AUDIO_EXTENSIONS = {".flac", ".mp3", ".m4a", ".wav", ".ogg", ".opus",
                    ".aac", ".wma", ".wv", ".ape", ".aiff", ".dsf", ".dff"}

# Points needed to call a release the best match, and the lead it needs
# over the runner-up; closer than that and the app says "possible match".
_MIN_SCORE = 40
_CLEAR_LEAD = 10


def analyze_folder(folder):
    """Folder -> facts used for matching (no MusicBrainz involved)."""
    files = sorted(
        os.path.join(folder, f) for f in os.listdir(folder)
        if os.path.splitext(f)[1].lower() in AUDIO_EXTENSIONS)
    lengths, bits, rates = [], set(), set()
    for path in files:
        try:
            m = MutagenFile(path)
        except Exception:
            m = None
        info = getattr(m, "info", None) if m is not None else None
        if info is None:
            continue
        if getattr(info, "length", None):
            lengths.append(int(round(info.length * 1000)))
        b = getattr(info, "bits_per_sample", None)
        if b:
            bits.add(int(b))
        r = getattr(info, "sample_rate", None)
        if r:
            rates.add(int(r))

    nfo_source = nfo_label = None
    for f in os.listdir(folder):
        if f.lower().endswith(".nfo"):
            try:
                with open(os.path.join(folder, f), encoding="utf-8",
                          errors="replace") as fh:
                    text = fh.read(20000)
            except OSError:
                continue
            m = re.search(r"^\s*Source\W*:\s*(.+?)\s*$", text, re.M | re.I)
            if m:
                nfo_source = m.group(1).strip()
            m = re.search(r"^\s*(?:Label|Information|Publisher)\W*:\s*(.+?)\s*$",
                          text, re.M | re.I)
            if m:
                nfo_label = m.group(1).strip()
            break

    name = os.path.basename(folder.rstrip("/")).lower()
    hint = None
    if re.search(r"\b(vinyl|lp|needle ?drop|vinylrip)\b", name):
        hint = "vinyl"
    elif re.search(r"\b(web|webrip|web-?dl|itunes|qobuz|tidal|hdtracks)\b", name):
        hint = "digital"
    elif re.search(r"\bsacd\b", name):
        hint = "sacd"
    elif re.search(r"\bcd(rip)?\b", name):
        hint = "cd"

    max_bits = max(bits) if bits else None
    max_rate = max(rates) if rates else None
    return {
        "track_count": len(files),
        "lengths": lengths if len(lengths) == len(files) else [],
        "bits": max_bits,
        "rate": max_rate,
        "hires": bool((max_bits and max_bits > 16) or (max_rate and max_rate > 48000)),
        "nfo_source": nfo_source,
        "nfo_label": nfo_label,
        "name_hint": hint,
    }


def _kind(formats):
    f = " ".join(formats).lower()
    if "digital" in f:
        return "digital"
    if "sacd" in f:
        return "sacd"
    if "vinyl" in f or '"' in f:
        return "vinyl"
    if "cd" in f:
        return "cd"
    return "other"


def _source_kind(source):
    s = (source or "").lower()
    if not s:
        return None
    if "web" in s or "itunes" in s or "qobuz" in s or "tidal" in s or "flac" == s:
        return "digital"
    if "vinyl" in s or "lp" in s.split():
        return "vinyl"
    if "sacd" in s:
        return "sacd"
    if "cd" in s:
        return "cd"
    return None


def _fmt_quality(facts):
    if facts["bits"] and facts["rate"]:
        return f"{facts['bits']}-bit/{facts['rate'] / 1000:g} kHz"
    return "hi-res" if facts["hires"] else "standard resolution"


def score_releases(releases, facts):
    """Annotate releases in place; return {"best", "candidates", "summary"}."""
    src = _source_kind(facts.get("nfo_source"))
    label_words = {w for w in re.findall(r"[a-z0-9]{3,}", (facts.get("nfo_label") or "").lower())
                   if w not in {"records", "music", "entertainment", "the", "inc", "ltd"}}

    for r in releases:
        score, reasons = 0, []

        def add(points, ok, text):
            nonlocal score
            score += points
            reasons.append({"ok": ok, "text": text})

        kind = _kind(r.get("formats") or [])
        n, mine = r.get("track_count") or 0, facts["track_count"]
        if n and mine:
            if n == mine:
                add(30, True, f"{mine} tracks")
            else:
                add(-40, False, f"has {n} tracks, yours has {mine}")

        lengths = r.get("track_lengths") or []
        if facts["lengths"] and len(lengths) == len(facts["lengths"]) and all(lengths):
            diff = sum(abs(a - b) for a, b in zip(facts["lengths"], lengths)) / len(lengths) / 1000
            if diff <= 2:
                add(30, True, f"track lengths match (±{diff:.0f}s)")
            elif diff <= 5:
                add(15, True, f"track lengths close (±{diff:.0f}s)")
            else:
                add(-10, False, f"track lengths differ by ~{diff:.0f}s")

        q = _fmt_quality(facts)
        dis = (r.get("disambiguation") or "").lower()
        if facts["hires"]:
            if kind in ("cd",):
                add(-30, False, f"{q} can't come from a CD")
            elif kind == "digital":
                if re.search(r"hi-?res|24[- ]?bit|96|192", dis):
                    add(30, True, f"{q} → hi-res download (MusicBrainz marks it hi-res)")
                else:
                    add(5, True, f"a {q} download, but this one isn't marked hi-res")
            elif kind == "vinyl":
                add(5, True, f"{q} could be a vinyl rip")
            elif kind == "sacd":
                add(5, True, f"{q} could be an SACD rip")
        elif facts["bits"]:
            if kind in ("cd", "digital"):
                add(5, True, f"{q} fits a {'CD' if kind == 'cd' else 'download'}")

        if src:
            if src == kind:
                add(15, True, f".nfo says {facts['nfo_source']}")
            elif kind in ("digital", "cd", "vinyl", "sacd"):
                add(-20, False, f".nfo says {facts['nfo_source']}, this is {kind}")
        elif facts.get("name_hint"):
            if facts["name_hint"] == kind:
                add(10, True, f"folder name says {facts['name_hint']}")

        labels = " ".join(r.get("labels") or []).lower()
        if label_words and labels and any(w in labels for w in label_words):
            add(5, True, f"label matches ({', '.join(r.get('labels')[:2])})")

        r["match"] = {"score": score, "reasons": reasons}

    ranked = sorted(releases, key=lambda x: x["match"]["score"], reverse=True)
    best, candidates = None, []
    if ranked and ranked[0]["match"]["score"] >= _MIN_SCORE:
        top = ranked[0]["match"]["score"]
        candidates = [x["id"] for x in ranked if top - x["match"]["score"] < _CLEAR_LEAD]
        if len(candidates) == 1:
            best = candidates[0]
    for x in releases:
        x["match"]["best"] = x["id"] == best
        x["match"]["candidate"] = best is None and x["id"] in candidates

    bits = [f"{facts['track_count']} tracks", _fmt_quality(facts)]
    if facts.get("nfo_source"):
        bits.append(f".nfo: {facts['nfo_source']}")
    return {"best": best, "candidates": candidates, "summary": " · ".join(bits)}
