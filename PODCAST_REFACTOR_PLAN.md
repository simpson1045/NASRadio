# Podcast Refactor Plan

**Status:** DRAFT — awaiting simpson1045's review/approval before execution.
**Author:** Claude + simpson1045, 2026-04-17
**Estimated effort:** ~4 focused sessions (refactor) + 1 quick-wins session (redirect resolution, updater bug).

---

## 1. Problem Statement

The current podcast implementation treats episodes as **virtual music tracks** — `Song(id: -episodeId, albumId: -feedId, filePath: streamURL)`. This shortcut has caused:

- Constant bugs in `audio_player_service.dart` every time music and podcast logic touch shared state (`_currentEpisodeId` leaks, stale progress timers firing against dead episodes, playlist listener blocking podcast advance).
- Four separate bugfix patches yesterday alone, all plugging leaks in the same broken abstraction.
- A fragile `song.id < 0` guard pattern scattered across the codebase.
- Destabilization of music features we spent months building.
- 10-second playback start time due to tracking redirect chains that are never cached or resolved.

We've been treating symptoms. This plan treats the cause.

---

## 2. Goals

1. **Eliminate the virtual Song / negative ID pattern entirely.** Podcast episodes become real rows in `songs`, differentiated by a `source_type` column.
2. **Reuse the music player's battle-tested playback, queue, and sync infrastructure** for podcasts. No branching in `audio_player_service.dart`.
3. **Preserve the orange podcast UI** (Now Playing, mini player, widgets) — now driven by `source_type`, not ID sign.
4. **Fix the 10s playback delay** by resolving and caching final CDN URLs (bypass tracker redirect chains on resume — standard behavior for mature podcast apps).
5. **Lay the groundwork for chapters** (RSS `podcast:chapters` + ID3 CHAP frames inside MP3s) without re-architecting later.

## 3. Non-Goals

- **Not** nuking the existing podcast UI screens (discovery, feed detail, subscribe flow). These keep working; only the data they query shifts.
- **Not** replacing Podcast Index for discovery. That's a separate concern and it works.
- **Not** building a standalone podcast player screen. Now Playing handles both with theme switching.
- **Not** touching the recommender service. It's fine where it is.

---

## 4. Target Architecture

### Data model (conceptual)

```
Artist (Tom Welling & Michael Rosenbaum)
  └─ Album (Talk Ville)                           ← podcast feed
      ├─ Song (S03E15 — Bloodline)                ← podcast episode
      │   ├─ Chapter (Intro,        0:00 → 3:24)
      │   ├─ Chapter (Plot Recap,   3:24 → 18:42)
      │   ├─ Chapter (AD: BetterHelp, 18:42 → 20:15, is_skippable=true)
      │   └─ Chapter (Interview,    20:15 → 58:00)
      ├─ Song (S03E14 — ...)
      └─ Song (S03E13 — ...)
```

- Episode → one row in `songs` (source_type='podcast', file_path = resolved CDN URL).
- Feed → one row in `albums` (linked to an artist row for the podcast author).
- Chapters → rows in a new `song_chapters` table (works for music too, unused for now).

### Player behavior

`audio_player_service.dart` becomes mode-agnostic. It just plays `Song` objects. The UI layer reads `song.sourceType` to decide theming and which controls to show (skip 30s vs next track, chapter strip vs waveform, etc).

### Resume position

Moves from `rss_episodes.played_position` to `songs.played_position` (new column). Unified with existing music sync — one code path, one WebSocket event.

---

## 5. Schema Changes

### 5.0 New column on `rss_feeds`

```sql
ALTER TABLE rss_feeds ADD COLUMN play_order TEXT NOT NULL DEFAULT 'newest_first';
  -- 'newest_first' | 'oldest_first'
  -- Drives both episode list display order and "play all" queue order.
  -- Set via the existing newest/oldest sort toggle on the feed detail screen.
```

### 5.1 New columns on `songs`

