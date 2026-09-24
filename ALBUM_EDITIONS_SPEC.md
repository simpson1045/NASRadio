# Album Editions — Spec (the Jellyfin-style version model)

Status: **scoped 2026-08-25** (not started). simpson1045's insight, same evening the
mix-aware tooling shipped: "instead of multiple listings of the same album for
different audio formats… a single release page that I can choose the format on."

---

## 1. Why (the root flaw the workarounds have been orbiting)

The library treats every edition as a separate album, so twin-mix albums
(stereo + Atmos Thriller, stereo + SACD Piano Man) either collide (Piano Man
double-layer incident) or multiply (title-suffix convention: "Bad (Dolby
Atmos)", "Piano Man (SACD 5.0)"). Every recent feature is a compensation:

- amber STEREO IN LIBRARY search badge (owning ≠ owning THIS mix)
- import duplicate veto via ffprobe (`different_mix`)
- Read-Tags "(Dolby Atmos)" album-title suffix
- MBID collisions between twins (stereo copy owns the release-group id)

Jellyfin's model (one movie, many versions — proven on simpson1045's own
Empire/Jedi grouping 2026-08-25) fixes the class: **one album, many editions.**

## 2. Data model

New layer ABOVE albums; current albums become editions of a group.

- `album_groups(id, title, artist_id, mbid /*release-group*/ , created_at)`
- `albums` gains: `group_id` (nullable FK), `edition_label` (text, e.g.
  "Dolby Atmos", "SACD 5.0", "2011 Remaster"; NULL = default/primary),
  `mb_release_id` (release-LEVEL MBID — kills the twin-MBID collision;
  dovetails with the rg-releases drill-down shipped 2026-08-25).
- Ungrouped albums (the overwhelming majority) stay `group_id = NULL` and
  behave exactly as today — the layer is opt-in per album.
- Migration for existing twins: title-suffix convention parses straight into
  labels — "Bad (Dolby Atmos)" → group "Bad", edition "Dolby Atmos".

**Grouping is a HUMAN decision** with machine suggestions. Fuzzy auto-grouping
is how the Piano Man/Van Halen mis-home disasters happened. Build on the
existing `album_merge_screen` tooling.

## 3. Import flow (simpson1045's requirement, 2026-08-25)

The import screen must handle **album exists AND lacks this mix**:

- The mix-aware duplicate check ALREADY returns this exact verdict:
  `match_type: "different_mix"` + the matched `album_id` (shipped d8ce26d +
  e7aa803). Today it only suppresses the delete button; in this model it
  drives an edition chooser on the Import Album screen:

  > Your library has "Thriller" (stereo FLAC). This folder is a different
  > mix (Atmos).
  > (•) Add as a new edition of that album   ← default
  > ( ) Import as a separate album

- "New edition": import attaches the files as a labeled edition in the
  existing group (creating the group on the fly if the matched album was
  ungrouped). Edition label auto-suggested by the same detection that
  prefills MB disambiguation (ffprobe Atmos profile / channels / folder
  fingerprint) — user editable.
- Reverse case identical (importing stereo when only Atmos is owned).
- Same-mix match keeps today's behavior (true duplicate).

## 4. Playback & UI

- **Album page**: one page per group; edition picker (chips/dropdown showing
  label + format badges). Tracklist reflects the chosen edition. Design this
  WITH the desktop-UX album-detail restoration (DESKTOP_UX_SPEC §5 #6) — one
  redesign, not two.
- **Phase-2 killer feature — context-aware edition defaults**: per-output
  preference. Cast to the C2 → prefer the spatial edition (album-level
  generalization of the per-track sidecar logic); phone/direct → prefer
  stereo/lossless. Explicit user pick always wins and can be remembered
  per group.
- Library browse/search/queue show the GROUP (one card), with a small
  multi-edition indicator (like Jellyfin's version count).
- Play counts/favorites: per-song per-edition underneath (no data change),
  surfaced aggregated at group level in UI. Playlists keep referencing
  concrete songs (edition-explicit) — no magic substitution in v1.
- Cast resolve_query: group title resolves to the context-preferred edition.

## 5. MusicBrainz integration

- Group carries the release-group MBID; each edition carries its own
  release MBID (picked via the rg-releases drill-down, or captured by the
  submission callback for editions we add to MB ourselves).
- The MB submission flow (MUSICBRAINZ_SUBMISSION_SPEC §10) plugs in: a new
  edition without an MB release gets the "Add it to MusicBrainz" path, and
  the callback links the release id to THAT edition.

## 6. Phasing

- **Phase 1**: schema + manual grouping UI (merge-into-group, ungroup,
  set label) + album-page edition picker + import-screen edition chooser
  (§3). Migrate the existing suffixed twins.
- **Phase 2**: context-aware playback defaults (cast→spatial). The magic.
- **Phase 3**: scanner import-time suggestions ("looks like an edition of
  X — group it?"), aggregated stats presentation, release-MBID backfill
  for existing editions.

## 7. Interactions / cautions

- Coordinate with DESKTOP_UX album-detail restoration (shared redesign).
- Cast sidecars: edition selection happens BEFORE per-track sidecar logic;
  a chosen spatial edition may still need sidecars for PCM multichannel.
- The tonight-import of "Thriller (Dolby Atmos)" (suffix convention) is
  forward-compatible: migration inhales it as a label. Nothing wasted.
