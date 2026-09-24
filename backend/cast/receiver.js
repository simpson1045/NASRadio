/**
 * NASRadio Custom Cast Receiver
 * Uses the Cast Application Framework (CAF) Receiver SDK v3
 * Features: custom UI, waveform progress bar, synced lyrics (toggled from phone)
 */

// Startup marker — visible in Chrome remote debug console at chrome://inspect
// (or the Chromecast debugger). If you don't see this line at session
// start, the receiver is running a cached older copy of this file and
// the cache buster in receiver.html needs another bump.
const NASRADIO_RECEIVER_VERSION = 'v38 — scrolling titles';

// Live diagnostic counters rendered on the TV. Combined.log roundtrip
// for DIAG_BOOT / DIAG_KEY / DIAG_MSG came back empty even though v13
// confirmed the new receiver IS loaded — so something in the
// sendCustomMessage path is failing. This HUD bypasses round-trip
// entirely: every counter increments on-device, so you can press keys,
// look at the TV, and see exactly which code paths fire.
//
//   K = window.keydown events caught (zero so far in testing)
//   I = playerManager message interceptor invocations
//        — should fire on remote-sent PLAY/PAUSE/SEEK/STOP
//   S = context.sendCustomMessage attempts (any DIAG_* try)
//   E = sendCustomMessage exceptions caught (try/catch fail count)
//   B = SENDER_CONNECTED event fires (should be >=1 once connected)
//   D = SENDER_DISCONNECTED event fires
//
// If S increments but combined.log stays empty, the message is being
// sent but lost in transit. If S stays at 0 but I increments, the
// interceptor fires but our send wrapper isn't getting called (logic
// bug). If everything stays at 0, no remote-key event of any kind
// reaches the receiver at all.
// Diagnostic counters. Surfaced both on the on-screen HUD (single-letter
// labels) and in DIAG_HEARTBEAT messages back to the sender:
//   K = window keydown events
//   I = playerManager message interceptors fired (PLAY/PAUSE/STOP/SEEK)
//   S = sendDiagToSender calls
//   E = errors
//   B = SENDER_CONNECTED events
//   D = SENDER_DISCONNECTED events
//   T = watchdog setInterval ticks (proves JS event loop is alive)
//   M = updateMediaInfo calls (counts MEDIA_STATUS event flood — added
//       in v19 to confirm/refute the "MEDIA_STATUS flood blocks JS"
//       hypothesis for the song-2 cast drop)
const _diag = { K: 0, I: 0, S: 0, E: 0, B: 0, D: 0, T: 0, M: 0 };
let _diagPlayerState = '?';

// HUD overlay removed — diag counters still publish to sender via
// DIAG_HEARTBEAT messages (sender-side log has the same info without
// covering the on-screen timestamp).
function _renderDiagHud() {}

// Watchdog tick — increments _diag.T once per second + polls the
// playerManager's state so the HUD reflects the live player state.
// (v15 tried to use a `PLAYER_STATE_CHANGED` event type that doesn't
// exist in CAF SDK v3 — the addEventListener call threw and halted
// JS execution before context.start() ran, which is why v15 hung
// with SYSTEM_ERROR on every relaunch attempt. Polling sidesteps
// that entirely — works regardless of which event types the SDK
// exposes.) If the tick stops incrementing on the TV while a cast
// session is supposedly active, the receiver's JS thread has
// frozen — drop in heartbeat tx-rx delta should correlate.
// Track BUFFERING time so we can detect stuck media playback. A
// network blip during the cast device's audio HTTP fetch corrupts
// the media element's state — CAF SDK doesn't auto-retry, so the
// receiver stays in BUFFERING forever while the cast TCP session
// stays alive. We notify the sender once we've been stuck for >15s
// so it can trigger a re-LOAD as recovery. Notification repeats
// every ~10s while still stuck so the sender can see how long.
let _bufferingSinceMs = null;
let _lastStuckReportSec = 0;

// Track when playerManager.getCurrentTimeSec() last actually moved.
// "audio stalled but state still says PLAYING" is a signature failure
// mode (the underlying media element froze but CAF hasn't transitioned
// out of PLAYING yet) — the diff between "claimed state" and "real
// progress" is exactly what we need to distinguish that from healthy
// playback. Compared against a small float-equal tolerance so we don't
// flag a 0.000001s drift as "audio moved".
let _lastCurrentTime = null;
let _lastCurrentTimeChangedAt = performance.now();
let _heartbeatTickCounter = 0;

setInterval(() => {
  _diag.T++;
  try {
    const state = playerManager.getPlayerState() || '?';
    _diagPlayerState = state;

    if (state === cast.framework.messages.PlayerState.BUFFERING) {
      if (_bufferingSinceMs === null) {
        _bufferingSinceMs = performance.now();
        _lastStuckReportSec = 0;
      } else {
        const stuckSec =
          Math.floor((performance.now() - _bufferingSinceMs) / 1000);
        // First report at 15s, then every 10s after that.
        if (
          (stuckSec >= 15 && _lastStuckReportSec === 0) ||
          (stuckSec >= _lastStuckReportSec + 10)
        ) {
          _lastStuckReportSec = stuckSec;
          sendDiagToSender({
            type: 'DIAG_STUCK_BUFFERING',
            seconds: stuckSec,
          });
        }
      }
    } else {
      _bufferingSinceMs = null;
      _lastStuckReportSec = 0;
    }

    // Currentime change tracker for the stall-vs-state diagnosis.
    const ct = playerManager.getCurrentTimeSec();
    if (typeof ct === 'number' && !isNaN(ct)) {
      if (_lastCurrentTime === null ||
          Math.abs(ct - _lastCurrentTime) > 0.001) {
        _lastCurrentTime = ct;
        _lastCurrentTimeChangedAt = performance.now();
      }
    }

    // Every 5th watchdog tick (~5 seconds), push the receiver's
    // internal state to the sender so combined.log has a fresh
    // snapshot to dump at the moment of any drop. Cheap message,
    // doesn't churn the sender's UI — only the drop-incident report
    // reads it.
    _heartbeatTickCounter++;
    if (_heartbeatTickCounter >= 5) {
      _heartbeatTickCounter = 0;
      const bufferingMs = _bufferingSinceMs !== null
        ? Math.floor(performance.now() - _bufferingSinceMs)
        : null;
      const timeUpdateAgoMs =
        Math.floor(performance.now() - _lastCurrentTimeChangedAt);
      sendDiagToSender({
        type: 'DIAG_HEARTBEAT',
        tick: _diag.T,
        playerState: state,
        currentTime: typeof ct === 'number' && !isNaN(ct) ? ct : null,
        bufferingMs: bufferingMs,
        timeUpdateAgoMs: timeUpdateAgoMs,
        counters: {
          K: _diag.K, I: _diag.I, S: _diag.S,
          E: _diag.E, B: _diag.B, D: _diag.D,
          M: _diag.M,
        },
      });
    }
  } catch (_) {}
  _renderDiagHud();
}, 1000);

// Screen Wake Lock. simpson1045's report: LG TV screensaver kicks in the
// instant a song's audio output ends, which preempts the cast app
// and kills the session in the 1-2s gap between MEDIA_STATUS
// FINISHED and our next() LOAD. wakeLock.request('screen') tells
// the OS "I'm doing media playback, don't screensaver this." We
// request once on receiver load and again every time the visibility
// flips back (browsers/OSes release wake locks on tab/page hide).
async function acquireWakeLock() {
  try {
    if ('wakeLock' in navigator) {
      const lock = await navigator.wakeLock.request('screen');
      console.log('[NASRadio] Wake lock acquired');
      lock.addEventListener('release', () => {
        console.log('[NASRadio] Wake lock released');
      });
    } else {
      console.log('[NASRadio] navigator.wakeLock not supported');
    }
  } catch (e) {
    console.log('[NASRadio] Wake lock failed:', e);
  }
}
acquireWakeLock();
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    acquireWakeLock();
  }
});

console.log('[NASRadio] Receiver loaded:', NASRADIO_RECEIVER_VERSION);

const context = cast.framework.CastReceiverContext.getInstance();
const playerManager = context.getPlayerManager();

// Custom namespace for NASRadio messages (waveform, lyrics, badges, toggle)
const NASRADIO_NS = 'urn:x-cast:com.nasradio.custom';

// Track the active sender's ID for sendCustomMessage() calls. Some CAF
// SDK versions accept `undefined` for senderId (broadcast to all
// connected senders), some don't — to avoid that ambiguity we capture
// the connected sender's ID from the SENDER_CONNECTED event and use it
// explicitly when sending diagnostic messages back. Falls back to
// `undefined` (broadcast) if no sender event has fired yet.
let _activeSenderId = null;
// Every connected sender, so a guest (the backend joining a phone-started
// cast) can be told apart from the owner and messages relayed between them.
const _senders = new Set();

function sendDiagToSender(payload) {
  _diag.S++;
  _renderDiagHud();
  try {
    context.sendCustomMessage(NASRADIO_NS, _activeSenderId, payload);
  } catch (e) {
    _diag.E++;
    _renderDiagHud();
    console.log('[NASRadio] sendCustomMessage threw:', e);
  }
}

context.addEventListener(
  cast.framework.system.EventType.SENDER_CONNECTED,
  (event) => {
    _diag.B++;
    _activeSenderId = event.senderId;
    _senders.add(event.senderId);
    _renderDiagHud();
    console.log('[NASRadio] Sender connected:', _activeSenderId);
    sendDiagToSender({
      type: 'DIAG_BOOT',
      version: NASRADIO_RECEIVER_VERSION,
    });
  },
);

context.addEventListener(
  cast.framework.system.EventType.SENDER_DISCONNECTED,
  (event) => {
    _diag.D++;
    _renderDiagHud();
    // Send the disconnect notice immediately while another sender
    // might still be connected. If this lands in combined.log shortly
    // before the cast_session socket onDone, we know the cast device
    // initiated tear-down via SENDER_DISCONNECTED, not just a socket
    // drop. If no DIAG_SENDER_DISCONNECTED line appears before the
    // socket onDone, the cast device killed the TCP socket without
    // firing the SDK event.
    sendDiagToSender({
      type: 'DIAG_SENDER_DISCONNECTED',
      senderId: event.senderId,
      reason: event.reason || null,
    });
    _senders.delete(event.senderId);
    if (_activeSenderId === event.senderId) {
      // Fall back to whoever is still here (the phone, when the backend
      // guest drops), so waveform requests keep going somewhere useful.
      _activeSenderId = _senders.size ? [..._senders][0] : null;
    }
  },
);