```sql
ALTER TABLE songs ADD COLUMN source_type TEXT NOT NULL DEFAULT 'local';
  -- 'local'   : music file on NAS (existing behavior)
  -- 'podcast' : remote episode, file_path is a URL

ALTER TABLE songs ADD COLUMN podcast_feed_id    INTEGER REFERENCES rss_feeds(id) ON DELETE CASCADE;
ALTER TABLE songs ADD COLUMN podcast_episode_id INTEGER REFERENCES rss_episodes(id) ON DELETE CASCADE;

ALTER TABLE songs ADD COLUMN source_url   TEXT;       -- original tracker-wrapped URL (re-resolve on expiry)
ALTER TABLE songs ADD COLUMN resolved_url TEXT;       -- final CDN URL (what the player actually hits)
ALTER TABLE songs ADD COLUMN resolved_url_expires_at TIMESTAMP;  -- null = doesn't expire

ALTER TABLE songs ADD COLUMN played_position INTEGER DEFAULT 0;  -- resume position, seconds
ALTER TABLE songs ADD COLUMN is_completed    INTEGER DEFAULT 0;  -- mark episodes as done

CREATE INDEX idx_songs_source_type ON songs(source_type);
CREATE INDEX idx_songs_podcast_episode ON songs(podcast_episode_id);
CREATE INDEX idx_songs_podcast_feed ON songs(podcast_feed_id);
```

**Note on `file_path` UNIQUE constraint:** podcast URLs are unique by nature, so this is fine. But we need to make sure the same episode isn't inserted twice — migration + feed refresh both guard against this via `podcast_episode_id`.

### 5.2 New table: `song_chapters`

```sql
CREATE TABLE song_chapters (
    id                 SERIAL PRIMARY KEY,
    song_id            INTEGER NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
    order_index        INTEGER NOT NULL,
    start_time_seconds INTEGER NOT NULL,
    end_time_seconds   INTEGER,                    -- null = runs to next chapter's start, or EOF
    title              TEXT,
    image_url          TEXT,                       -- per-chapter artwork (rare, used by some shows)
    link_url           TEXT,                       -- external link (e.g., sponsor URL)
    is_skippable       BOOLEAN DEFAULT FALSE,      -- true for ads, Patreon callouts, etc.
    source             TEXT,                       -- 'rss' (podcast:chapters) | 'id3' (CHAP frame) | 'manual'
    UNIQUE(song_id, order_index)
);

CREATE INDEX idx_song_chapters_song ON song_chapters(song_id);
```

### 5.3 `rss_episodes` table: kept as staging/metadata

We do **not** drop this table. It continues to be the source-of-truth for podcast-specific metadata (GUID, publish date, RSS description, downloaded_path). The refactor adds a one-to-one link from `songs.podcast_episode_id` to `rss_episodes.id`. On feed refresh, new episodes land in `rss_episodes` FIRST, then get mirrored into `songs`.

**Why keep both:** `rss_episodes` has fields that don't belong on `songs` (guid uniqueness per feed, downloaded_path, RSS raw metadata). Cleanly separating "podcast metadata" from "playable item" keeps things tidy.

---

## 6. Migration Strategy

### 6.1 Data backfill (one-time script)

For each row in `rss_feeds`:
1. Find or create an `artists` row with `name = feed.author` (fall back to `feed.title` if author is null).
2. Find or create an `albums` row with `(artist_id, title = feed.title)`. Store artwork.

For each row in `rss_episodes`:
3. Find or create a `songs` row with:
   - `title = episode.title`
   - `artist_id = <feed's artist>`, `album_id = <feed's album>`
   - `file_path = episode.audio_url` (will get resolved to CDN URL on first play; see §7)
   - `source_type = 'podcast'`
   - `podcast_feed_id`, `podcast_episode_id` populated
   - `duration = episode.audio_duration`
   - `played_position = episode.played_position` (carry over resume state)
   - `is_completed = episode.is_completed`
   - `created_at = episode.published_at` (so chronological sort works out of the box)

**Idempotent:** script checks for existing `songs.podcast_episode_id = X` before inserting, so safe to re-run.

### 6.2 Filtering the music library

Existing music screens (artist list, album list, browse by album, search) need a default `WHERE songs.source_type = 'local'` filter so Talk Ville doesn't clutter your music library.

