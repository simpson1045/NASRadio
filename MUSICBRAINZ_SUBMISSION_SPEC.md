# Feature Spec — Submit Releases to MusicBrainz (from NASRadio)

Status: **Phase 1 backend SHIPPED 2026-08-25** (see §10 — final UX agreed with simpson1045;
in-app modal + webview is the next app-build headline). Scoped 2026-07-21.
Use case: albums/singles in the library that aren't on MusicBrainz (e.g. "Straffer
the Boy Duck" by Stephen Spencer) — so no artwork/metadata enrichment. Let the user
push them *to* MusicBrainz, pre-filled from Spotify + local tags, and capture the new
MBID back so enrichment starts working.

---

## 1. The hard constraint: MusicBrainz has no silent "create" API

You **cannot** POST a new artist/release and have it just appear. MB is community-
curated; new data goes through the **release editor** and (for some edit types) a
voting/review period. The sanctioned way for an external app to submit is **Release
Editor Seeding**: we pre-fill the editor form, hand off to the browser, and the user
reviews + submits under *their own* MB account. This is exactly how tools like
a-tisket and Picard work. So the feature is "prefill + one-click handoff + capture the
result," not "auto-submit."

## 2. Seeding mechanics (confirmed from MB docs)

- **Endpoint:** `POST https://musicbrainz.org/release/add` (HTML form POST).
- **Only `name` is required**; everything else optional.
- **No auth needed to seed** the form. The user just needs to be logged into MB in
  their browser to hit "submit" at the end.
- **`redirect_uri`**: after the user submits, MB redirects there with
  `?release_mbid=<NEW_MBID>` appended. **This is the money feature** — we point it at a
  NASRadio endpoint, capture the MBID, store it on the album, and immediately kick off
  artwork/metadata enrichment.
- Because it's a POST with many fields (full tracklist), the delivery pattern is a
  small **auto-submitting HTML form** (hidden inputs + `<body onload>submit()`), which
  the app opens in a browser/webview. (A GET query-string works for small seeds but a
  tracklist blows past URL limits.)

### Key seed field names
```
name                                             release title
artist_credit.names.0.name                       credited artist name (search aid)
artist_credit.names.0.mbid                        artist MBID (if we can resolve it)
type                                              release-group primary type (Album/Single/EP), repeatable for secondary
status                                            official
events.0.date.year / .month / .day               release date
events.0.country                                 ISO country (optional)
labels.0.name                                     label name
labels.0.catalog_number                          catalog #
barcode                                          UPC/EAN
mediums.0.format                                  e.g. "Digital Media"
mediums.0.track.0.name                            track title
mediums.0.track.0.number                          track number
mediums.0.track.0.length                          MM:SS or milliseconds
mediums.0.track.0.artist_credit.names.0.name      per-track artist
urls.0.url                                        e.g. the Spotify album URL
urls.0.link_type                                  integer link-type id (Spotify streaming); can omit and let user pick
edit_note                                         "Submitted via NASRadio from Spotify + local tags"
redirect_uri                                      NASRadio callback to capture release_mbid
```

## 3. Data sources — Spotify is rich (confirmed live against Straffer)

Official Spotify Web API (already wired: `SpotifyDiscovery().sp`, client creds) gives:
| Spotify field | -> MB seed |
|---|---|
| `album.name` | `name` |
| `album.artists[].name` / `.id` | `artist_credit.names.N.name` |
| `album.release_date` (+ precision) | `events.0.date.year/month/day` |
| `album.label` | `labels.0.name` |
| `album.external_ids.upc` | `barcode` |
| `album.external_urls.spotify` | `urls.0.url` |
| `album.images[0]` | (artwork — already handled by the picker feature) |
| `track.name / track_number / duration_ms` | `mediums.0.track.N.name/number/length` |
| `track.artists[].name` | per-track `artist_credit` |
| `track.external_ids.isrc` | ISRC (see §6 — not seedable in the form; needs write API) |

Fallback when Spotify has nothing: local file tags (already parsed at import) — title,
artist, album, track number, duration. Weaker (no barcode/label/date) but enough to seed.

## 4. End-to-end flow

1. Album detail page, album has no `mbid` -> show a **"Submit to MusicBrainz"** action
   (context menu, next to "Change Type").
2. App -> `GET /api/musicbrainz/seed/<album_id>`.
3. Backend gathers metadata (Spotify search by artist+album -> full album+tracks;
   fall back to local tags), builds the seed field set, returns an **auto-submit HTML
   form** (or a signed token the app opens as a URL).
4. App opens it in a browser/webview -> MB release editor, pre-filled -> user reviews,
   logs in if needed, submits.
5. MB redirects to `GET /api/musicbrainz/callback?album_id=<id>&release_mbid=<mbid>`
   -> backend stores `mbid` on the album, triggers artwork + metadata enrichment.
6. App shows "Submitted — MusicBrainz match linked."

## 5. Backend design

- `app/musicbrainz_seed.py` — build the seed dict from a Spotify album payload and/or
  local tags; render the auto-submit HTML form.
- `GET /api/musicbrainz/seed/<album_id>` — returns the form HTML (or a URL).
- `GET /api/musicbrainz/callback` — captures `release_mbid`, updates the album, kicks
  enrichment. Must be reachable by the user's browser (LAN or the Cloudflare WAN host);
  use the WAN host as `redirect_uri` so it works off-network too.