// Receiver tear-down signal. When the user kills the cast app from
// the TV remote (Home / Back / pick a different cast app on the TV),
// the SDK fires SHUTDOWN before the page actually unloads. We fire a
// one-shot DIAG_RECEIVER_SHUTDOWN to the sender so it knows the
// upcoming disconnect was intentional and skips its auto-reconnect.
//
// Race risk: the cast socket might tear down before this message
// makes it through. In that case the sender's _handleDisconnect
// fires first and auto-reconnect runs anyway (the user has to dismiss
// the relaunch — annoying but not the "kill twice" failure mode).
// In practice CAF's SHUTDOWN fires early enough that the message
// usually lands.
//
// Belt-and-braces: also listen for beforeunload / pagehide. Some
// receiver tear-downs (webOS lifecycle hooks, OOM kills) skip
// SHUTDOWN entirely, but the browser still fires unload-class events
// before the JS context dies. Sending the same payload twice is
// harmless — the sender uses the FIRST DIAG_RECEIVER_SHUTDOWN it
// sees within the grace window.
let _shutdownSignalSent = false;
function _sendShutdownSignal(reason) {
  if (_shutdownSignalSent) return;
  _shutdownSignalSent = true;
  try {
    sendDiagToSender({
      type: 'DIAG_RECEIVER_SHUTDOWN',
      reason: reason,
      version: NASRADIO_RECEIVER_VERSION,
    });
  } catch (e) {
    console.warn('[NASRadio] Failed to send shutdown signal:', e);
  }
}

context.addEventListener(
  cast.framework.system.EventType.SHUTDOWN,
  (event) => {
    console.log('[NASRadio] CAF SHUTDOWN event fired:', event);
    _sendShutdownSignal('caf_shutdown');
  },
);

window.addEventListener('beforeunload', () => {
  _sendShutdownSignal('beforeunload');
});

window.addEventListener('pagehide', () => {
  _sendShutdownSignal('pagehide');
});

// Player state is polled by the watchdog setInterval above —
// `cast.framework.events.EventType.PLAYER_STATE_CHANGED` doesn't exist
// in CAF SDK v3, so we can't use it as an event source. Polling every
// 1s from the existing watchdog is good enough resolution for the HUD.

// ─── DOM Elements ──────────────────────────────────────────────────

// Now Playing view
const bgImage = document.getElementById('bg-image');
const artwork = document.getElementById('artwork');
// Extra canvas on each side of the waveform so the playhead glow (25px
// radial + 8px shadow) has room to fade instead of slicing off flat at the
// bar ends. The bars themselves still draw in exactly the old span; the
// canvas is just wider and shifted left by the same amount.
const WAVE_PAD = 28;
const titleEl = document.getElementById('title');
const artistEl = document.getElementById('artist');
const albumEl = document.getElementById('album');
const contentEl = document.getElementById('content');
const idleScreen = document.getElementById('idle-screen');
const formatBadge = document.getElementById('format-badge');
const ddplusBadge = document.getElementById('ddplus-badge');
const atmosBadge = document.getElementById('atmos-badge');
const surroundBadge = document.getElementById('surround-badge');
const hdcdBadge = document.getElementById('hdcd-badge');
const explicitBadge = document.getElementById('explicit-badge');

// Lyrics view
const lyricsView = document.getElementById('lyrics-view');
const lyricsContainer = document.getElementById('lyrics-container');
const lyricsArtworkSmall = document.getElementById('lyrics-artwork-small');
const lyricsTitleEl = document.getElementById('lyrics-title');
const lyricsArtistEl = document.getElementById('lyrics-artist');

// Black screen
const blackScreen = document.getElementById('black-screen');

// Party overlay (QR + code, top-left)
const partyOverlay = document.getElementById('party-overlay');
const partyQrImg = document.getElementById('party-qr');
const partyCodeEl = document.getElementById('party-code');

// Bottom-right cards: Up Next countdown (desktop-fullscreen port) +
// queue-add toast ("5150 added to the queue by Claude")
const upnextCard = document.getElementById('upnext-card');
const upnextArt = document.getElementById('upnext-art');
const upnextTitle = document.getElementById('upnext-title');
const upnextArtist = document.getElementById('upnext-artist');
const upnextRing = document.getElementById('upnext-ring');
const upnextSecs = document.getElementById('upnext-secs');
const queueToast = document.getElementById('queue-toast');
const queueToastArt = document.getElementById('queue-toast-art');
const queueToastTitle = document.getElementById('queue-toast-title');
const queueToastLabel = document.getElementById('queue-toast-label');
const queueToastArtist = document.getElementById('queue-toast-artist');
const queueToastByPre = document.getElementById('queue-toast-by-pre');
const queueToastBy = document.getElementById('queue-toast-by');
const queueToastBgImg = document.getElementById('queue-toast-bgimg');
let _queueToastTimer = null;
let _upnextShownFor = null;   // contentId the card is currently populated with

// Sleep timer
const sleepTimerEl = document.getElementById('sleep-timer');
const sleepCountdownEl = document.getElementById('sleep-countdown');

// Clock
const clockEl = document.getElementById('clock');
function updateClock() {
  if (!clockEl) return;
  const now = new Date();
  let h = now.getHours();
  const ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  const m = now.getMinutes().toString().padStart(2, '0');
  clockEl.textContent = `${h}:${m} ${ampm}`;
}
updateClock();
setInterval(updateClock, 10000);

// Waveform
const waveformCanvas = document.getElementById('waveform-canvas');
const waveformCtx = waveformCanvas.getContext('2d');
const currentTimeEl = document.getElementById('current-time');
const totalTimeEl = document.getElementById('total-time');
const livePill = document.getElementById('live-pill');

// ─── Live-stream mode ───────────────────────────────────────────────
// Radio stations cast with streamType=LIVE: duration is Infinity, so a
// scrubber is meaningless and formatTime(Infinity) renders the infamous
// "Infinity:NaN:NaN". Live mode hides the waveform + total time and
// shows a pulsing LIVE pill; elapsed listen time stays.
let liveMode = false;

function setLiveMode(on) {
  if (on === liveMode) return;
  liveMode = on;
  document.body.classList.toggle('live-mode', on);
  livePill.classList.toggle('hidden', !on);
  totalTimeEl.classList.toggle('hidden', on);
  console.log('[NASRadio] Live mode:', on);
}

// ─── State ─────────────────────────────────────────────────────────

let currentArtworkUrl = '';
// Background image (artist photo) URL guard. updateMediaInfo() runs
// on every MEDIA_STATUS event — which CAF fires multiple times per
// second during state changes, buffering, seeks, song loads, etc.
// Without this guard, every event allocates a fresh `new Image()`
// for the same artist URL, accumulates onload/onerror closures in
// memory, and on the resource-constrained webOS the GC pauses long
// enough to block the JS event loop (which means PING/PONG can't
// flow on the cast heartbeat namespace → cast device RSTs the
// socket after enough missed PONGs). Symptom: drop right after the
// second song LOAD, "Connection reset by peer" from cast device's
// LAN IP, music keeps playing on TV (native audio decoder thread
// is fine). Same guard pattern as currentArtworkUrl.
let currentBgImageUrl = '';
// Last NOW_PLAYING push from the sender (live stations). The sender's
// push can RACE the LOAD: tune to a station mid-cast and the track
// arrives while the stream is still loading — then the post-LOAD
// MEDIA_STATUS repaint (updateMediaInfo) overwrote it with the static
// station name, and the sender won't re-push until the broadcast
// rotates. Stash every push and re-apply it during LIVE repaints.
// Cleared by the LOAD interceptor so a new station never inherits the
// previous station's track.
let _pendingStationTrack = null;
// Sender-provided "up next" list (next ~10 queue items, each a complete
// {contentId, contentType, metadata, customData}). Normally the sender
// drives every song change with a fresh LOAD — but if the phone is
// swiped away, Dozed, or off the LAN when a song ends, nobody sends
// that LOAD and playback just stops. With this list the receiver waits
// a grace period after MEDIA_FINISHED and, if no LOAD showed up, loads
// the next item ITSELF. The sender re-syncs to wherever we got to when
// it comes back (customData.songId rides every item for that).
let _upNext = [];
let _selfAdvanceTimer = null;
const SELF_ADVANCE_GRACE_MS = 4000;
// Headless (backend) casts have no phone racing to LOAD the next track —
// waiting the full grace is 4s of dead air between every song. The
// backend tags its LOADs with customData.headlessSender.
const HEADLESS_ADVANCE_GRACE_MS = 250;
let _isHeadlessCast = false;

// ── Segue crossfade (Stage 1: volume ramp, no overlap) ──────────────
// Fade the outgoing track's volume over its last `crossfadeSec`
// seconds and ramp the incoming track up over the first half of that.
// Position-derived every rAF tick, so seeks/pauses self-correct.
// 0 disables. Set via CROSSFADE message; persisted across launches.
const castAudioEl = document.getElementById('castMediaElement');
let crossfadeSec = (() => {
  const v = parseFloat(localStorage.getItem('nasradio_crossfade'));
  return isFinite(v) ? Math.max(0, Math.min(v, 12)) : 4;
})();

function applySegueVolume(t, d) {
  if (!crossfadeSec || liveMode || !isFinite(d) || d <= 0) {
    if (castAudioEl.volume !== 1) castAudioEl.volume = 1;
    return;
  }
  const fadeIn = crossfadeSec / 2;
  let v = 1;
  if (t < fadeIn) v = Math.min(1, t / fadeIn);
  const remaining = d - t;
  if (remaining < crossfadeSec) {
    v = Math.min(v, Math.max(0, remaining / crossfadeSec));
  }
  // Equal-power curve — linear ramps sound like they duck too early
  castAudioEl.volume = Math.sin(v * Math.PI / 2);
}

function _cancelSelfAdvance() {
  if (_selfAdvanceTimer) {
    clearTimeout(_selfAdvanceTimer);
    _selfAdvanceTimer = null;
  }
}

function _scheduleSelfAdvance() {
  _cancelSelfAdvance();
  if (_upNext.length === 0) return;
  _selfAdvanceTimer = setTimeout(() => {
    _selfAdvanceTimer = null;
    // Only take over if nothing else did: a live sender's LOAD (or a
    // user STOP) moves the player out of IDLE and/or cancels this timer.
    const state = playerManager.getPlayerState();
    if (state !== cast.framework.messages.PlayerState.IDLE) {
      console.log('[NASRadio] Self-advance skipped — player is', state);
      return;
    }
    const item = _upNext.shift();
    if (!item || !item.contentId) return;
    try {
      const li = new cast.framework.messages.LoadRequestData();
      li.media = new cast.framework.messages.MediaInformation();
      li.media.contentId = item.contentId;
      li.media.contentType = item.contentType || 'audio/flac';
      li.media.streamType = cast.framework.messages.StreamType.BUFFERED;
      li.media.metadata = item.metadata || {};
      li.media.customData = item.customData || {};
      li.autoplay = true;
      console.log('[NASRadio] Self-advancing to', item.contentId);
      sendDiagToSender({
        type: 'DIAG_SELF_ADVANCE',
        songId: item.customData ? item.customData.songId : null,
        remaining: _upNext.length,
      });
      playerManager.load(li).catch((e) => {
        console.log('[NASRadio] Self-advance load failed:', e);
      });
    } catch (e) {
      console.log('[NASRadio] Self-advance error:', e);
    }
  }, _isHeadlessCast ? HEADLESS_ADVANCE_GRACE_MS : SELF_ADVANCE_GRACE_MS);
}
let progressInterval = null;
let waveformData = null;       // Array of 0.0-1.0 floats
// Song id of the currently loaded media, pulled from the LOAD's
// customData.songId. Used to make WAVEFORM_REQUEST messages
// addressable so the sender can answer with the right waveform when
// the deferred-send race drops the original send.
let currentSongId = null;
// Throttle waveform re-request retries — at most one in flight per
// song, retried at increasing intervals until either the waveform
// arrives or the song changes.
let _waveformRequestTimer = null;
let _waveformRequestAttempts = 0;
let lyricsLines = null;        // Array of {time: seconds, text: string}
let currentLyricIndex = -1;
let lyricsVisible = false;     // Toggled from phone — NOT auto-shown
let sleepTimerInterval = null;
let sleepTimerRemaining = 0;
let specialWaveform = null;   // 'evh', 'dna', 'lightsaber:blue', etc.
let animFrame = 0;            // Time-based animation (seconds from performance.now())