Podcast screens query the inverse: `WHERE songs.source_type = 'podcast'` joined with `rss_feeds` / `rss_episodes` for podcast-specific metadata.

### 6.3 Rollback

Every migration step is behind a single feature flag (`PODCAST_UNIFIED_MODEL = True/False` in config). If something goes wrong:
1. Set flag to `False`.
2. Frontend + backend revert to reading podcast state from `rss_episodes` via the old code path (still present during transition).
3. New columns on `songs` stay in place, ignored.

The *backfilled* `songs` rows are inert until the flag is on — no impact on music.

---

## 7. Redirect Resolution (the 10s → sub-second fix)

This is a standalone feature but ships WITH the refactor since it lands in the same schema.

### Flow
1. **Feed refresh:** when a new episode appears, spawn a background greenthread that does a HEAD-chasing loop on `audio_url`:
   - `requests.head(url, allow_redirects=True)` → final URL
   - Store `source_url` (original) + `resolved_url` (final) + `resolved_url_expires_at` (parse `Expires` header if signed, else null)
2. **On playback:** `stream_song` for podcast songs returns a 302 redirect to `resolved_url` (or streams through if the client can't follow redirects).
3. **On 403/expiry:** re-resolve, update, retry — transparent to the player.
4. **For pre-existing episodes without `resolved_url`:** lazy resolve on first play. After that, cached.

### Why this is correct podcast-app behavior
All mature apps (Overcast, Pocket Casts, Castro, Apple Podcasts) resolve-once-cache-forever. IAB guidelines dedupe downloads by IP+UA/day, so this doesn't short the publisher on analytics. First play still goes through the full tracker chain. Resumes don't — and shouldn't.

### Expected improvement
- Current: ~10s to first byte (5 redirects × ~200-500ms + TLS + DNS per hop).
- After: ~200-500ms to first byte (single CDN request).

---

## 8. Chapters

### Sources (in priority order)

1. **`<podcast:chapters url="...chapters.json"/>`** — modern podcast namespace. JSON file with `chapters: [{startTime, title, img, url, toc}]`. Parsed at feed refresh.
2. **PSC (Podlove Simple Chapters)** — older inline XML (`<psc:chapters>` in each item). Parsed at feed refresh.
3. **ID3v2 CHAP/CTOC frames** — embedded inside the MP3 itself. Required for Megaphone shows (Talk Ville has NO RSS chapters). Parsed via `mutagen` on first play or download, cached in `song_chapters`.

### UI
- Chapter strip on Now Playing screen (only if `song_chapters` has rows for the current song).
- Tap a chapter → seek to `start_time_seconds`.
- "Next chapter" / "Previous chapter" buttons (podcast mode only).
- "Auto-skip ads" toggle (setting) — when on, chapters with `is_skippable=true` are skipped on playback.

### Skippable detection
- RSS/PSC chapters with `toc: false` → `is_skippable = true`.
- ID3 chapters with title matching common ad patterns (Squarespace, BetterHelp, NordVPN, Athletic Greens, Factor, etc.) → `is_skippable = true` with some heuristic confidence. User can toggle per-chapter.

---

## 9. Phase Breakdown (Execution Order)

Each phase leaves the repo in a shippable state. You can pause between any two.

### Phase 0 — Quick wins (~1 session, can ship first)
- [x] Fix `_isNewer` in [update_service.dart:71](frontend/lib/services/update_service.dart:71) — add `buildNumber` tiebreak when semver is equal. **Done 2026-04-17.**
- [x] Silence recommender `WSAECONNREFUSED` log spam when service is off. **Done 2026-04-17.**
- [ ] (Optional) Add WSL2 transcode auto-start to `start_all.bat` — needs simpson1045 to confirm WSL2 command.

**Ships independently. Cut a v1.0.2 release before touching the refactor.**

### Phase 1 — Schema + migration (~1 session) ✅ DONE 2026-04-17
- [x] Add new columns to `songs` + new `song_chapters` table (idempotent `CREATE IF NOT EXISTS` + `ADD COLUMN IF NOT EXISTS`).
- [x] `rss_feeds.play_order` column added (default `'newest_first'`).
- [x] Write backfill script (`backend/migrate_podcasts_to_songs.py`).
- [x] Add `PODCAST_UNIFIED_MODEL` feature flag (default OFF).
- [x] Run backfill locally, verify data integrity manually.
- [x] Existing code continues to read from `rss_episodes` — no behavior change.

**Backfill results:** 10 feeds, 4,482 episodes → songs rows with `source_type='podcast'`. All resume positions carried over exactly from `rss_episodes.played_position`. Music catalog (38,616 `source_type='local'` tracks) untouched. Feature flag OFF — no behavior change. Ready for Phase 2.

### Phase 2 — Redirect resolution (~1 session) ✅ DONE 2026-04-17
- [x] Implement `resolve_audio_url()` in `rss_feeds.py` using `requests` with `allow_redirects=True`.
- [x] Hook into `refresh_feed()` — new episodes get mirrored into `songs` via `sync_feed_to_songs()` and resolved in greenthreads.
- [x] `stream_song` short-circuits for `source_type='podcast'`: returns 302 to `resolved_url` (re-resolves if expired).
- [x] Lazy-resolve endpoint `/api/rss/episodes/<id>/resolve` for on-demand.
- [x] Bulk backfill script `backend/resolve_podcast_urls.py` for the 4,482 existing songs.
- [ ] Frontend wire-up deferred to Phase 3 (flag-gated). Current app still uses legacy path, so no user-visible change yet — but backend infrastructure is complete.

**Measured resolve times on live feeds:**
- ASOT (miroppb): 1 redirect, ~1.2s → sub-second after cache
- Talk Ville (Megaphone, 5-hop chain through Podtrac/Chartable/mgln.ai/Claritas/Megaphone): ~3.6s → sub-second. Signed URL with 6-hour TTL handled by the expiry re-resolve path.
- StarTalk (Podtrac → SimpleCast): ~0.8s → sub-second.
- Jurassic Park (Podomatic, signed): ~1.2s → sub-second, TTL ~6h.

**Status:** Backfill resolver running in background — ~1/s throughput, ~90 min total for 4,482 episodes. Lazy resolve handles anything not yet backfilled. **Backend restart required** to activate the new stream_song behavior; existing backend still serves the legacy path until restarted (safe — podcast playback on current frontend doesn't hit /api/stream).

### Phase 3a — Groundwork (✅ DONE 2026-04-17)

The negative-ID pattern is gone from everywhere the UI cares about. Podcasts are still played via the existing `playPodcastEpisode()` code path, but every "is this a podcast?" check now reads `song.isPodcast` (which is `sourceType == 'podcast'`) instead of `song.id < 0`. This is semantically identical on today's virtual Songs — but means the day we move podcasts fully to real `songs` rows (Phase 3b), zero UI code has to change.

- [x] Song model: new fields `sourceType`, `podcastFeedId`, `podcastEpisodeId`, `playedPosition`, `isCompleted` + `isPodcast` getter.
- [x] Virtual Songs in `playPodcastEpisode()` now stamp `sourceType='podcast'` + real episode/feed IDs.
- [x] **All** `song.id < 0` / `song.id > 0` podcast-identity guards swapped for `song.isPodcast` / `!song.isPodcast` — across `audio_player_service.dart`, `audio_handler.dart`, `cast_service.dart`, `now_playing_screen.dart`.
- [x] Music library queries filter `source_type = 'local'`: `/api/artists`, `/api/albums`, `/api/songs` (+ total count), `/api/search` (artists, albums, songs). Podcast-only artists/albums stop polluting the music library.
- [x] `RssFeed` model gains `playOrder`. `PUT /api/rss/feeds/<id>` accepts `play_order` writes (validated to `newest_first`/`oldest_first`).
- [x] **Sort button on feed detail screen wired to per-feed `play_order`** — SharedPreferences bool removed, each feed's order comes from the backend. Talk Ville can be `oldest_first` while ASOT stays `newest_first`.
- [x] Queue-on-play from feed detail: existing `playPodcastEpisode(allEpisodes: [...])` path gets episodes already in `play_order` via `_loadEpisodes()`, so the queue builds correctly.

### Phase 3b — Full consolidation (deferred, low urgency)

Now that all callers use `isPodcast` instead of ID signs, the remaining cleanup is code-quality:

- [ ] Eventually: flip `PODCAST_UNIFIED_MODEL=true`, route `playPodcastEpisode` callers to `playSong` on real `songs` rows (loaded by `podcast_episode_id`).
- [ ] Then strip: `_currentEpisodeId`, `_clearPodcastMode`, `_podcastProgressTimer`, `_advanceToNextPodcastEpisode`, `playPodcastEpisode`, `_updatePodcastEpisodeFromSong`. Normal music queue/advance handles everything.
- [ ] Queue-on-resume from outside feed detail (e.g. "Continue Listening" on discovery) — load full feed into queue.
- [ ] Search screen split: "Music (N)" + "Podcasts (N)" sections.
- [ ] Device sync: retire `podcast_episode_updated`, unify progress events.

**Ship note:** Phase 3a is shippable on its own. User-visible wins:
- Music library no longer shows ASOT / Talk Ville / etc. as artists or albums.
- Per-feed sort order (Talk Ville: oldest first, ASOT: newest first) instead of one global toggle.
- Zero regression risk — behavior is identical because `isPodcast` returns true for exactly the same Song objects that had `id < 0`.

**Ships with feature flag guarding rollback. Full test matrix required:**
- Music playback (all existing scenarios).
- Podcast playback (fresh, resume, advance, mid-playback retry, podcast→music switch, music→podcast switch).
- Device sync (desktop→phone and back).
- Both platforms (media_kit desktop + just_audio mobile).

### Phase 4 — Chapters (✅ DONE 2026-04-17, core feature)
- [x] `parse_chapters_from_feed()` — scans an RSS feed for `<podcast:chapters url="...">` URLs.
- [x] `fetch_chapters_json()` — pulls the podcast-namespace JSON spec. Honors `toc: false` (hidden-from-TOC = ad marker).
- [x] `fetch_chapters_from_id3()` — reads ID3v2 CHAP/CTOC frames via HTTP Range. Downloads just the tag (usually 1-5 MB), never the audio.
- [x] `ensure_chapters_for_song()` — idempotent populator that persists to `song_chapters`.
- [x] On-demand parsing: `_ensure_chapters_async()` fires in a greenthread from `stream_song()` the first time a podcast plays. Non-blocking, cached after.
- [x] `GET /api/songs/<id>/chapters` — generic endpoint.
- [x] `GET /api/rss/episodes/<id>/chapters` — episode-keyed, for podcast playback (virtual Songs have negative IDs that don't resolve to songs rows directly).
- [x] Frontend `SongChapter` model + `getSongChapters` / `getEpisodeChapters` on ApiService.
- [x] `ChapterStrip` widget — horizontal scroller, highlighted active chapter, auto-scrolls as position advances, AD badge on skippable chapters, tap to seek. Renders `SizedBox.shrink()` when no chapters (safe to unconditionally include).
- [x] Wired into both mobile and desktop Now Playing layouts (between progress bar and transport controls).
- [x] PSC (Podlove) inline parsing — deferred. None of simpson1045's feeds use it; revisit if a feed requires it.

**Deferred to Phase 4b (polish, feature-adds):**
- [ ] "Next chapter" / "Previous chapter" buttons on the transport bar.
- [ ] Auto-skip-ads toggle (setting) — seeks past chapters where `is_skippable=true`.
- [ ] Chapter artwork display (ID3 rarely has per-chapter art; podcast: JSON sometimes does).
- [ ] RSS feed-refresh hook to capture `<podcast:chapters>` URLs and pre-populate for feeds that publish them. Currently on-demand only.

---

## 14. Audit-driven Work List (post-refactor)

From the full podcast audit on 2026-04-17. simpson1045's answers recorded. Ordered by session.

### Session A — broken stuff
- [ ] Error states in Podcast Discovery: retry button + clear message for each section's load failure (`podcast_discovery_screen.dart:86-159`).
- [ ] Download progress UI — button updates from "download" → "downloading" → "downloaded" or "failed" based on WebSocket events (`rss_feed_detail_screen.dart:619-625`; backend already emits `podcast_download_complete`).
- [ ] HTML stripping consistency across ALL episode description displays (feed detail rows, discovery cards, now playing).
- [ ] Cross-device episode sync on Discovery screen — Continue Listening should update when another device advances an episode.
- [ ] Sort toggle debounce in feed detail.

### Session B — chapter polish
- [ ] Tick marks on the scrubber at each chapter start.
- [ ] Slide-in "Chapters" modal sheet (alternative to the bottom strip for picking a chapter).
- [ ] Chapter artwork display in both the strip and the modal.

### Session C — user-visible features
- [ ] Search within a feed (filter episode list by title).
- [ ] "Mark all as played" button for a feed.
- [ ] Per-feed auto-download toggle in feed detail UI (`RssFeed.autoDownload` already on the model).
- [ ] Listen Later quick-queue (add-to-queue button on discovery/search cards).

### Session D — heavy hitters
- [ ] Auto-skip intro/outro timers (per-feed setting).
- [ ] Episode retention policy (auto-delete played episodes older than N days).
- [ ] Unified playlists (music + podcast episodes mixed) — UI on top of existing songs-table architecture.
- ~~Episode share link with timestamp~~ — scrapped for now (simpson1045 is the only user; revisit if the app opens up).

### Session E — code quality / Phase 3b cleanup
- [ ] Strip virtual negative-ID Songs — route everything through `playSong()` on real songs rows.
- [ ] Consolidate `_currentEpisodeId` / `_podcastTitle` / `_podcastFeedId` etc. into `_currentSong` (single source of truth).
- [ ] One `_startProgressTimer()` method instead of three copies.
- [ ] Promote sleep timer to a visible button on podcast Now Playing (currently buried in the three-dot menu).
- [ ] OPML subscription export + import.

### Future (separate sessions)
- [ ] **Fire OS-specific build** — sideloadable APK with remote-friendly navigation and voice controls, tuned for Firestick/Fire TV. Separate project; will share backend and most of the Flutter code but need a dedicated UI layer.

**Validated on:** ASOT Ep 1273 — 29 chapters with `Artist – Track` titles pulled from ID3 CHAP frames in ~1s via a 2MB Range request. Same pattern will work for every feed with ID3 chapters (Megaphone shows included). Skippable detection flags well-known ad sponsor names (Squarespace, BetterHelp, NordVPN, etc.) — can be tuned over time.

---

## 10. File-Level Change Map

### Backend
- `backend/app/models.py` — new columns, new table, new indexes.
- `backend/app/rss_feeds.py` — `resolve_audio_url()`, `parse_chapters_json()`, chapter backfill hook.
- `backend/app/routes.py` — new endpoints: `/api/rss/episodes/<id>/resolve`, chapter endpoints; modify `stream_song` for podcast redirect.
- `backend/migrate_podcasts_to_songs.py` — new, one-shot backfill.
- `backend/app/device_sync.py` — unify progress events (remove `podcast_episode_updated` special case).

### Frontend
- `frontend/lib/services/audio_player_service.dart` — **major simplification**. Strip all podcast-specific code paths.
- `frontend/lib/services/device_sync_service.dart` — remove `onPodcastEpisodeUpdated`, use unified progress.
- `frontend/lib/screens/now_playing_screen.dart` — check `song.sourceType` for theming.
- `frontend/lib/screens/rss_feed_detail_screen.dart` — query songs joined with episodes.
- `frontend/lib/screens/podcast_discovery_screen.dart` — update "continue listening" to query songs.
- `frontend/lib/models/song.dart` — add `sourceType`, `playedPosition`, `isCompleted`, `chapters` fields.
- `frontend/lib/widgets/chapter_strip.dart` — new.
- `frontend/lib/widgets/mini_player.dart` — theme check.

---

## 11. Decisions (answered 2026-04-17)

1. **Music library filtering — CONFIRMED.** Every music-browsing query gets `WHERE songs.source_type = 'local'`: Artists screen, Albums screen, Songs/search, recent, most played, home carousels. Search screen shows both but labeled separately ("Music: N results" / "Podcasts: N results"). Podcast screens query the inverse.
2. **Play-all order — per-feed, wired to existing sort button.** New column `rss_feeds.play_order` (`'newest_first'` default | `'oldest_first'`). The existing newest/oldest sort toggle on the feed detail screen writes to this column. Affects both the episode list display AND the "play all" queue order AND the queue built on resume (see §11.2a below).
   - **11.2a — Queue on resume/play:** when an episode is played (or resumed), the player queue is built as *all episodes in that feed*, sorted by the feed's `play_order`, with the current episode positioned at its correct index. This way natural playback advances through the feed in the user's preferred direction.
3. **Favorites on episodes — YES.** Reuses existing favorites table (`item_type='song'`). Especially useful for DJ-mix shows like ASOT where a specific week has a standout mix.
4. **Playlists — YES.** Podcast episodes can be added to playlists same as music tracks. Free win from the unified model.
5. **Play count / history — YES.** Podcasts track plays through the existing `play_history` table. Future analytics can split by `source_type`.
6. **`rss_episodes` long-term — KEEP.** Stays as a staging/metadata table. Separation pays off every time we need podcast-specific metadata without bloating `songs`.

---

## 11.5. Chapter Strategy — Validated Against Real Feeds

Verified 2026-04-17 against actual feeds simpson1045 subscribes to.

| Feed | RSS `podcast:chapters` | ID3 CHAP frames | Strategy |
|------|------------------------|-----------------|----------|
| Talk Ville (Megaphone) | ❌ None (namespace not even declared) | Likely yes (Megaphone standard) | ID3 CHAP parse via `mutagen` on first play |
| A State of Trance (miroppb) | ❌ None (namespace declared, unused) | ✅ **29 CHAP + 1 CTOC** confirmed in Ep 1273 | ID3 CHAP parse — full DJ tracklist |

ASOT Episode 1273 ID3 dump (2026-04-17, verified via mutagen):
- **29 chapter frames**, each labeled with proper `"Artist – Track Title"` format.
- Example: `67.9m — Gareth Emery feat. Christina Novelli – Concrete Angel`
- Core tags: Artist=`Armin van Buuren`, Album=`A State of Trance`, Title=`Episode 1273`.
- **miroppb.com serves the MP3 with NO tracking redirects** — direct URL, so Phase 2 redirect-resolution is a no-op for ASOT specifically. Matters for Megaphone/Talk Ville.

Implication: **both subscribed feeds need ID3 CHAP parsing**. RSS `podcast:chapters` support still ships (required for feeds that DO publish it), but ID3 is the workhorse.

### ASOT-specific UX win
DJ mixes have 20-30 tracks per episode. The chapter strip + "next/previous track" buttons + per-chapter favoriting (Q3: yes) means you can favorite *specific tracks within a mix*. "I loved that Gareth Emery track at 67.9m in ASOT 1273" → one tap, saved.

---

## 12. Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Migration breaks music library | Feature flag OFF by default; backfill is idempotent and doesn't touch music rows. |
| UNIQUE(file_path) collision with existing music | Podcast URLs are distinct from NAS paths; constraint is safe. |
| Resume position sync conflicts across devices | Existing music sync already handles this; we inherit it automatically. |
| Signed CDN URLs expire | `resolved_url_expires_at` + auto-reresolve on 403. |
| Chapter parsing fails on some feeds | Graceful degradation — no chapters just means no chapter strip. Never blocks playback. |
| Build/install regressions during Phase 3 | Feature flag lets us toggle back to current behavior per-device if anything breaks. |

---

## 13. Decision Point

**simpson1045's call:**
- Approve plan as-is → I'll start with Phase 0 (quick wins) → test APK on phone → Phase 1.
- Modify specific sections → let's iterate.
- Reject / major rework → tell me what's wrong.

Once you sign off, this doc becomes the single source of truth for execution. Each phase gets a checklist update as it lands.
