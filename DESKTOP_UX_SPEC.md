# Desktop UX Restoration — Spec

Status: **scoped 2026-08-25** (not started). Owner: simpson1045 + Claude.
Trigger: first run on the 27" 5K iMac made it undeniable — "tiny ant sized shit."

---

## 1. History (why "restoration," not "adding desktop support")

**NASRadio started as a desktop app and was ported to phone.** Somewhere in that
port, the dedicated mobile-layout / desktop-layout separation was lost. Since
then one compromise layout has served both form factors, and every sizing
decision has been a negotiation between a 6" phone and a 27" panel — negotiations
that produce mush. We are not bolting desktop onto a phone app; we are restoring
an architecture this codebase used to have. (Recorded in auto-memory:
`nasradio-desktop-first-history`.)

## 2. Audit — the vestiges (measured 2026-08-25)

- **198 scattered breakpoint checks** (`isMobile`/`isDesktop`/`width < 600`/
  `shortestSide`…) across **22 files** — guerrilla branching, no shared source
  of truth. Hot zones: `search_screen` (33), `now_playing_screen` (24),
  `mini_player` (23), `settings_dialog` (16), `waveform_progress_bar` (13),
  `library_screen` (12), `genre_detail_screen` (12), `artist_detail_screen` (10).
- **11 raw `MediaQuery.of(context).size.width` reads** in 7 more files.
- **The shell (`main_navigation_screen.dart`) has NO desktop handling** — a
  phone bottom-tab bar at every width, plus one fossil TODO: "Re-enable with
  conditional imports for Windows desktop."
- **Both layouts live inline in the giant screens**: `now_playing_screen`
  (184KB), `import_queue_screen` (180KB — includes two parallel MusicBrainz
  result implementations), `youtube_download_screen` (145KB),
  `playlist_detail_screen` (130KB). Worst-case decay: one build method
  serving two form factors via interleaved conditionals.
- 40 screens total in `lib/screens/`.
- Cost of the decay in practice: every UI change is tested against two form
  factors implicitly; regressions ship because a phone fix silently reshapes
  desktop (and vice versa).

## 3. Target architecture

One decision, made once, high in the tree:

```dart
// layout_context.dart (new)
enum AppLayout { mobile, desktop }
// Chosen ONCE per window geometry at the shell; exposed via InheritedWidget
// (LayoutScope.of(context).isDesktop). Breakpoint: >= 1100 logical px wide
// (matches login_screen's precedent). Window resize re-evaluates.
```

- **Shared foundation (unchanged, already good):** services, AudioPlayerService,
  cast stack, ApiService, models, state. The split is VIEW-ONLY.
- **Per-screen layout pairs** where the form factors genuinely diverge:
  `xyz_screen.dart` keeps state + logic, delegating build to
  `layouts/xyz_mobile.dart` / `layouts/xyz_desktop.dart`. Screens where one
  responsive layout honestly serves both (simple lists) stay single-file.
- **Retire local checks as screens are restored** — a screen is "restored" when
  it contains zero ad-hoc width checks and reads `LayoutScope` only.
- `login_screen.dart` (2026-08-25) is the pattern's proof: shared state +
  `_narrowLayout()`/`_wideLayout()`, one breakpoint, no compromise.

## 4. The desktop shell (Phase 1 — the reframing win)

Replace the stretched bottom-tab bar on desktop with a **left navigation rail**:

- Rail: logo mark at top; Home / Library / Search / Playlists / Favorites /
  Playing as icon+label entries; Downloads/Import/Settings in a bottom cluster.
- **Mini-player** docks as a full-width bar across the bottom of the content
  area (not inside the rail) — bigger artwork, real transport controls,
  waveform scrubber, volume slider (desktop has a pointer; use it).
- Content area gets the rest. Every screen instantly reads as a desktop app
  even before its own restoration.
- Mobile keeps the bottom tab bar exactly as-is.

## 5. Screen priority (restore in this order)

| # | Screen | Why | Notes |
|---|--------|-----|-------|
| 1 | Shell / navigation | Reframes everything | Phase 1 above |
| 2 | Dashboard | First screen seen | Denser rails, more per row, richer stat header |
| 3 | Library | Core browsing | Grid density, alphabet jump rail, hover actions |
| 4 | Now Playing | The 184KB monster | Full split: desktop panorama (art + waveform + queue + lyrics side-by-side) vs phone stack |
| 5 | Search | 33 checks — worst offender | Results in columns; filters as sidebar |
| 6 | Album/Artist detail | High traffic | Two-column: art/meta left, tracks right |
| 7 | Queue / Playlists | | Drag-reorder with pointer affordances |
| 8 | Import queue + Prowlarr search | Power-user screens, desktop-dominant usage | Tables > cards on desktop |
| 9 | Settings, dialogs, everything else | | Sweep the remaining checks |

## 6. Desktop manners (Phase 3, after layouts)

- Hover states on every interactive element; cursor changes.
- Right-click context menus (song rows: queue/playlist/favorite/goto-album).
- Keyboard: Space play/pause, arrows seek/skip, Ctrl/Cmd+F focus search,
  Ctrl/Cmd+L library, media keys (already partial via SMTC?).
- Scrollbars visible on desktop; mouse-wheel tuned.
- Window: remember size/position (window_manager already present); sane
  min-size (allow small w/o breaking — small desktop window may borrow the
  MOBILE layout, which the architecture makes free).

## 7. Platform housekeeping (parallel track, small)

- macOS: rename product "frontend" → NASRadio; real app icon (vector source
  recovered: `frontend/assets/images/nasradio_logo.svg`); update-pipeline
  wiring (`macos` platform in update_routes.py + updater platform branch +
  release-macos.sh on IMAC); Skia opt-out of Impeller already done (Intel
  MetalSDF jank).
- Windows: inherits every desktop-layout win automatically.

## 8. Phasing / effort (evenings, incremental, one thing tested at a time)

- **Phase 1:** `LayoutScope` + desktop shell (rail + docked mini-player). 1–2 sessions.
- **Phase 2:** screens #2–#8 in priority order. Each is its own session-sized
  job; ship after each (desktop-only visual changes are low-risk releases).
- **Phase 3:** desktop manners sweep. 1–2 sessions.
- **Definition of done:** zero ad-hoc width checks outside `LayoutScope`;
  `flutter analyze` clean; both form factors screenshot-reviewed per screen.

## 9. Decisions locked with simpson1045 (2026-08-25)

- This is restoration of the desktop-first heritage, not mobile-first retrofit.
- Two dedicated layouts beat one compromise layout. Shared logic, split views.
- Shell first. Incremental per-screen restoration after, shipped as they land.