/**
 * Format seconds to M:SS or H:MM:SS
 */
function formatTime(seconds) {
  if (!seconds || seconds < 0) return '0:00';
  seconds = Math.floor(seconds);
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) {
    return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  }
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/**
 * Update the UI with current media metadata
 */
function updateMediaInfo(mediaInfo) {
  if (!mediaInfo) return;
  _diag.M++;

  const metadata = mediaInfo.metadata || {};
  const customData = mediaInfo.customData || {};
  // Live-track override — see _pendingStationTrack above.
  const stash =
    mediaInfo.streamType === 'LIVE' ? _pendingStationTrack : null;
  const title = (stash && stash.title) ||
    metadata.title || metadata.songName || 'Unknown Title';
  const artist = (stash && stash.artist) ||
    metadata.artist || metadata.albumArtist || 'Unknown Artist';
  const album = stash ? '' : (metadata.albumName || '');

  // Now Playing view
  setScrollingText(titleEl, title);
  titleEl.className = 'fade-in';
  setScrollingText(artistEl, artist);
  artistEl.className = 'fade-in';
  setScrollingText(albumEl, album);
  albumEl.className = 'fade-in';

  // Lyrics view header
  setScrollingText(lyricsTitleEl, title);
  setScrollingText(lyricsArtistEl, artist);

  // Update artwork (center image is always album art). For live stations
  // a stashed per-track artwork beats the static station favicon — same
  // race as the title above.
  const images = metadata.images || [];
  const stashArt = stash && stash.artwork ? stash.artwork : null;
  if (stashArt || images.length > 0) {
    const artUrl = stashArt || images[0].url;
    if (artUrl !== currentArtworkUrl) {
      currentArtworkUrl = artUrl;
      // NO crossOrigin on these preloads. crossOrigin='anonymous' makes
      // the load REQUIRE an Access-Control-Allow-Origin header — our
      // backend sends one (flask-cors) so album art worked, but external
      // station artwork (nightride.fm, somafm.com) doesn't → onerror →
      // station image never appeared. We never read these pixels back
      // (the canvas is waveform-only), so CORS mode buys nothing.
      const img = new Image();
      img.onload = function () {
        artwork.src = artUrl;
        artwork.classList.add('loaded');
        lyricsArtworkSmall.src = artUrl;
        // Set album art as background fallback (overridden below if artist image exists)
        if (!customData.artistImageUrl) {
          bgImage.style.backgroundImage = `url(${artUrl})`;
        }
      };
      img.onerror = function () {
        console.warn('[NASRadio] Failed to load artwork:', artUrl);
      };
      img.src = artUrl;
    }
  }

  // Special waveform mode
  specialWaveform = customData.specialWaveform || null;

  // Track current song id and reset retry state if we just transitioned
  // to a different song. New song → waveform should be null and the
  // sender is expected to send a fresh one shortly. If it doesn't,
  // _ensureWaveform() (called from PLAYER_LOAD_COMPLETE) will ask.
  // Headless-backend cast? Unlocks the fast self-advance grace.
  _isHeadlessCast = !!customData.headlessSender;

  const newSongId = (typeof customData.songId === 'number')
    ? customData.songId
    : null;
  if (newSongId !== null && newSongId !== currentSongId) {
    currentSongId = newSongId;
    _waveformRequestAttempts = 0;
    if (_waveformRequestTimer) {
      clearTimeout(_waveformRequestTimer);
      _waveformRequestTimer = null;
    }
  }

  // Badges from customData (primary source — no separate message needed)
  if (customData.fileFormat) {
    updateBadges({
      format: customData.fileFormat,
      isHdcd: customData.isHdcd || false,
      isExplicit: customData.isExplicit || false,
      isAtmos: customData.isAtmos || false,
      audioChannels: customData.audioChannels || 2,
    });
  }

  // Faded background: prefer artist image, fallback to album art.
  // GUARDED: only allocate a new Image() when the URL actually
  // changed. MEDIA_STATUS fires many times per song so the
  // unguarded version (pre-v19) leaked an Image+closures on every
  // event — see currentBgImageUrl declaration above for the full
  // story of why this is critical on webOS.
  const artistImgUrl = customData.artistImageUrl;
  if (artistImgUrl && artistImgUrl !== currentBgImageUrl) {
    currentBgImageUrl = artistImgUrl;
    const artistImg = new Image();
    // No crossOrigin — see the album-art loader above.
    artistImg.onload = function () {
      // Late-arriving onload from a previous LOAD whose URL has
      // since been superseded — don't overwrite the current bg.
      if (artistImgUrl !== currentBgImageUrl) return;
      bgImage.style.backgroundImage = `url(${artistImgUrl})`;
      console.log('[NASRadio] Background: artist image');
    };
    artistImg.onerror = function () {
      // Artist image not available — use album art (already set or will be set above)
      if (artistImgUrl !== currentBgImageUrl) return;
      if (currentArtworkUrl) {
        bgImage.style.backgroundImage = `url(${currentArtworkUrl})`;
      }
      console.log('[NASRadio] Background: album art (artist image not found)');
    };
    artistImg.src = artistImgUrl;
  }

  // Show content, hide idle
  contentEl.classList.add('visible');
  idleScreen.classList.add('hidden');

  // Live stream (radio station)? Sender sets streamType=LIVE explicitly.
  setLiveMode(mediaInfo.streamType === 'LIVE');

  if (mediaInfo.duration && isFinite(mediaInfo.duration)) {
    totalTimeEl.textContent = formatTime(mediaInfo.duration);
  }
}

// ─── Badge Rendering ───────────────────────────────────────────────

function updateBadges(data) {
  // Format badge (FLAC, MP3, etc.) with format-specific colors.
  // DD+ streams get the official wordmark badge instead of a text pill.
  if (data.format === 'DD+') {
    formatBadge.className = 'badge hidden';
    ddplusBadge.classList.remove('hidden');
  } else if (data.format) {
    ddplusBadge.classList.add('hidden');
    formatBadge.textContent = data.format;
    // Remove all format color classes
    formatBadge.className = 'badge';
    // Add format-specific color class
    const fmt = data.format.toLowerCase().replace(/\s+/g, '');
    formatBadge.classList.add('fmt-' + fmt);
  } else {
    formatBadge.className = 'badge hidden';
    ddplusBadge.classList.add('hidden');
  }

  // Atmos badge (object audio) / Surround badge (plain multichannel).
  // Mutually exclusive: Atmos implies multichannel, so the channel-count
  // pill would be redundant next to the Dolby one.
  if (data.isAtmos) {
    atmosBadge.classList.remove('hidden');
    surroundBadge.classList.add('hidden');
  } else if ((data.audioChannels || 2) > 2) {
    const ch = data.audioChannels;
    // 6 → "5.1", 8 → "7.1", 5 → "5.0" (LFE counts as the .1)
    surroundBadge.textContent =
      ch === 6 ? '5.1' : ch === 8 ? '7.1' : ch === 7 ? '6.1' : (ch - 0) + '.0';
    surroundBadge.classList.remove('hidden');
    atmosBadge.classList.add('hidden');
  } else {
    atmosBadge.classList.add('hidden');
    ddplusBadge.classList.add('hidden');
    surroundBadge.classList.add('hidden');
  }

  // HDCD badge
  if (data.isHdcd) {
    hdcdBadge.classList.remove('hidden');
  } else {
    hdcdBadge.classList.add('hidden');
  }

  // Explicit badge
  if (data.isExplicit) {
    explicitBadge.classList.remove('hidden');
  } else {
    explicitBadge.classList.add('hidden');
  }
}

// ─── Waveform Rendering ────────────────────────────────────────────

/**
 * Set up waveform canvas size (call on load and resize)
 */
function setupWaveformCanvas() {
  const dpr = window.devicePixelRatio || 1;
  const container = waveformCanvas.parentElement;
  // Account for the 60px padding on each side from the container, then
  // add WAVE_PAD on each side for the glow (see WAVE_PAD).
  const w = container.clientWidth - 120 + 2 * WAVE_PAD;
  const h = 36;
  waveformCanvas.width = w * dpr;
  waveformCanvas.height = h * dpr;
  waveformCanvas.style.width = w + 'px';
  waveformCanvas.style.height = h + 'px';
  waveformCanvas.style.marginLeft = (-WAVE_PAD) + 'px';
}

/**
 * Draw the waveform with played/unplayed colors
 */