- Reuse `SpotifyDiscovery` for metadata and the existing artwork pipeline for covers.

## 6. OAuth (Phase 2 — optional)

Seeding needs no OAuth. OAuth2 (MB supports it) is only needed to use the **write API**
for extras the seed form can't carry well — submitting **ISRCs**, tags/genres, ratings —
or to attribute submissions. Defer to phase 2. If added, store the MB user token like
the Last.fm session key.

## 7. Caveats / etiquette

- **Community review**: submissions are edited by a real person (the user) and may be
  voted on. Not instant, not silent. Good — keep the human in the loop.
- **Rate limit**: MB API is 1 req/sec + a descriptive User-Agent (we already set one).
- **Don't mass-submit.** One-at-a-time, user-reviewed. No bulk "submit my whole library."
- **Artist matching**: seeding the artist *name* lets MB/the user match or create. We can
  try to resolve Spotify-artist -> MB-artist MBID first (there's already Spotify<->MB
  artist plumbing in `artist_image_downloader._get_spotify_image`), and seed the MBID
  when confident to avoid duplicate-artist creation.
- **Duplicate check**: before offering "Submit," do a MB search by artist+title and warn
  if a likely match already exists (avoid dupes).

## 8. Phasing / effort

- **Phase 1 (MVP)** — the whole flow above minus OAuth: seed builder + two endpoints +
  one app action + the callback capture. ~Medium. Delivers the core value.
- **Phase 2** — OAuth login + write-API ISRC/tag submission + artist-MBID pre-resolution
  + duplicate-warning. ~Medium.

## 9. Open questions for simpson1045

1. **Where should "Submit to MusicBrainz" live** — album context menu only, or also a
   nudge on album pages that have no MB match?
2. **In-app webview vs. external browser** for the handoff? (Webview keeps it in-app but
   the user must log into MB inside it; external browser likely already has their MB
   session.)
3. **Auto-suggest submission** for un-matched albums, or strictly manual (only when the
   user asks)? (Etiquette leans manual.)
4. Worth doing the **duplicate-check warning** in Phase 1, or defer?
5. Phase 2 OAuth — wanted eventually, or is seed-and-submit enough long-term?

---

## 10. 2026-08-25 — Phase 1 backend SHIPPED; final UX design (agreed with simpson1045)

**Live in `app/musicbrainz_seed.py`** (blueprint `mb_seed_api`, registered in
`__init__.py`; deployed to the container):
- `GET /api/musicbrainz/seed-folder?path=&comment=&token=` — seeds from a **staging
  folder** (pre-import case; §4's flow assumed a library album — folders matter too).
- `GET /api/musicbrainz/seed/<album_id>?comment=&token=` — seeds from a library
  album's files.
- Both build the seed from **local file tags first** (mutagen), NOT Spotify — WEB
  rips carry richer truth: Apple Music m4a's yield barcode (`----:…:UPC`), label
  (`©pub`), release date (`©day`), and the Apple album id (`plID` →
  `urls.0.url = music.apple.com/us/album/<id>`). Spotify stays the Phase-2 fallback
  for tag-poor albums. `comment` query param → MB disambiguation (e.g. "Dolby Atmos").
- `GET /api/musicbrainz/callback?sig=&release_mbid=` — unauthenticated;
  itsdangerous-signed `sig` (salt `nasradio-mb-seed-v1`, 24h) carries the target:
  album seeds → `UPDATE albums SET mbid`; folder seeds → writes `musicbrainz.mbid`
  into the staging folder for the eventual import to pick up.
- Auth on seed pages: full token via header **or `?token=`** (opened in a browser).
- Pilot: Thriller (Dolby Atmos) Apple WEB rip in staging — seed verified (41 fields,
  9 tracks + durations, barcode 074643811224, Epic, 1982, Apple URL). Submission
  itself pending simpson1045's MB editor pass.

**Fact learned:** MB's Thriller release group has **85 releases and zero Atmos
entries** (only Sony 360RA) — spatial editions are patchily catalogued; we will be
creating these entries routinely as the surround collection grows.

**Final UX (simpson1045's design — build in the next app release):**
1. Import Album screen returns release groups **with a "See more" pager**.
2. New action: **"Not listed? Add it now"** → in-app modal, all release sections
   prefilled from a JSON variant of the seed builder, every field editable.
3. Modal submit → backend stages the *edited* fields → **in-app browser popup**
   (webview: WebView2 on Windows, WKWebView on macOS, native on Android; external
   browser stays the Linux/webview-failure fallback) opens MB's release editor
   with those values. One-time MB login per device (webview cookies persist).
4. User presses MB's own submit — the irreducible step; MB has **no create API**
   for anyone (§1 stands confirmed).
5. The webview **intercepts the callback navigation**, grabs `release_mbid`
   directly from the nav event, closes itself, app shows "Linked ✓". (Redirect
   page remains as fallback; interception also stops tokens riding in visible URLs.)
6. Import duplicate/MBID handling then keys off the release-level id — dovetails
   with the planned `albums.mb_release_id` column (release-level vs release-group
   linking; drill-down "sub-releases" picker is the sibling feature).
