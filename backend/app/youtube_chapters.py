"""
YouTube chapter parsing.

YouTube has its own description-timestamp chapter parser, but it's strict
(must start at 0:00, requires `TIMESTAMP TITLE` ordering, at least 3
timestamps, each chapter ≥10s). Tons of OST uploads fail those rules even
though they have a perfectly readable tracklist in the description — that's
where this module steps in. We parse more permissively than YouTube does so
the chapter-split import can extract tracks from descriptions like:

    0:00 SimCity Segue                ← Format A: TIMESTAMP TITLE
    5:33 Mayor Mambo
    1:05:52 Driving Mode BGM 1

    #1 - Among 0:00                   ← Format B: TITLE TIMESTAMP, with prefix
    #11- Hunt 2 20:54
    #30 - Welcome 56:11

Public API:

    parse_chapters_from_description(description: str, video_duration: int)
        → list[{"order_index", "start_seconds", "end_seconds", "title"}]

Returns [] if no plausible tracklist is detected, in which case the caller
should fall back to importing the video as a single track.
"""
from __future__ import annotations

import re
from typing import Optional


# A timestamp is M:SS or H:MM:SS (or H:MM:SS with up to 2-digit hour).
# `\b` boundaries keep us from matching mid-token garbage. The hour group is
# optional so plain "5:33" and "1:05:52" both work.
_TS_RE = re.compile(r"\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b")

# Title-prefix patterns we strip *once* from the front of a candidate title
# after the timestamp is removed. Order matters — more specific first.
_PREFIX_PATTERNS = [
    # "#1 - ", "#11- ", "#1.", "#1)" — case-insensitive `#` + digits + optional separator
    re.compile(r"^\s*#\s*\d+\s*[-.:)]?\s*", re.IGNORECASE),
    # "Track 1:", "Track 12 - ", "Trk 03." — common label-style prefix
    re.compile(r"^\s*(?:track|trk)\s*\d+\s*[-.:)]?\s*", re.IGNORECASE),
    # "01.", "1)", "1-", "01:" — bare numeric ordering prefix
    re.compile(r"^\s*\d{1,3}\s*[-.:)]\s*", re.IGNORECASE),
]

# Decorative junk to strip from both ends of the title once prefix is removed.
_TRIM_RE = re.compile(r"^[\s\-_:|.\[\](){}]+|[\s\-_:|.\[\](){}]+$")

# Cap how many tracks we'll return in a single tracklist — even prog-rock OSTs
# rarely break 100 tracks. Anything beyond this is almost certainly the parser
# falsely matching incidental timestamps.
_MAX_TRACKS = 200


def _timestamp_to_seconds(match: re.Match) -> int:
    """Convert a regex match from _TS_RE to total seconds."""
    h = int(match.group(1)) if match.group(1) is not None else 0
    m = int(match.group(2))
    s = int(match.group(3))
    return h * 3600 + m * 60 + s


def _clean_title(raw: str) -> str:
    """Strip common track-number prefixes and decorative chars from a title."""
    s = raw.strip()
    for pat in _PREFIX_PATTERNS:
        new_s = pat.sub("", s, count=1)
        if new_s != s:
            s = new_s
            break  # Only strip ONE prefix pattern, not all of them
    s = _TRIM_RE.sub("", s).strip()
    return s


def parse_chapters_from_description(
    description: str,
    video_duration: Optional[int],
) -> list[dict]:
    """
    Extract a tracklist from a free-form YouTube description.

    Returns an ordered list of chapter dicts:
        [{"order_index": int, "start_seconds": int, "end_seconds": int|None,
          "title": str}, ...]

    Algorithm:
      1. Walk description lines in order.
      2. Per line: find timestamps. Require EXACTLY ONE per line (multiple
         timestamps on one line are usually time-range references like
         "Solo 1:30-2:15", not chapter markers).
      3. Whichever side of the timestamp has more visible text is the title.
      4. Accumulate (start_seconds, title) only when start strictly exceeds
         the previously-accepted entry's start — silently drop out-of-order
         candidates so a noise line ("Recorded at 12:00 PM") sitting between
         real tracklist entries doesn't reset everything.
      5. Need ≥2 valid entries AND first start ≤60s to call it a tracklist.
      6. Compute end_seconds[i] = start_seconds[i+1]; end of last = video
         duration if known, else None.

    `video_duration` is in seconds; pass None if unknown (last chapter's
    end_seconds will be None — caller decides what to do).
    """
    if not description:
        return []

    candidates: list[tuple[int, str]] = []
    last_accepted_start = -1

    for line in description.splitlines():
        line = line.strip()
        if not line:
            continue

        matches = list(_TS_RE.finditer(line))
        if len(matches) != 1:
            # Zero timestamps → not a candidate line. Multiple → probably a
            # time-range reference; skip rather than gamble on which is which.
            continue

        m = matches[0]
        try:
            start = _timestamp_to_seconds(m)
        except (ValueError, TypeError):
            continue

        # Drop if outside the actual video runtime (with a small buffer for
        # rounding/length-mismatch). Without this, a stray "12:00 PM" line in
        # an album description would be accepted as a 720s "chapter".
        if video_duration is not None and start > video_duration + 5:
            continue

        # Strip the timestamp from the line; whatever remains is the title.
        raw_title = (line[: m.start()] + line[m.end() :]).strip()
        title = _clean_title(raw_title)
        if not title:
            continue

        # Enforce strict ascending: drop lines that go backwards in time, so a
        # mid-description noise timestamp doesn't break the parse. This also
        # naturally dedupes exact-duplicate timestamps (only first wins).
        if start <= last_accepted_start:
            continue

        candidates.append((start, title))
        last_accepted_start = start

        if len(candidates) >= _MAX_TRACKS:
            break

    # A real tracklist has at least 2 entries and starts near the beginning.
    if len(candidates) < 2:
        return []
    if candidates[0][0] > 60:
        return []

    chapters: list[dict] = []
    for i, (start, title) in enumerate(candidates):
        if i + 1 < len(candidates):
            end: Optional[int] = candidates[i + 1][0]
        else:
            end = video_duration if (video_duration is not None and video_duration > start) else None
        chapters.append(
            {
                "order_index": i,
                "start_seconds": start,
                "end_seconds": end,
                "title": title,
            }
        )
    return chapters