function drawWaveform(progress) {
  const fullW = waveformCanvas.clientWidth;
  const w = fullW - 2 * WAVE_PAD;      // the bar span; glow spills into the pad
  const h = waveformCanvas.clientHeight;
  const dpr = window.devicePixelRatio || 1;

  waveformCtx.setTransform(1, 0, 0, 1, 0, 0);
  waveformCtx.scale(dpr, dpr);
  waveformCtx.clearRect(0, 0, fullW, h);
  waveformCtx.translate(WAVE_PAD, 0);
  animFrame = performance.now() / 1000;

  // Route to special waveform renderers
  if (specialWaveform && waveformData && waveformData.length > 0) {
    if (specialWaveform === 'evh') {
      drawEVHWaveform(progress, w, h);
      return;
    } else if (specialWaveform === 'dna') {
      drawDNAWaveform(progress, w, h);
      return;
    } else if (specialWaveform.startsWith('lightsaber:')) {
      drawLightsaberWaveform(progress, w, h);
      return;
    }
  }

  if (!waveformData || waveformData.length === 0) {
    // Fallback: simple progress line
    waveformCtx.fillStyle = 'rgba(255, 255, 255, 0.15)';
    waveformCtx.fillRect(0, h / 2 - 2, w, 4);
    waveformCtx.fillStyle = '#00d4ff';
    waveformCtx.fillRect(0, h / 2 - 2, w * progress, 4);
    return;
  }

  const barCount = waveformData.length;
  const barWidth = w / barCount;
  const centerY = h / 2;
  const maxBarHeight = h * 0.9;

  // Continuous fill edge in pixels (not bar count). The played /
  // unplayed colour boundary follows this `cursorX` exactly — so for
  // the one bar that straddles it, we split-fill: left part in the
  // played colour, right part in the unplayed colour. As `cursorX`
  // glides smoothly between bar centres at RAF rate, the split shifts
  // left→right inside that bar and the fill visually flows through
  // the waveform with no quantization step.
  const cursorX = progress * w;
  const PLAYED = '#00d4ff';
  const UNPLAYED = 'rgba(255, 255, 255, 0.2)';

  for (let i = 0; i < barCount; i++) {
    const amplitude = waveformData[i];
    const barH = Math.max(2, amplitude * maxBarHeight);
    const x = i * barWidth;
    const y = centerY - barH / 2;
    const gap = barWidth > 3 ? 1 : 0;
    const drawW = Math.max(1, barWidth - gap);

    if (x + drawW <= cursorX) {
      // Fully played
      waveformCtx.fillStyle = PLAYED;
      waveformCtx.fillRect(x, y, drawW, barH);
    } else if (x >= cursorX) {
      // Fully unplayed
      waveformCtx.fillStyle = UNPLAYED;
      waveformCtx.fillRect(x, y, drawW, barH);
    } else {
      // Boundary bar — split fill at cursorX.
      const playedW = cursorX - x;
      waveformCtx.fillStyle = PLAYED;
      waveformCtx.fillRect(x, y, playedW, barH);
      waveformCtx.fillStyle = UNPLAYED;
      waveformCtx.fillRect(cursorX, y, drawW - playedW, barH);
    }
  }

  // Fizzling spark at the continuous fill edge. The glow breathes and
  // throws a handful of short-lived sparks that drift up and fade — the
  // same feel as the special skins' animated playheads, on every track.
  // Everything is a pure function of animFrame (seconds), so there is no
  // particle state to keep and a missed frame costs nothing.
  if (cursorX > 0 && cursorX < w) {
    const t = animFrame;
    const flicker = 0.75 + 0.25 * Math.sin(t * 9.7) * Math.sin(t * 3.1 + 1.3);
    const r = 18 + 6 * flicker;
    const gradient = waveformCtx.createRadialGradient(cursorX, centerY, 0, cursorX, centerY, r);
    gradient.addColorStop(0, `rgba(0, 212, 255, ${(0.22 + 0.2 * flicker).toFixed(3)})`);
    gradient.addColorStop(0.5, `rgba(0, 212, 255, ${(0.10 * flicker).toFixed(3)})`);
    gradient.addColorStop(1, 'rgba(0, 212, 255, 0)');
    waveformCtx.fillStyle = gradient;
    waveformCtx.fillRect(cursorX - r, 0, r * 2, h);

    // Sparks: each has its own cycle speed; `life` runs 0→1 then the
    // spark is reborn at a new angle (the integer cycle count seeds it).
    const SPARKS = 7;
    for (let i = 0; i < SPARKS; i++) {
      const speed = 0.9 + i * 0.13;
      const phase = t * speed + i * 0.37;
      const life = phase - Math.floor(phase);
      const ang = i * 2.399 + Math.floor(phase) * 1.7;
      const dist = 3 + life * 16;
      const sx = cursorX + Math.cos(ang) * dist * 0.6;
      const sy = centerY + Math.sin(ang) * dist - life * 8;
      const a = (1 - life) * 0.9;
      waveformCtx.fillStyle = `rgba(180, 240, 255, ${a.toFixed(3)})`;
      waveformCtx.fillRect(sx, sy, 1.5, 1.5);
    }
  }
}

/**
 * Van Halen EVH Frankenstein Stripes waveform
 * Red base with chaotic diagonal black & white stripes, clipped to waveform shape
 */
function drawEVHWaveform(progress, w, h) {
  const barCount = waveformData.length;
  const centerY = h / 2;
  const maxAmplitude = h / 2;

  // Build waveform path (smooth filled shape)
  waveformCtx.beginPath();
  waveformCtx.moveTo(0, centerY);
  for (let i = 0; i < barCount; i++) {
    const x = (i / barCount) * w;
    const amp = waveformData[i] * maxAmplitude * 0.9;
    waveformCtx.lineTo(x, centerY - amp);
  }
  for (let i = barCount - 1; i >= 0; i--) {
    const x = (i / barCount) * w;
    const amp = waveformData[i] * maxAmplitude * 0.9;
    waveformCtx.lineTo(x, centerY + amp);
  }
  waveformCtx.closePath();

  // Draw unplayed portion (dark blue-gray)
  waveformCtx.save();
  waveformCtx.clip();
  waveformCtx.fillStyle = '#2a3f5f';
  waveformCtx.fillRect(w * progress, 0, w, h);
  waveformCtx.restore();

  // Draw played portion with Frankenstein pattern
  waveformCtx.save();

  // Re-create path for clipping
  waveformCtx.beginPath();
  waveformCtx.moveTo(0, centerY);
  for (let i = 0; i < barCount; i++) {
    const x = (i / barCount) * w;
    const amp = waveformData[i] * maxAmplitude * 0.9;
    waveformCtx.lineTo(x, centerY - amp);
  }
  for (let i = barCount - 1; i >= 0; i--) {
    const x = (i / barCount) * w;
    const amp = waveformData[i] * maxAmplitude * 0.9;
    waveformCtx.lineTo(x, centerY + amp);
  }
  waveformCtx.closePath();
  waveformCtx.clip();

  // Clip to played region
  waveformCtx.beginPath();
  waveformCtx.rect(0, 0, w * progress, h);
  waveformCtx.clip();

  // Red base
  waveformCtx.fillStyle = '#E31937';
  waveformCtx.fillRect(0, 0, w, h);

  // Chaotic diagonal stripes (Frankenstein pattern)
  const stripes = [
    // Black stripes - wider, various angles
    { color: '#000000', x: -20, angle: 0.4, sw: 18 },
    { color: '#000000', x: 60, angle: -0.6, sw: 22 },
    { color: '#000000', x: 150, angle: 0.3, sw: 16 },
    { color: '#000000', x: 240, angle: -0.5, sw: 20 },
    { color: '#000000', x: 350, angle: 0.7, sw: 18 },
    { color: '#000000', x: 450, angle: -0.4, sw: 24 },
    { color: '#000000', x: 550, angle: 0.5, sw: 16 },
    { color: '#000000', x: 650, angle: -0.3, sw: 20 },
    { color: '#000000', x: 750, angle: 0.6, sw: 18 },
    { color: '#000000', x: 850, angle: -0.5, sw: 22 },
    { color: '#000000', x: 950, angle: 0.4, sw: 16 },
    { color: '#000000', x: 1050, angle: -0.6, sw: 20 },
    { color: '#000000', x: 1150, angle: 0.3, sw: 18 },
    { color: '#000000', x: 1250, angle: -0.4, sw: 22 },
    // White stripes - thinner
    { color: '#FFFFFF', x: 20, angle: -0.5, sw: 10 },
    { color: '#FFFFFF', x: 100, angle: 0.6, sw: 8 },
    { color: '#FFFFFF', x: 200, angle: -0.4, sw: 12 },
    { color: '#FFFFFF', x: 300, angle: 0.5, sw: 10 },
    { color: '#FFFFFF', x: 400, angle: -0.7, sw: 8 },
    { color: '#FFFFFF', x: 500, angle: 0.4, sw: 12 },
    { color: '#FFFFFF', x: 600, angle: -0.6, sw: 10 },
    { color: '#FFFFFF', x: 700, angle: 0.3, sw: 8 },
    { color: '#FFFFFF', x: 800, angle: -0.5, sw: 10 },
    { color: '#FFFFFF', x: 900, angle: 0.6, sw: 12 },
    { color: '#FFFFFF', x: 1000, angle: -0.4, sw: 8 },
    { color: '#FFFFFF', x: 1100, angle: 0.5, sw: 10 },
    { color: '#FFFFFF', x: 1200, angle: -0.3, sw: 12 },
  ];

  for (const s of stripes) {
    waveformCtx.save();
    waveformCtx.translate(s.x, centerY);
    waveformCtx.rotate(s.angle);
    waveformCtx.fillStyle = s.color;
    waveformCtx.fillRect(-s.sw / 2, -h * 1.5, s.sw, h * 3);
    waveformCtx.restore();
  }

  waveformCtx.restore();

  // Red glow on playhead
  const playX = w * progress;
  if (playX > 0 && playX < w) {
    const gradient = waveformCtx.createRadialGradient(playX, centerY, 0, playX, centerY, 20);
    gradient.addColorStop(0, 'rgba(227, 25, 55, 0.5)');
    gradient.addColorStop(1, 'rgba(227, 25, 55, 0)');
    waveformCtx.fillStyle = gradient;
    waveformCtx.fillRect(playX - 20, 0, 40, h);
  }
}

/**
 * Jurassic Park DNA waveform — double helix style
 */
function drawDNAWaveform(progress, w, h) {
  const barCount = waveformData.length;
  const barWidth = w / barCount;
  const playedBars = Math.floor(progress * barCount);
  const centerY = h / 2;
  const helixAmplitude = h * 0.45;
  const barH = h * 0.16;  // Constant strand thickness
  const frequency = 0.08;

  // Draw connecting rungs first (behind the strands) — yellow base pairs
  waveformCtx.lineWidth = 3;
  for (let i = 0; i < barCount; i += 5) {
    const x = i * barWidth + barWidth / 2;
    const phase = i * frequency + animFrame * 0.6;
    const y1 = centerY + Math.sin(phase) * helixAmplitude * 0.6;
    const y2 = centerY - Math.sin(phase) * helixAmplitude * 0.6;
    if (i < playedBars) {
      waveformCtx.shadowColor = '#ffd000';
      waveformCtx.shadowBlur = 8;
      waveformCtx.strokeStyle = 'rgba(255, 208, 0, 0.7)';
    } else {
      waveformCtx.shadowBlur = 0;
      waveformCtx.strokeStyle = 'rgba(255, 208, 0, 0.12)';
    }
    waveformCtx.beginPath();
    waveformCtx.moveTo(x, y1);
    waveformCtx.lineTo(x, y2);
    waveformCtx.stroke();
  }
  waveformCtx.shadowBlur = 0;

  // Draw strands with constant-height bars
  for (let i = 0; i < barCount; i++) {
    const x = i * barWidth;
    const phase = i * frequency + animFrame * 0.6;
    const gap = barWidth > 3 ? 1 : 0;
    const bw = Math.max(2, barWidth - gap);

    // Strand 1 (top helix) — blue #00a8ff
    const y1 = centerY + Math.sin(phase) * helixAmplitude * 0.6 - barH / 2;
    if (i < playedBars) {
      waveformCtx.shadowColor = '#00a8ff';
      waveformCtx.shadowBlur = 6;
      waveformCtx.fillStyle = '#00a8ff';
    } else {
      waveformCtx.shadowBlur = 0;
      waveformCtx.fillStyle = 'rgba(0, 168, 255, 0.2)';
    }
    waveformCtx.fillRect(x, y1, bw, barH);

    // Strand 2 (bottom helix) — purple #a855f7
    const y2 = centerY - Math.sin(phase) * helixAmplitude * 0.6 - barH / 2;
    if (i < playedBars) {
      waveformCtx.shadowColor = '#a855f7';
      waveformCtx.shadowBlur = 6;
      waveformCtx.fillStyle = '#a855f7';
    } else {
      waveformCtx.shadowBlur = 0;
      waveformCtx.fillStyle = 'rgba(168, 85, 247, 0.2)';
    }
    waveformCtx.fillRect(x, y2, bw, barH);
  }
  waveformCtx.shadowBlur = 0;

  // Purple/blue glow on playhead
  if (playedBars > 0 && playedBars < barCount) {
    const glowX = playedBars * barWidth;
    const gradient = waveformCtx.createRadialGradient(glowX, centerY, 0, glowX, centerY, 25);
    gradient.addColorStop(0, 'rgba(0, 168, 255, 0.5)');
    gradient.addColorStop(0.5, 'rgba(168, 85, 247, 0.3)');
    gradient.addColorStop(1, 'rgba(168, 85, 247, 0)');
    waveformCtx.fillStyle = gradient;
    waveformCtx.fillRect(glowX - 25, 0, 50, h);
  }
}

