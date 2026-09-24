"""
Utility functions for NASRadio
"""

import re
import unicodedata


def parse_artists(artist_string):
    """
    Parse a free-text artist string into individual artist names, in order.

    Handles formats like:
    - "Eminem, Dr. Dre, Sly Pyper"
    - "Elton John & Eric Clapton"
    - "Artist feat. Artist" / "Artist featuring Artist" / "Artist ft. Artist"
    - "A; B" (multi-value tag separator)
    - "A / B" — a slash WITH spaces around it (credit lists like
      "Iggy Pop / Rob Duprey / Chris Stein")
    - "A\x00B" — raw multi-value ID3 frames, in case a caller hands one over

    Returns names in their original order, de-duplicated case-insensitively
    (so a count loop can't credit the same artist twice). Always returns at
    least one entry; falls back to ["Unknown Artist"] for empty input.

    Shared by the file scanner (reading TPE1/Vorbis tags) and the YouTube
    importer (parsing the hand-typed artist field) so both resolve the same
    way. Note: a bare "/" is intentionally NOT a separator because it appears
    inside legitimate single-artist names (e.g. "AC/DC"); only " / " with
    whitespace on both sides is. " with " is not split either: it is a word
    in too many band names ("Sleeping With Sirens").
    """
    if not artist_string:
        return ["Unknown Artist"]

    # Replace collaboration phrases with commas (most-specific first, all
    # whitespace-anchored so we never split mid-word — e.g. "ft" in a name).
    normalized = artist_string.strip().replace("\x00", ", ")
    normalized = re.sub(r"\s+featuring\s+", ", ", normalized, flags=re.IGNORECASE)
    normalized = re.sub(r"\s+feat\.?\s+", ", ", normalized, flags=re.IGNORECASE)
    normalized = re.sub(r"\s+ft\.?\s+", ", ", normalized, flags=re.IGNORECASE)
    normalized = re.sub(r"\s+&\s+", ", ", normalized)
    normalized = re.sub(r"\s+/\s+", ", ", normalized)
    normalized = normalized.replace(";", ",")

    # De-duplicate case-insensitively while preserving first-seen order.
    seen = set()
    artists = []
    for name in normalized.split(","):
        name = name.strip()
        if not name:
            continue
        key = name.lower()
        if key not in seen:
            seen.add(key)
            artists.append(name)

    return artists or ["Unknown Artist"]


def normalize_text_for_search(text):
    """
    Normalize text for search by:
    - Removing diacritics (ö→o, ü→u, é→e, etc.)
    - Removing punctuation entirely for fuzzy matching
    - Converting to lowercase
    - Normalizing whitespace

    This allows "motley crue" to match "Mötley Crüe"
    and "youre no good" to match "You're No Good"
    """
    if not text:
        return ""

    # Normalize unicode characters (NFD = decompose characters with diacritics)
    # Then filter out combining characters (the accent marks)
    normalized = unicodedata.normalize("NFD", text)
    without_accents = "".join(
        char
        for char in normalized
        if unicodedata.category(char) != "Mn"  # Mn = Mark, Nonspacing (diacritics)
    )

    # Remove punctuation entirely (apostrophes, quotes, dashes, etc.)
    # Keep only alphanumeric and spaces
    cleaned = "".join(
        char if char.isalnum() or char.isspace() else "" for char in without_accents
    )

    # Collapse multiple spaces and convert to lowercase
    return " ".join(cleaned.lower().split())