# ---- Self-test against the real SimCity 2000 + JPOG descriptions -----------

_SIMCITY_DESC = """There are a lot of uploads of the PlayStation soundtrack to the hit classic SimCity 2000 (the best version of the soundtrack, who are we kidding), but not one of them has the tracks extended for our listening pleasure, nor do they have the three driving mode tracks exclusive to the PlayStation. So many nostalgic memories of playing this game on my 13 inch Mitsubishi TV, hearing my favorite tracks play for hours on end... feels so weird to listen to the OST and only get 50 seconds to 2 minutes worth at a time. Well consider this problem solved! I have quadrupled the length of each track and compiled them into one album giving us 90 minutes of pure 1996 SimCity bliss!

I may not own the rights to these tracks, but I definitely own the right to give a huge thanks to the composer, Sue Kasper! Your score is amazing and brings me such joy!

0:00 SimCity Segue
5:33 Mayor Mambo
8:41 Downtown Dance
12:35 City Shimmy
19:36 Virtual Village
23:36 Railroad Rap
27:46 Traffic Trouble
32:50 Subway Song
38:13 Chinatown Cencerto
42:02 Harbor Hymn
48:37 Repetition Rendition
51:53 Disaster Decision
57:12 Serious Sims
1:02:11 Bluesy Berg
1:05:52 Driving Mode BGM 1
1:14:16 Driving Mode BGM 2
1:21:43 Driving Mode BGM 3"""

_JPOG_DESC = """Soundtrack completo de Jurassic Park Operation Genesis, videojuego disponible para las siguientes plataformas: Xbox - PlayStation 2 y PC.

#1 - Among 0:00
#2 - Brachiosaurus 3:33
#3 - Breakout 5:54
#4 - Chase 7:28
#5 - Dinoplay 10:37
#6 - Dusk 12:15
#7 - Endgame 15:47
#8 - Dinosaur Fly By 16:16
#9 - Hammond 18:28
#10 - Hunt 19:04
#11- Hunt 2 20:54
#12- Inpark 23:03
#13 - L DInos 26:57
#14- Ludlow 29:08
#15 - New Life 29:24
#16 - Night D 30:00
#17 - Raptor 34:04
#18 - Safari 34:28
#19 - Sleep 36:29
#20 - Spino 39:40
#21 - Storm 40:04
#22 - Stormend 41:27
#23 - Stormfro 41:48
#24 - Sunrise 43:21
#25 - Tornado 47:00
#26 - T-Rex 49:04
#27 - Twilight 49:33
#28 - Victory 52:53
#29 - Waterhol 53:08
#30 - Welcome 56:11

Contacto: example@example.com
Discord Oficial: https://discord.gg/example"""