/**
 * Star Wars lightsaber waveform — blade with hilt
 * Recovered version with metallic grip, ambient glow, layered blade
 */
function drawLightsaberWaveform(progress, w, h) {
  const barCount = waveformData.length;
  const centerY = h / 2;
  const maxAmplitude = h / 2;

  // Parse color from specialWaveform string
  const colorName = specialWaveform.split(':')[1] || 'blue';
  const colors = {
    blue:   { main: '#4488ff', core: '#ccdeff', r: 68,  g: 136, b: 255 },
    red:    { main: '#ff4444', core: '#ffcccc', r: 255, g: 68,  b: 68  },
    green:  { main: '#44ff44', core: '#ccffcc', r: 68,  g: 255, b: 68  },
    purple: { main: '#aa44ff', core: '#eeccff', r: 170, g: 68,  b: 255 },
  };
  const c = colors[colorName] || colors.blue;

  // Pulsing intensity (800ms cycle like Flutter)
  const pulse = 0.7 + 0.3 * Math.sin(animFrame * 2.4);

  // ─── HILT ───
  const hiltWidth = Math.max(80, w * 0.08);
  const hiltHeight = h * 0.65;
  const hiltX = 0;
  const hiltY = centerY - hiltHeight / 2;

  // Pommel (rounded end cap)
  const pommelW = 8;
  waveformCtx.fillStyle = '#666666';
  waveformCtx.beginPath();
  waveformCtx.roundRect(hiltX, hiltY + 4, pommelW, hiltHeight - 8, [4, 0, 0, 4]);
  waveformCtx.fill();
  // Pommel highlight
  waveformCtx.fillStyle = 'rgba(255,255,255,0.15)';
  waveformCtx.fillRect(hiltX + 2, hiltY + 6, 3, hiltHeight * 0.4);

  // Grip section
  const gripX = hiltX + pommelW;
  const gripW = hiltWidth * 0.5;
  const gripGrad = waveformCtx.createLinearGradient(gripX, hiltY, gripX, hiltY + hiltHeight);
  gripGrad.addColorStop(0, '#555555');
  gripGrad.addColorStop(0.3, '#999999');
  gripGrad.addColorStop(0.5, '#bbbbbb');
  gripGrad.addColorStop(0.7, '#999999');
  gripGrad.addColorStop(1, '#555555');
  waveformCtx.fillStyle = gripGrad;
  waveformCtx.fillRect(gripX, hiltY, gripW, hiltHeight);
  // Grip ridges
  for (let r = 0; r < 5; r++) {
    const ry = hiltY + hiltHeight * 0.15 + r * (hiltHeight * 0.7 / 5);
    waveformCtx.fillStyle = 'rgba(0,0,0,0.25)';
    waveformCtx.fillRect(gripX, ry, gripW, 2);
  }

  // Activation box
  const actX = gripX + gripW;
  const actW = hiltWidth * 0.2;
  waveformCtx.fillStyle = '#888888';
  waveformCtx.fillRect(actX, hiltY - 2, actW, hiltHeight + 4);
  // Power button glow
  const btnY = centerY;
  const btnR = 4;
  waveformCtx.beginPath();
  waveformCtx.arc(actX + actW / 2, btnY, btnR, 0, Math.PI * 2);
  waveformCtx.fillStyle = c.main;
  waveformCtx.shadowColor = c.main;
  waveformCtx.shadowBlur = 8 * pulse;
  waveformCtx.fill();
  waveformCtx.shadowBlur = 0;

  // Emitter shroud
  const emitX = actX + actW;
  const emitW = hiltWidth - pommelW - gripW - actW;
  const emitGrad = waveformCtx.createLinearGradient(emitX, hiltY, emitX, hiltY + hiltHeight);
  emitGrad.addColorStop(0, '#aaaaaa');
  emitGrad.addColorStop(0.5, '#dddddd');
  emitGrad.addColorStop(1, '#aaaaaa');
  waveformCtx.fillStyle = emitGrad;
  waveformCtx.fillRect(emitX, hiltY + 2, emitW, hiltHeight - 4);
  // Emitter glow (colored light from blade)
  waveformCtx.fillStyle = `rgba(${c.r}, ${c.g}, ${c.b}, ${0.3 * pulse})`;
  waveformCtx.fillRect(emitX, hiltY + 2, emitW, hiltHeight - 4);

  // ─── BLADE ───
  const bladeStartX = hiltWidth;
  const bladeWidth = w - hiltWidth;
  const progressX = bladeStartX + bladeWidth * progress;

  // Build smooth waveform path for blade
  const buildBladePath = () => {
    waveformCtx.beginPath();
    waveformCtx.moveTo(bladeStartX, centerY);
    for (let i = 0; i < barCount; i++) {
      const x = bladeStartX + (i / barCount) * bladeWidth;
      const amp = waveformData[i] * maxAmplitude * 0.85;
      waveformCtx.lineTo(x, centerY - amp);
    }
    for (let i = barCount - 1; i >= 0; i--) {
      const x = bladeStartX + (i / barCount) * bladeWidth;
      const amp = waveformData[i] * maxAmplitude * 0.85;
      waveformCtx.lineTo(x, centerY + amp);
    }
    waveformCtx.closePath();
  };

  // Unplayed portion (dark)
  waveformCtx.save();
  buildBladePath();
  waveformCtx.clip();
  waveformCtx.fillStyle = '#223344';
  waveformCtx.fillRect(progressX, 0, w, h);
  waveformCtx.restore();

  // Ambient glow behind blade (wide, soft)
  waveformCtx.save();
  waveformCtx.globalAlpha = 0.15 * pulse;
  waveformCtx.shadowColor = c.main;
  waveformCtx.shadowBlur = 30;
  waveformCtx.fillStyle = c.main;
  waveformCtx.fillRect(bladeStartX, centerY - h * 0.25, Math.max(0, progressX - bladeStartX), h * 0.5);
  waveformCtx.restore();

  // Outer glow layer (widest, most transparent)
  waveformCtx.save();
  buildBladePath();
  waveformCtx.clip();
  waveformCtx.beginPath();
  waveformCtx.rect(bladeStartX, 0, progressX - bladeStartX, h);
  waveformCtx.clip();
  waveformCtx.shadowColor = c.main;
  waveformCtx.shadowBlur = 20 * pulse;
  waveformCtx.fillStyle = `rgba(${c.r}, ${c.g}, ${c.b}, ${0.4 * pulse})`;
  waveformCtx.fillRect(bladeStartX, 0, progressX - bladeStartX, h);
  waveformCtx.restore();

  // Middle glow layer
  waveformCtx.save();
  buildBladePath();
  waveformCtx.clip();
  waveformCtx.beginPath();
  waveformCtx.rect(bladeStartX, 0, progressX - bladeStartX, h);
  waveformCtx.clip();
  waveformCtx.shadowColor = c.main;
  waveformCtx.shadowBlur = 10;
  waveformCtx.fillStyle = `rgba(${c.r}, ${c.g}, ${c.b}, ${0.7 * pulse})`;
  waveformCtx.fillRect(bladeStartX, 0, progressX - bladeStartX, h);
  waveformCtx.restore();

  // Inner core (brightest — white-hot center)
  waveformCtx.save();
  // Build narrower core path (45% amplitude)
  waveformCtx.beginPath();
  waveformCtx.moveTo(bladeStartX, centerY);
  for (let i = 0; i < barCount; i++) {
    const x = bladeStartX + (i / barCount) * bladeWidth;
    const amp = waveformData[i] * maxAmplitude * 0.45;
    waveformCtx.lineTo(x, centerY - amp);
  }
  for (let i = barCount - 1; i >= 0; i--) {
    const x = bladeStartX + (i / barCount) * bladeWidth;
    const amp = waveformData[i] * maxAmplitude * 0.45;
    waveformCtx.lineTo(x, centerY + amp);
  }
  waveformCtx.closePath();
  waveformCtx.clip();
  waveformCtx.beginPath();
  waveformCtx.rect(bladeStartX, 0, progressX - bladeStartX, h);
  waveformCtx.clip();
  waveformCtx.fillStyle = '#ffffff';
  waveformCtx.shadowColor = c.core;
  waveformCtx.shadowBlur = 8;
  waveformCtx.fillRect(bladeStartX, 0, progressX - bladeStartX, h);
  waveformCtx.restore();

  // Progress edge glow (bright line at playhead)
  if (progress > 0 && progress < 1) {
    // Outer glow
    waveformCtx.shadowColor = c.main;
    waveformCtx.shadowBlur = 12 * pulse;
    waveformCtx.strokeStyle = `rgba(${c.r}, ${c.g}, ${c.b}, ${0.6 * pulse})`;
    waveformCtx.lineWidth = 4;
    waveformCtx.beginPath();
    waveformCtx.moveTo(progressX, centerY - h * 0.4);
    waveformCtx.lineTo(progressX, centerY + h * 0.4);
    waveformCtx.stroke();
    // Bright core line
    waveformCtx.shadowBlur = 0;
    waveformCtx.strokeStyle = '#ffffff';
    waveformCtx.lineWidth = 2;
    waveformCtx.beginPath();
    waveformCtx.moveTo(progressX, centerY - h * 0.35);
    waveformCtx.lineTo(progressX, centerY + h * 0.35);
    waveformCtx.stroke();
  }
}

// ─── Lyrics Rendering ──────────────────────────────────────────────

/**
 * Parse LRC format lyrics into an array of {time, text}
 */
function parseLRC(lrcString) {
  if (!lrcString) return null;
  const lines = [];
  const regex = /\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)/;

  lrcString.split('\n').forEach(line => {
    const match = line.match(regex);
    if (match) {
      const minutes = parseInt(match[1]);
      const seconds = parseInt(match[2]);
      const fraction = parseInt(match[3]);
      const ms = match[3].length === 3 ? fraction : fraction * 10;
      const time = minutes * 60 + seconds + ms / 1000;
      const text = match[4].trim();
      if (text) {
        lines.push({ time, text });
      }
    }
  });

  lines.sort((a, b) => a.time - b.time);
  return lines.length > 0 ? lines : null;
}

/**
 * Build lyrics DOM elements
 */
function buildLyricsDOM() {
  lyricsContainer.innerHTML = '';
  if (!lyricsLines) return;

  lyricsLines.forEach((line, i) => {
    const el = document.createElement('div');
    el.className = 'lyric-line';
    el.textContent = line.text;
    el.dataset.index = i;
    lyricsContainer.appendChild(el);
  });
}

/**
 * Update which lyric line is active based on current time
 */
function updateLyrics(currentTime) {
  if (!lyricsLines || lyricsLines.length === 0 || !lyricsVisible) return;

  let newIndex = -1;
  for (let i = lyricsLines.length - 1; i >= 0; i--) {
    if (currentTime >= lyricsLines[i].time) {
      newIndex = i;
      break;
    }
  }

  if (newIndex === currentLyricIndex) return;
  currentLyricIndex = newIndex;

  const lines = lyricsContainer.querySelectorAll('.lyric-line');
  lines.forEach((el, i) => {
    el.classList.remove('active', 'past');
    if (i === currentLyricIndex) {
      el.classList.add('active');
    } else if (i < currentLyricIndex) {
      el.classList.add('past');
    }
  });

  // Scroll the active line into view
  if (currentLyricIndex >= 0 && lines[currentLyricIndex]) {
    const scrollParent = document.getElementById('lyrics-body');
    if (scrollParent) {
      const lineTop = lines[currentLyricIndex].offsetTop;
      const lineHeight = lines[currentLyricIndex].offsetHeight;
      const parentHeight = scrollParent.offsetHeight;
      const targetScroll = lineTop - (parentHeight / 2) + (lineHeight / 2);
      scrollParent.scrollTo({ top: targetScroll, behavior: 'smooth' });
    }
  }
}

/**
 * Toggle lyrics view on/off
 */
function toggleLyricsView(show) {
  lyricsVisible = show;
  if (show && lyricsLines) {
    // Make visible FIRST so scrollIntoView can calculate positions
    // (the 0.5s opacity transition means the user won't see the wrong position)
    lyricsView.classList.add('visible');
    remeasureScrollingText();  // header rows had zero width while hidden
    contentEl.style.opacity = '0';
    contentEl.style.pointerEvents = 'none';

    // Reset and scroll to current position
    currentLyricIndex = -1;
    const currentTime = playerManager.getCurrentTimeSec();
    updateLyrics(currentTime);

    // Force scroll after layout is computed (Chromecast needs longer delay)
    setTimeout(() => {
      const activeLine = lyricsContainer.querySelector('.lyric-line.active');
      const scrollParent = document.getElementById('lyrics-body');
      if (activeLine && scrollParent) {
        // Calculate scroll position to center the active line
        const lineTop = activeLine.offsetTop;
        const lineHeight = activeLine.offsetHeight;
        const parentHeight = scrollParent.offsetHeight;
        scrollParent.scrollTop = lineTop - (parentHeight / 2) + (lineHeight / 2);
      } else if (scrollParent) {
        scrollParent.scrollTop = 0;
      }
    }, 100);
  } else {
    lyricsView.classList.remove('visible');
    remeasureScrollingText();
    // Restore now-playing view
    if (contentEl.classList.contains('visible')) {
      contentEl.style.opacity = '';
      contentEl.style.pointerEvents = '';
    }
  }
}

// ─── Sleep Timer Countdown ─────────────────────────────────────────

function formatCountdown(seconds) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

function startSleepCountdown(seconds) {
  stopSleepCountdown();
  sleepTimerRemaining = seconds;
  sleepCountdownEl.textContent = formatCountdown(sleepTimerRemaining);
  sleepTimerEl.classList.remove('hidden');
  console.log('[NASRadio] Sleep timer started:', seconds, 'seconds');

  sleepTimerInterval = setInterval(() => {
    sleepTimerRemaining--;
    if (sleepTimerRemaining <= 0) {
      stopSleepCountdown();
    } else {
      sleepCountdownEl.textContent = formatCountdown(sleepTimerRemaining);
    }
  }, 1000);
}

function stopSleepCountdown() {
  if (sleepTimerInterval) {
    clearInterval(sleepTimerInterval);
    sleepTimerInterval = null;
  }
  sleepTimerRemaining = 0;
  sleepTimerEl.classList.add('hidden');
}

// ─── Progress Updates ──────────────────────────────────────────────

function startProgressPolling() {
  stopProgressPolling();
  // Use requestAnimationFrame for butter-smooth waveform at native refresh rate (60/120fps)
  function tick() {
    updateProgress();
    progressInterval = requestAnimationFrame(tick);
  }
  progressInterval = requestAnimationFrame(tick);
}

function stopProgressPolling() {
  if (progressInterval) {
    cancelAnimationFrame(progressInterval);
    progressInterval = null;
  }
}

let _lastLyricsUpdate = 0;
let _lastTimeText = '';

// Smoother for getCurrentTimeSec(). The CAF SDK's getCurrentTimeSec()
// returns the underlying HTMLMediaElement's currentTime, which is only
// updated by the browser on the `timeupdate` event — and per the
// HTMLMediaElement spec that event fires at ~4Hz (every ~250ms),
// not vsync. RAF is calling our tick at 60/120fps but the data we read
// inside it stays at the same value across many ticks. Result: the
// waveform progress bar visibly steps in 250ms-ish jumps instead of
// gliding. Fix: extrapolate forward locally whenever the raw value
// hasn't moved, capping at duration. Same trick as the Flutter
// WaveformProgressBar's _smoothPosition.
let _smoothLastRaw = -1;
let _smoothLastRawAt = 0;
function smoothedCurrentTime() {
  const raw = playerManager.getCurrentTimeSec();
  const state = playerManager.getPlayerState();
  const playing = state === cast.framework.messages.PlayerState.PLAYING;
  if (raw !== _smoothLastRaw || !playing) {
    // Either the raw clock just ticked OR we're paused / buffering —
    // resync to the authoritative value.
    _smoothLastRaw = raw;
    _smoothLastRawAt = performance.now();
    return raw;
  }
  // Playing, raw clock hasn't moved yet — extrapolate forward.
  const elapsedSec = (performance.now() - _smoothLastRawAt) / 1000;
  return raw + elapsedSec;
}

// Card show/hide: .visible enters layout (display), .shown fades in a
// frame later. Hidden cards leave the flex stack entirely, so an unshown
// sibling can't push a visible card up the screen (the v29 toast bug).
function showCard(el) {
  if (el._hideTimer) {
    clearTimeout(el._hideTimer);
    el._hideTimer = null;
  }
  if (el.classList.contains('visible')) {
    el.classList.add('shown');   // possibly mid-fade-out — bring it back
    return;
  }
  el.classList.add('visible');
  // Double rAF: let the display change land before the fade starts,
  // or the transition gets skipped and the card just pops in.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => el.classList.add('shown'));
  });
}

function hideCard(el) {
  if (!el.classList.contains('visible') || el._hideTimer) return;
  el.classList.remove('shown');
  el._hideTimer = setTimeout(() => {
    el._hideTimer = null;
    el.classList.remove('visible');
  }, 500);
}

// Desktop-fullscreen "UP NEXT" card, TV edition: visible during the last
// 15s of a track when the queue has a next item; ring drains to the end.
const UPNEXT_LEAD_SEC = 15;

function updateUpNextCard(currentTime, duration) {
  const remaining = duration - currentTime;
  const next = _upNext.length > 0 ? _upNext[0] : null;
  const show = !liveMode && next && isFinite(duration) && duration > 0 &&
               remaining > 0 && remaining <= UPNEXT_LEAD_SEC;
  if (!show) {
    hideCard(upnextCard);
    _upnextShownFor = null;
    return;
  }
  if (_upnextShownFor !== next.contentId) {
    _upnextShownFor = next.contentId;
    const md = next.metadata || {};
    upnextTitle.textContent = md.title || '';
    upnextArtist.textContent = md.artist || '';
    const art = (md.images && md.images[0] && md.images[0].url) || '';
    if (art) {
      upnextArt.src = art;
      upnextArt.style.display = '';
    } else {
      upnextArt.style.display = 'none';
    }
  }
  upnextSecs.textContent = Math.ceil(remaining);
  upnextRing.style.setProperty('--pct', Math.max(0, remaining / UPNEXT_LEAD_SEC));
  showCard(upnextCard);
}

function updateProgress() {
  const state = playerManager.getPlayerState();
  if (state === cast.framework.messages.PlayerState.IDLE) {
    hideCard(upnextCard);
    return;
  }

  const currentTime = smoothedCurrentTime();
  const duration = playerManager.getDurationSec();
  updateUpNextCard(currentTime, duration);
  applySegueVolume(currentTime, duration);

  // Live stream: no scrubber math — just tick the elapsed listen time.
  // (Also catches a non-finite duration that slipped past LOAD metadata.)
  if (liveMode || !isFinite(duration)) {
    const now = Date.now();
    if (now - _lastLyricsUpdate > 250) {
      _lastLyricsUpdate = now;
      const timeText = formatTime(currentTime);
      if (timeText !== _lastTimeText) {
        currentTimeEl.textContent = timeText;
        _lastTimeText = timeText;
      }
    }
    return;
  }

  if (duration > 0) {
    const progress = Math.min(currentTime / duration, 1);
    drawWaveform(progress);
    // Throttle text/DOM updates to ~4fps (they don't need 60fps)
    const now = Date.now();
    if (now - _lastLyricsUpdate > 250) {
      _lastLyricsUpdate = now;
      const timeText = formatTime(currentTime);
      if (timeText !== _lastTimeText) {
        currentTimeEl.textContent = timeText;
        totalTimeEl.textContent = formatTime(duration);
        _lastTimeText = timeText;
      }
      updateLyrics(currentTime);
    }
  }
}

// ─── Remote Key Diagnostic ──────────────────────────────────────────
//
// LG TV remote presses MAY or MAY NOT reach this listener depending on
// whether webOS intercepts them at the OS layer. simpson1045's testing showed:
//   - OK key → CAF SDK's default handler toggles play/pause (works)
//   - Media play/pause key → webOS shows its own overlay, music does
//     not pause (key event apparently never reaches us)
// This listener relays every keydown back to the sender (phone) as a
// `DIAG_KEY` custom message so we can see in combined.log exactly
// which keys reach the receiver and which don't. Also best-effort
// wires up media keys to playerManager — if they DO reach us, they'll
// just work.
window.addEventListener('keydown', (e) => {
  _diag.K++;
  _renderDiagHud();
  // Relay to sender for combined.log capture.
  sendDiagToSender({
    type: 'DIAG_KEY',
    key: e.key,
    code: e.code,
    keyCode: e.keyCode,
  });

  // Best-effort direct handling for media keys. If the keydown does
  // reach our listener, CAF SDK won't auto-toggle for custom receivers
  // so we drive the player manager ourselves.
  if (e.key === 'MediaPlayPause' ||
      e.keyCode === 179 || e.keyCode === 463) {
    const state = playerManager.getPlayerState();
    if (state === cast.framework.messages.PlayerState.PLAYING) {
      playerManager.pause();
    } else if (state === cast.framework.messages.PlayerState.PAUSED) {
      playerManager.play();
    }
    e.preventDefault();
  }
});