def _run_self_test() -> int:
    """Returns 0 on success, 1 on failure. Run via `python -m app.youtube_chapters`."""
    failures = 0

    # --- SimCity: 17 tracks, format A (TIMESTAMP TITLE) -----------------
    simcity = parse_chapters_from_description(_SIMCITY_DESC, video_duration=5356)  # 1:29:16
    expected_simcity = [
        (0, "SimCity Segue"),
        (333, "Mayor Mambo"),
        (521, "Downtown Dance"),
        (755, "City Shimmy"),
        (1176, "Virtual Village"),
        (1416, "Railroad Rap"),
        (1666, "Traffic Trouble"),
        (1970, "Subway Song"),
        (2293, "Chinatown Cencerto"),
        (2522, "Harbor Hymn"),
        (2917, "Repetition Rendition"),
        (3113, "Disaster Decision"),
        (3432, "Serious Sims"),
        (3731, "Bluesy Berg"),
        (3952, "Driving Mode BGM 1"),
        (4456, "Driving Mode BGM 2"),
        (4903, "Driving Mode BGM 3"),
    ]
    print(f"SimCity 2000: parsed {len(simcity)} chapters (expected {len(expected_simcity)})")
    if len(simcity) != len(expected_simcity):
        print(f"  FAIL: wrong chapter count")
        failures += 1
    for i, (exp_start, exp_title) in enumerate(expected_simcity):
        if i >= len(simcity):
            break
        got = simcity[i]
        ok = got["start_seconds"] == exp_start and got["title"] == exp_title
        marker = "  ok" if ok else "  FAIL"
        print(f"{marker} [{i:02d}] start={got['start_seconds']:>5} title='{got['title']}'"
              + ("" if ok else f"  (expected start={exp_start} title='{exp_title}')"))
        if not ok:
            failures += 1
    # last chapter's end should be video duration
    if simcity and simcity[-1]["end_seconds"] != 5356:
        print(f"  FAIL: last chapter end={simcity[-1]['end_seconds']} (expected 5356)")
        failures += 1
    # middle chapter ends should equal next chapter starts
    for i in range(len(simcity) - 1):
        if simcity[i]["end_seconds"] != simcity[i + 1]["start_seconds"]:
            print(f"  FAIL: chapter {i} end={simcity[i]['end_seconds']} but next start={simcity[i+1]['start_seconds']}")
            failures += 1

    # --- JPOG: 30 tracks, format B (TITLE TIMESTAMP, with #N prefix) ----
    jpog = parse_chapters_from_description(_JPOG_DESC, video_duration=3588)  # 59:48
    print(f"\nJPOG: parsed {len(jpog)} chapters (expected 30)")
    if len(jpog) != 30:
        print(f"  FAIL: wrong chapter count")
        failures += 1
    expected_jpog_first = [
        (0, "Among"),
        (213, "Brachiosaurus"),
        (354, "Breakout"),
    ]
    expected_jpog_last = [
        (3188, "Victory"),
        (3188, "Waterhol"),  # placeholder; real value computed below
        (3371, "Welcome"),
    ]
    # The expected starts for the last 3, based on the description:
    # Victory 52:53 = 3173s, Waterhol 53:08 = 3188s, Welcome 56:11 = 3371s
    expected_jpog_last = [
        (3173, "Victory"),
        (3188, "Waterhol"),
        (3371, "Welcome"),
    ]
    for i, (exp_start, exp_title) in enumerate(expected_jpog_first):
        if i >= len(jpog):
            break
        got = jpog[i]
        ok = got["start_seconds"] == exp_start and got["title"] == exp_title
        marker = "  ok" if ok else "  FAIL"
        print(f"{marker} [{i:02d}] start={got['start_seconds']:>5} title='{got['title']}'"
              + ("" if ok else f"  (expected start={exp_start} title='{exp_title}')"))
        if not ok:
            failures += 1
    if len(jpog) >= 3:
        for offset, (exp_start, exp_title) in enumerate(expected_jpog_last):
            got = jpog[-(3 - offset)]
            ok = got["start_seconds"] == exp_start and got["title"] == exp_title
            marker = "  ok" if ok else "  FAIL"
            print(f"{marker} [{len(jpog) - 3 + offset:02d}] start={got['start_seconds']:>5} title='{got['title']}'"
                  + ("" if ok else f"  (expected start={exp_start} title='{exp_title}')"))
            if not ok:
                failures += 1

    # --- Empty / no-tracklist input should return [] --------------------
    print("\nEmpty input: ", end="")
    empty = parse_chapters_from_description("", 100)
    if empty == []:
        print("ok ([])")
    else:
        print(f"FAIL ({empty!r})")
        failures += 1

    print("\nGeneric description (no timestamps): ", end="")
    generic = parse_chapters_from_description("Subscribe and like!\nVisit my website.", 100)
    if generic == []:
        print("ok ([])")
    else:
        print(f"FAIL ({generic!r})")
        failures += 1

    print("\nSingle-timestamp tracklist (insufficient): ", end="")
    single = parse_chapters_from_description("0:00 Only Track", 100)
    if single == []:
        print("ok ([])")
    else:
        print(f"FAIL ({single!r})")
        failures += 1

    print("\n" + "=" * 60)
    if failures == 0:
        print("OK")
    else:
        plural = "s" if failures != 1 else ""
        print(f"FAILED ({failures} failure{plural})")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    import sys
    sys.exit(_run_self_test())