// ─── Cast Protocol Message Interceptors (diagnostic) ────────────────
//
// Remote-key presses on webOS don't reach our window keydown listener —
// the diagnostic relay (DIAG_KEY) showed zero hits when simpson1045 pressed
// every media key. BUT skip-forward / skip-back DID actually move the
// playback position by 10s, meaning the cast SDK is receiving the
// commands via the cast protocol (MEDIA_SEEK messages) rather than as
// raw key events. That implies PLAY / PAUSE / STOP should arrive
// through the same protocol path too — but for some reason play/pause
// presses don't actually pause the music. To find out, intercept the
// MessageType.* events on playerManager: each interceptor relays
// `{type:'DIAG_MSG', msgType:'PLAY'}` etc. back to the sender for
// combined.log capture, then passes the request through untouched so
// default behaviour still runs. If PLAY arrives but the music doesn't
// pause, something downstream (audio focus, audio element state, etc.)
// is the culprit — not the message routing.
[
  ['PLAY', cast.framework.messages.MessageType.PLAY],
  ['PAUSE', cast.framework.messages.MessageType.PAUSE],
  ['STOP', cast.framework.messages.MessageType.STOP],
  ['SEEK', cast.framework.messages.MessageType.SEEK],
  ['LOAD', cast.framework.messages.MessageType.LOAD],
].forEach(([label, msgType]) => {
  playerManager.setMessageInterceptor(msgType, (request) => {
    _diag.I++;
    _renderDiagHud();
    if (label === 'LOAD') {
      // New media incoming — any stashed live track belongs to the
      // PREVIOUS station; drop it so the new one can't inherit it.
      _pendingStationTrack = null;
      // A sender is driving — stand down any pending self-advance.
      _cancelSelfAdvance();
    }
    if (label === 'STOP') {
      // Deliberate stop (user disconnect) — don't resurrect playback.
      _cancelSelfAdvance();
      _upNext = [];
    }
    sendDiagToSender({
      type: 'DIAG_MSG',
      msgType: label,
      currentTime: request && request.currentTime,
      // Who issued this command? The phone's senderId vs webOS's own
      // internal sender look different — this settles whether the
      // PAUSE→PLAY-211ms-later bounce came from the phone (toggle bug,
      // now fixed sender-side) or from webOS itself.
      senderId: (request && request.senderId) || null,
    });
    return request;
  });
});

// ─── Custom Message Handler ────────────────────────────────────────

// ── Scrolling single-line text ──────────────────────────────────────────
// Title / artist / album (and the lyrics-view header) are one line each.
// When the text is wider than its row it scrolls: hold, glide left at a
// constant speed, loop seamlessly. Fits -> plain centred text, no animation.
// Everything that writes those rows goes through setScrollingText().
const MARQUEE_PX_PER_SEC = 60;
const MARQUEE_GAP_PX = 90;
const _scrollingEls = new Set();

function _layoutScrollingText(el) {
  const text = el._marqueeText || '';
  el.textContent = '';
  const span = document.createElement('span');
  span.textContent = text;
  el.appendChild(span);
  if (!text || el.clientWidth === 0) return;      // hidden panel: measured on show
  // NB: an inline span's own scrollWidth is always 0 — measure the row's
  // scrollWidth for "does it fit" and the span's rendered box for distance.
  if (el.scrollWidth - el.clientWidth <= 4) return;    // it fits
  const textWidth = Math.ceil(span.getBoundingClientRect().width);

  const dist = textWidth + MARQUEE_GAP_PX;
  const track = document.createElement('span');
  track.className = 'marquee-track';
  const clone = span.cloneNode(true);
  clone.setAttribute('aria-hidden', 'true');
  span.style.paddingRight = MARQUEE_GAP_PX + 'px';
  clone.style.paddingRight = MARQUEE_GAP_PX + 'px';
  el.textContent = '';
  track.appendChild(span);
  track.appendChild(clone);
  track.style.setProperty('--marquee-dist', '-' + dist + 'px');
  // 12% of each cycle is the hold at the start (see the keyframes).
  track.style.animationDuration = (dist / MARQUEE_PX_PER_SEC / 0.88).toFixed(2) + 's';
  el.appendChild(track);
}

function setScrollingText(el, text) {
  if (!el) return;
  const next = text || '';
  if (el._marqueeText === next && el.firstChild) return;  // same text: don't restart the scroll
  el._marqueeText = next;
  _scrollingEls.add(el);
  // Plain text right away (so it's never blank), measured next frame once
  // layout has the new string.
  el.textContent = next;
  requestAnimationFrame(() => _layoutScrollingText(el));
}

function remeasureScrollingText() {
  requestAnimationFrame(() => _scrollingEls.forEach(_layoutScrollingText));
}
window.addEventListener('resize', remeasureScrollingText);

function _sendTo(senderId, payload) {
  try {
    context.sendCustomMessage(NASRADIO_NS, senderId || undefined, payload);
  } catch (e) {
    console.log('[NASRadio] sendCustomMessage to', senderId, 'threw:', e);
  }
}

// requestId -> {from, data, timer} for requests relayed owner-wards.
const _relayPending = new Map();

function _relay(from, data, targets, resultType) {
  const timer = setTimeout(() => {
    _relayPending.delete(data.requestId);
    _sendTo(from, { type: resultType, requestId: data.requestId, ok: false,
                    error: 'the queue owner did not answer' });
  }, 6000);
  _relayPending.set(data.requestId, { from, data, timer });
  const fwd = Object.assign({}, data, { from });
  targets.forEach((id) => _sendTo(id, fwd));
}

function _upNextBrief(item) {
  const m = item.metadata || {};
  const c = item.customData || {};
  return { songId: c.songId || null, title: m.title || null,
           artist: m.artist || m.albumArtist || null, album: m.albumName || null };
}

function currentStateForSenders() {
  const info = playerManager.getMediaInformation() || {};
  const m = info.metadata || {};
  const c = info.customData || {};
  return {
    playerState: playerManager.getPlayerState(),
    nowPlaying: info.contentId ? {
      songId: c.songId || null, title: m.title || null,
      artist: m.artist || m.albumArtist || null, album: m.albumName || null,
    } : null,
    upNext: _upNext.map(_upNextBrief),
    headless: !!c.headlessSender,
    senders: _senders.size,
  };
}

function handleQueueInsert(from, data) {
  const items = Array.isArray(data.items) ? data.items : [];
  if (items.length === 0) {
    _sendTo(from, { type: 'QUEUE_INSERT_RESULT', requestId: data.requestId,
                    ok: false, error: 'no items' });
    return;
  }
  const others = [..._senders].filter((id) => id !== from);
  if (others.length > 0) {
    _relay(from, data, others, 'QUEUE_INSERT_RESULT');
    return;
  }
  // Alone with the queue: it's ours to edit.
  if (data.mode === 'next') {
    _upNext.unshift(...items);
  } else {
    _upNext.push(...items);
  }
  _upnextShownFor = null;
  showQueueToast(data);
  _sendTo(from, { type: 'QUEUE_INSERT_RESULT', requestId: data.requestId,
                  ok: true, handledBy: 'receiver', queueLength: _upNext.length });
  console.log('[NASRadio] Guest queue insert handled locally:', items.length, 'items');
}

function showQueueToast(data) {
  // Attribution toast: mode-aware pill, big title, "Artist • by Name"
  // with the name in cyan, artist image (album-art fallback) as the
  // card's blurred background.
  queueToastLabel.textContent =
    data.mode === 'next' ? 'ADDED UP NEXT' : 'ADDED TO QUEUE';
  queueToastTitle.textContent = data.title || '';
  queueToastArtist.textContent = data.artist || '';
  queueToastByPre.textContent = data.artist ? ' • by ' : 'by ';
  queueToastBy.textContent = data.by || 'someone';
  if (data.artworkUrl) {
    queueToastArt.src = data.artworkUrl;
    queueToastArt.style.display = '';
  } else {
    queueToastArt.style.display = 'none';
  }
  const bgUrl = data.artistImageUrl || data.artworkUrl || '';
  queueToastBgImg.style.display = 'none';
  if (bgUrl) {
    const img = new Image();
    img.onload = function () {
      queueToastBgImg.src = bgUrl;
      queueToastBgImg.style.display = '';
    };
    img.src = bgUrl;
  }
  showCard(queueToast);
  if (_queueToastTimer) clearTimeout(_queueToastTimer);
  _queueToastTimer = setTimeout(() => {
    _queueToastTimer = null;
    hideCard(queueToast);
  }, 8000);
  console.log('[NASRadio] Queue added:', data.title, 'by', data.by);
}

context.addCustomMessageListener(NASRADIO_NS, (event) => {
  const data = event.data;
  console.log('[NASRadio] Custom message type:', data.type);

  if (data.type === 'WAVEFORM') {
    waveformData = data.data;
    console.log('[NASRadio] Received waveform:', waveformData ? waveformData.length : 0, 'samples');
    setupWaveformCanvas();
    drawWaveform(0);
    // Got it — cancel any in-flight retry so we don't spam the
    // sender with a second WAVEFORM_REQUEST.
    if (_waveformRequestTimer) {
      clearTimeout(_waveformRequestTimer);
      _waveformRequestTimer = null;
    }
    _waveformRequestAttempts = 0;

  } else if (data.type === 'LYRICS') {
    // Store lyrics but do NOT auto-show — user toggles from phone
    lyricsLines = parseLRC(data.synced);
    currentLyricIndex = -1;

    if (lyricsLines) {
      buildLyricsDOM();
      // Reset scroll to top so lyrics don't start mid-list when toggled on
      lyricsContainer.scrollTop = 0;
      console.log('[NASRadio] Lyrics ready:', lyricsLines.length, 'lines (hidden until toggled)');
    } else {
      lyricsContainer.innerHTML = '';
      // If lyrics view was showing but new song has no lyrics, hide it
      if (lyricsVisible) {
        toggleLyricsView(false);
      }
      console.log('[NASRadio] No synced lyrics for this track');
    }

  } else if (data.type === 'PARTY_MODE') {
    // Host started/ended a party. QR is served by our backend (public
    // while the party is active), so a plain img load works — no
    // crossOrigin, same lesson as the artwork loaders.
    const on = !!data.active;
    if (on && data.qrUrl) {
      partyQrImg.src = data.qrUrl;
      partyCodeEl.textContent = data.code || '';
      partyOverlay.classList.add('visible');
    } else {
      partyOverlay.classList.remove('visible');
      partyQrImg.src = '';
    }
    console.log('[NASRadio] Party mode:', on, data.code || '');

  } else if (data.type === 'UP_NEXT') {
    _upNext = Array.isArray(data.items) ? data.items : [];
    // Queue may have changed under the visible card — repopulate next tick
    _upnextShownFor = null;
    console.log('[NASRadio] UP_NEXT:', _upNext.length, 'items');

  } else if (data.type === 'QUEUE_ADDED') {
    showQueueToast(data);

  } else if (data.type === 'QUEUE_INSERT') {
    // A guest sender (Claude via the backend) wants tracks in a queue it
    // doesn't own. If the owner (phone) is connected, forward and let it
    // answer; if we're alone with a self-advance list (orphaned headless
    // queue), splice the items in ourselves.
    handleQueueInsert(event.senderId, data);

  } else if (data.type === 'QUEUE_INSERT_RESULT' || data.type === 'SKIP_RESULT') {
    // The owner answered a relayed request — pass it back to the guest.
    const pend = _relayPending.get(data.requestId);
    if (pend) {
      clearTimeout(pend.timer);
      _relayPending.delete(data.requestId);
      if (data.type === 'QUEUE_INSERT_RESULT' && data.ok) showQueueToast(pend.data);
      _sendTo(pend.from, data);
    }

  } else if (data.type === 'SKIP') {
    const others = [..._senders].filter((id) => id !== event.senderId);
    if (others.length === 0) {
      _sendTo(event.senderId, {
        type: 'SKIP_RESULT', requestId: data.requestId, ok: false,
        error: 'nobody owns this queue (no other sender connected)',
      });
    } else {
      _relay(event.senderId, data, others, 'SKIP_RESULT');
    }

  } else if (data.type === 'STATE_REQUEST') {
    _sendTo(event.senderId, Object.assign({ type: 'STATE', requestId: data.requestId },
      currentStateForSenders()));

  } else if (data.type === 'CROSSFADE') {
    const secs = parseFloat(data.seconds);
    crossfadeSec = isFinite(secs) ? Math.max(0, Math.min(secs, 12)) : 0;
    try { localStorage.setItem('nasradio_crossfade', String(crossfadeSec)); } catch (e) {}
    if (!crossfadeSec) castAudioEl.volume = 1;
    console.log('[NASRadio] Crossfade set:', crossfadeSec + 's');

  } else if (data.type === 'TOGGLE_LYRICS') {
    // Phone user pressed the lyrics button
    const shouldShow = data.show !== undefined ? data.show : !lyricsVisible;
    console.log('[NASRadio] Toggle lyrics:', shouldShow);
    toggleLyricsView(shouldShow);

  } else if (data.type === 'BADGES') {
    updateBadges(data);
    console.log('[NASRadio] Badges:', data.format, data.isHdcd ? '+HDCD' : '');

  } else if (data.type === 'SLEEP_TIMER') {
    if (data.remaining > 0) {
      startSleepCountdown(data.remaining);
    } else {
      stopSleepCountdown();
    }

  } else if (data.type === 'BLACK_SCREEN') {
    const active = data.active !== undefined ? data.active : !blackScreen.classList.contains('active');
    if (active) {
      blackScreen.classList.add('active');
    } else {
      blackScreen.classList.remove('active');
    }
    console.log('[NASRadio] Black screen:', active);

  } else if (data.type === 'ARTWORK_REFRESH') {
    // Album cover / artist image changed in the app while this song is
    // on. Same song, new pixels: the sender gives cache-busted URLs so
    // we don't repaint from the browser cache. Load first, swap on load.
    if (data.artworkUrl) {
      const fresh = new Image();
      fresh.onload = function () {
        currentArtworkUrl = data.artworkUrl;
        artwork.src = data.artworkUrl;
        lyricsArtworkSmall.src = data.artworkUrl;
        if (!data.artistImageUrl) bgImage.style.backgroundImage = `url(${data.artworkUrl})`;
        console.log('[NASRadio] Artwork refreshed');
      };
      fresh.src = data.artworkUrl;
    }
    if (data.artistImageUrl) {
      const freshBg = new Image();
      freshBg.onload = function () {
        currentBgImageUrl = data.artistImageUrl;
        bgImage.style.backgroundImage = `url(${data.artistImageUrl})`;
        console.log('[NASRadio] Artist image refreshed');
      };
      freshBg.onerror = function () {
        if (currentArtworkUrl) bgImage.style.backgroundImage = `url(${currentArtworkUrl})`;
      };
      freshBg.src = data.artistImageUrl;
    }
  } else if (data.type === 'NOW_PLAYING') {
    // Live station track update. The initial LOAD carries the station name;
    // this replaces the title/artist as the broadcast changes, with no
    // stream reload (so audio never gaps).
    // Stash it so the post-LOAD repaint can't wipe it (see
    // _pendingStationTrack).
    _pendingStationTrack = {
      title: data.title || null,
      artist: data.artist || null,
      artwork: data.artwork || null,
    };
    if (data.title) {
      setScrollingText(titleEl, data.title);
      titleEl.className = 'fade-in';
      setScrollingText(lyricsTitleEl, data.title);
    }
    if (data.artist !== undefined) {
      setScrollingText(artistEl, data.artist || '');
      artistEl.className = 'fade-in';
      setScrollingText(lyricsArtistEl, data.artist || '');
    }
    // Per-track artwork from the station's broadcast metadata. Same
    // guarded-Image pattern as updateMediaInfo — see currentBgImageUrl
    // above for why the guard matters on webOS. Doubles as the faded
    // background (stations have no artist image), so the screen isn't a
    // black void between the pill and the clock.
    if (data.artwork && data.artwork !== currentArtworkUrl) {
      const artUrl = data.artwork;
      currentArtworkUrl = artUrl;
      // No crossOrigin — station artwork is external and rarely sends
      // CORS headers; see the album-art loader in updateMediaInfo.
      const img = new Image();
      img.onload = function () {
        if (artUrl !== currentArtworkUrl) return; // superseded mid-flight
        artwork.src = artUrl;
        artwork.classList.add('loaded');
        lyricsArtworkSmall.src = artUrl;
        bgImage.style.backgroundImage = `url(${artUrl})`;
        currentBgImageUrl = artUrl;
        console.log('[NASRadio] Station artwork updated');
      };
      img.onerror = function () {
        console.warn('[NASRadio] Failed to load station artwork:', artUrl);
      };
      img.src = artUrl;
    }
    console.log('[NASRadio] Now playing:', data.title, '—', data.artist);
  }
});

// ─── CAF Event Listeners ──────────────────────────────────────────

playerManager.addEventListener(
  cast.framework.events.EventType.MEDIA_STATUS,
  (event) => {
    const mediaInfo = playerManager.getMediaInformation();
    if (mediaInfo) updateMediaInfo(mediaInfo);
  }
);

playerManager.addEventListener(
  cast.framework.events.EventType.PLAYER_LOAD_COMPLETE,
  (event) => {
    console.log('[NASRadio] Media loaded');
    const mediaInfo = playerManager.getMediaInformation();
    if (mediaInfo) updateMediaInfo(mediaInfo);
    setupWaveformCanvas();
    startProgressPolling();
    // Defensive: if the sender's normal post-LOAD waveform send is
    // dropped (race on subsequent songs is the most common cause —
    // see deferred-send timeout in cast_service.dart), ask for one
    // ourselves. Idempotent: stops retrying as soon as a waveform
    // arrives or the song changes.
    _ensureWaveform();
  }
);

// Send WAVEFORM_REQUEST to the sender with the current songId. The
// sender's _sendWaveformAndLyrics will reply on the same namespace.
// Retries with exponential backoff up to ~30s; gives up after that
// (sender genuinely doesn't have a waveform — e.g. brand-new import
// where analysis hasn't completed).
function _ensureWaveform() {
  if (_waveformRequestTimer) {
    clearTimeout(_waveformRequestTimer);
    _waveformRequestTimer = null;
  }
  if (waveformData && waveformData.length > 0) return;
  if (currentSongId === null) return;

  _waveformRequestAttempts++;
  if (_waveformRequestAttempts > 5) {
    console.log(
      '[NASRadio] Waveform request gave up after ' +
        _waveformRequestAttempts +
        ' attempts (song=' + currentSongId + ')'
    );
    return;
  }

  const songIdForThisAttempt = currentSongId;
  try {
    context.sendCustomMessage(NASRADIO_NS, _activeSenderId || undefined, {
      type: 'WAVEFORM_REQUEST',
      songId: songIdForThisAttempt,
    });
    _diag.S++;
    console.log(
      '[NASRadio] WAVEFORM_REQUEST sent (attempt ' +
        _waveformRequestAttempts + ', song=' + songIdForThisAttempt + ')'
    );
  } catch (e) {
    _diag.E++;
    console.log('[NASRadio] WAVEFORM_REQUEST failed: ' + e);
  }

  // Backoff: 1s, 2s, 4s, 8s, 16s. Stops on next call if waveformData
  // arrives or currentSongId changes.
  const delayMs = 1000 * Math.pow(2, _waveformRequestAttempts - 1);
  _waveformRequestTimer = setTimeout(() => {
    if (currentSongId === songIdForThisAttempt &&
        (!waveformData || waveformData.length === 0)) {
      _ensureWaveform();
    }
  }, delayMs);
}

playerManager.addEventListener(
  cast.framework.events.EventType.PLAYING,
  () => startProgressPolling()
);

playerManager.addEventListener(
  cast.framework.events.EventType.PAUSE,
  () => updateProgress()
);

playerManager.addEventListener(
  cast.framework.events.EventType.SEEKED,
  () => {
    currentLyricIndex = -1; // Force lyrics re-sync after seek
    updateProgress();
  }
);

playerManager.addEventListener(
  cast.framework.events.EventType.MEDIA_FINISHED,
  () => {
    console.log('[NASRadio] Media finished');
    stopProgressPolling();
    waveformData = null;
    lyricsLines = null;
    currentLyricIndex = -1;
    lyricsContainer.innerHTML = '';
    // Cancel any pending waveform-request retry — the song this
    // request was associated with is gone.
    if (_waveformRequestTimer) {
      clearTimeout(_waveformRequestTimer);
      _waveformRequestTimer = null;
    }
    _waveformRequestAttempts = 0;
    // Hide lyrics view when song ends
    toggleLyricsView(false);
    // Hide badges
    formatBadge.classList.add('hidden');
    atmosBadge.classList.add('hidden');
    ddplusBadge.classList.add('hidden');
    surroundBadge.classList.add('hidden');
    hdcdBadge.classList.add('hidden');
    explicitBadge.classList.add('hidden');
    // No sender LOAD within the grace period? Advance ourselves.
    _scheduleSelfAdvance();
  }
);

playerManager.addEventListener(
  cast.framework.events.EventType.ERROR,
  (event) => {
    console.error('[NASRadio] ERROR:', event.detailedErrorCode, event.reason);
  }
);

function showIdle() {
  contentEl.classList.remove('visible');
  idleScreen.classList.remove('hidden');
  toggleLyricsView(false);
  stopProgressPolling();
  waveformData = null;
  lyricsLines = null;
  currentLyricIndex = -1;
  lyricsContainer.innerHTML = '';
  formatBadge.classList.add('hidden');
  atmosBadge.classList.add('hidden');
  ddplusBadge.classList.add('hidden');
  surroundBadge.classList.add('hidden');
  hdcdBadge.classList.add('hidden');
  explicitBadge.classList.add('hidden');
  drawWaveform(0);
  currentTimeEl.textContent = '0:00';
  totalTimeEl.textContent = '0:00';
}

// ─── Receiver Startup ─────────────────────────────────────────────

setupWaveformCanvas();
window.addEventListener('resize', setupWaveformCanvas);

const playbackConfig = new cast.framework.PlaybackConfig();
playbackConfig.mediaElement = document.getElementById('castMediaElement');

const options = new cast.framework.CastReceiverOptions();
options.disableIdleTimeout = true;
options.playbackConfig = playbackConfig;
options.customNamespaces = {};
options.customNamespaces[NASRADIO_NS] = cast.framework.system.MessageType.JSON;

context.start(options);

console.log('[NASRadio] Custom receiver started');
