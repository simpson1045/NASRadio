import itertools
import os
import re
import sys
import time
import traceback

import psycopg2
import psycopg2.errors
import psycopg2.extras
import psycopg2.pool
from datetime import datetime


# ──────────────────────────────────────────────────────────────────────
# Pool lease tracking
#
# Every connection handed out by the pool is registered here with the
# Flask endpoint / route path / caller file:line / acquisition time.
# When psycopg2 raises PoolError("connection pool exhausted") we dump
# every currently-held lease to the log so you can see who's hogging.
# The /api/health endpoint also exposes the current holders so the
# in-app System Logs screen can show live state.
#
# NOTE: no threading.Lock anywhere in this file. Under eventlet's
# monkey-patch, threading.Lock becomes an eventlet Semaphore —
# safe to acquire/release across green threads within the hub,
# but FATAL when touched from a real OS thread (e.g. a
# threading.Thread background scheduler). The previous version
# used a Lock here and caused `greenlet.error: Cannot switch to
# a different thread` to fire at random. Eventlet green threads
# don't preempt each other between yield points, and CPython dict
# mutations are atomic, so the lock was never actually needed for
# correctness in the cooperative model. Kept the same API.
# ──────────────────────────────────────────────────────────────────────

_active_leases = {}  # lease_id (int) -> dict(endpoint, path, caller, acquired_at)
_lease_counter = itertools.count(1)

_APP_DIR = os.path.dirname(os.path.abspath(__file__))


def _caller_hint(skip_frames=3):
    """Walk back up the call stack and return the first frame whose
    file lives inside backend/app/ (i.e. the real caller, not our
    wrapper). Returned as 'routes.py:1234'. Best-effort — silent
    fallback keeps get_connection() fast and resilient.
    """
    try:
        frame = sys._getframe(skip_frames)
        for _ in range(20):
            if frame is None:
                break
            fname = frame.f_code.co_filename
            if fname.startswith(_APP_DIR) and not fname.endswith("models.py"):
                return f"{os.path.basename(fname)}:{frame.f_lineno}"
            frame = frame.f_back
    except Exception:
        pass
    return "?"


def _request_endpoint():
    """Pull Flask endpoint + path if we're inside a request context."""
    try:
        from flask import has_request_context, request

        if has_request_context():
            return request.endpoint or "?", request.path or "?"
    except Exception:
        pass
    return None, None


def _register_lease():
    lease_id = next(_lease_counter)
    endpoint, path = _request_endpoint()
    # Atomic dict insert — safe under eventlet's cooperative
    # scheduling without needing any lock.
    _active_leases[lease_id] = {
        "endpoint": endpoint,
        "path": path,
        "caller": _caller_hint(skip_frames=4),
        "acquired_at": time.time(),
    }
    return lease_id


def _release_lease(lease_id):
    # Atomic dict pop — safe under eventlet's cooperative scheduling.
    _active_leases.pop(lease_id, None)


def get_pool_holders():
    """Snapshot of who's currently holding a pooled connection.
    Sorted oldest-first — the top of the list is your prime suspect.
    """
    now = time.time()
    # Snapshot first so we don't hold a reference while iterating
    # if another green thread mutates in the middle.
    snapshot = list(_active_leases.items())
    rows = [
        {
            "lease_id": lid,
            "endpoint": info["endpoint"],
            "path": info["path"],
            "caller": info["caller"],
            "held_for_s": round(now - info["acquired_at"], 3),
        }
        for lid, info in snapshot
    ]
    rows.sort(key=lambda r: r["held_for_s"], reverse=True)
    return rows


def _dump_holders_on_exhaustion():
    """Called right before re-raising PoolError. Prints every
    currently-held lease to stderr with how long they've been out.
    """
    holders = get_pool_holders()
    print("🔴 DB pool exhausted — current holders:")
    if not holders:
        print("   (no leases tracked — instrumentation may be bypassed)")
        return
    for h in holders:
        print(
            f"   [{h['held_for_s']:>6.2f}s] {h['endpoint'] or '?':<40} "
            f"{h['path'] or '?':<50} {h['caller']}"
        )


# ── Long-held connection watchdog ─────────────────────────────────────
# A pooled connection that stays checked out holds an open transaction
# ("idle in transaction" in pg_stat_activity). On its own that only wastes
# a connection; combined with any DDL it froze the whole backend on
# 2026-09-23 (see HANDOFF "lock convoy"). Log who is holding one so the
# next leak names itself.
LEASE_WARN_AFTER_SEC = 120
_lease_warned = set()


def start_lease_watchdog(interval=60):
    import eventlet

    def _loop():
        while True:
            eventlet.sleep(interval)
            try:
                live = set()
                for h in get_pool_holders():
                    live.add(h["lease_id"])
                    if h["held_for_s"] >= LEASE_WARN_AFTER_SEC and h["lease_id"] not in _lease_warned:
                        _lease_warned.add(h["lease_id"])
                        print(f"🟠 DB connection held {int(h['held_for_s'])}s by {h['caller']} "
                              f"({h['endpoint'] or 'background job'} {h['path'] or ''}) - "
                              f"its transaction stays open the whole time")
                _lease_warned.intersection_update(live)
            except Exception as e:
                print(f"⚠️ lease watchdog: {e}")

    eventlet.spawn_n(_loop)
    print(f"🩺 DB lease watchdog started - warns on connections held > {LEASE_WARN_AFTER_SEC}s")


# ── Schema migration without the lock convoy ──────────────────────────
# Postgres takes ACCESS EXCLUSIVE for "ALTER TABLE .. ADD COLUMN IF NOT
# EXISTS" (and a SHARE lock for CREATE INDEX IF NOT EXISTS) BEFORE it checks
# whether the column/index exists, and init_db holds every lock until its
# final commit. So a no-op migration behind one slow reader stalled every
# query on songs/albums/users. This cursor skips DDL whose target already
# exists (catalog lookup, no table locks), and lock_timeout makes anything
# that does need a lock fail fast and retry instead of queueing.
MIGRATION_LOCK_TIMEOUT = "3s"
MIGRATION_ATTEMPTS = 5


class _MigrationCursor:
    _ALTER = re.compile(r"^\s*ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+(\w+)", re.I)
    _TABLE = re.compile(r"^\s*CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+(\w+)", re.I)
    _INDEX = re.compile(r"^\s*CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+(\w+)", re.I)

    def __init__(self, cur):
        self._cur = cur
        self.ran = 0
        self.skipped = 0
        cur.execute(f"SET LOCAL lock_timeout = '{MIGRATION_LOCK_TIMEOUT}'")
        cur.execute("SELECT table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema = current_schema()")
        self._cols = {(r["table_name"].lower(), r["column_name"].lower()) for r in cur.fetchall()}
        self._tables = {tn for tn, _ in self._cols}
        cur.execute("SELECT indexname FROM pg_indexes WHERE schemaname = current_schema()")
        self._indexes = {r["indexname"].lower() for r in cur.fetchall()}

    def execute(self, sql, params=None):
        s = sql if isinstance(sql, str) else str(sql)
        m = self._ALTER.match(s)
        if m and (m.group(1).lower(), m.group(2).lower()) in self._cols:
            self.skipped += 1
            return None
        m = self._TABLE.match(s)
        if m and m.group(1).lower() in self._tables:
            self.skipped += 1
            return None
        m = self._INDEX.match(s)
        if m and m.group(1).lower() in self._indexes:
            self.skipped += 1
            return None
        self.ran += 1
        return self._cur.execute(sql) if params is None else self._cur.execute(sql, params)

    def __getattr__(self, name):
        return getattr(self._cur, name)


class PooledConnection:
    """Wrapper that returns connection to pool on close() instead of closing"""

    def __init__(self, conn, pool, lease_id=None):
        self._conn = conn
        self._pool = pool
        self._returned = False
        self._lease_id = lease_id

    def close(self):
        """Return to pool instead of closing"""
        if self._returned:
            return
        self._returned = True
        try:
            self._conn.rollback()  # Clear any uncommitted state
        except Exception:
            pass
        try:
            self._pool.putconn(self._conn)
        except Exception:
            pass
        if self._lease_id is not None:
            _release_lease(self._lease_id)
            self._lease_id = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def __del__(self):
        """Safety net - return connection if someone forgot to close"""
        if not self._returned:
            self.close()

    def __getattr__(self, name):
        return getattr(self._conn, name)


class Database:
    """Handle all database operations for NASRadio"""

    _initialized = False
    _pool = None

    def __init__(self, db_url, migrate=False):
        """migrate=True only from the backend's startup (run.py) and the
        manage_users CLI. Every other Database() - request handlers, jobs,
        token mints run with `docker exec`, scripts - just connects."""
        self.db_url = db_url
        self._init_pool()
        if migrate:
            self.init_db()

    def _init_pool(self):
        """Initialize connection pool (once).

        maxconn=75: bumped from 50 on 2026-06-01 after the favorites/check
        per-song burst pattern (each FavoriteButton in a list of 50 songs
        fires its own HTTP request) exhausted the pool. PostgreSQL default
        max_connections is 100 so 75 still leaves headroom for direct
        DBeaver / psql sessions. Real fix is a batch /api/favorites/check
        endpoint on the backend + a frontend pre-load (deferred).
        """
        if Database._pool is None:
            Database._pool = psycopg2.pool.ThreadedConnectionPool(
                minconn=5, maxconn=75, dsn=self.db_url
            )
            print("✅ PostgreSQL connection pool initialized (5-75 connections)")

    def get_connection(self):
        """Get pooled connection, tagged with its lease holder."""
        try:
            conn = Database._pool.getconn()
        except psycopg2.pool.PoolError:
            _dump_holders_on_exhaustion()
            raise
        conn.autocommit = False
        lease_id = _register_lease()
        return PooledConnection(conn, Database._pool, lease_id=lease_id)

    def get_cursor(self, conn):
        """Get a cursor that returns dictionaries"""
        # Handle both wrapped and raw connections
        raw_conn = conn._conn if isinstance(conn, PooledConnection) else conn
        return raw_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    def init_db(self):
        """Create/upgrade the schema. Once per process, only when asked
        (Database(url, migrate=True)). Retries if a needed lock is busy."""
        if Database._initialized:
            return
        for attempt in range(1, MIGRATION_ATTEMPTS + 1):
            self._mig_conn = None
            try:
                self._run_migrations()
                return
            except psycopg2.errors.LockNotAvailable as e:
                print(f"⚠️ schema migration: lock busy for > {MIGRATION_LOCK_TIMEOUT} "
                      f"(attempt {attempt}/{MIGRATION_ATTEMPTS}): {str(e).strip()[:120]}")
                time.sleep(3 * attempt)
            finally:
                if self._mig_conn is not None:
                    self._mig_conn.close()
        raise RuntimeError("schema migration could not get its locks - another session "
                           "is holding a transaction on these tables")

    def _run_migrations(self):
        conn = self.get_connection()
        self._mig_conn = conn
        cursor = _MigrationCursor(self.get_cursor(conn))

        # Artists table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS artists (
                id SERIAL PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                album_count INTEGER DEFAULT 0,
                song_count INTEGER DEFAULT 0,
                image_path TEXT,
                last_played TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                mbid TEXT
            )
        """
        )

        # Artist aliases — alternate names / nicknames (e.g. "IZ" or
        # "Bruddah Iz" for "Israel Kamakawiwoʻole"), so search can resolve a
        # nickname to the canonical artist. Backfilled from MusicBrainz where
        # an mbid exists; can also be added manually.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS artist_aliases (
                id SERIAL PRIMARY KEY,
                artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
                alias TEXT NOT NULL,
                source TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(artist_id, alias)
            )
        """
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_artist_aliases_artist_id "
            "ON artist_aliases(artist_id)"
        )

        # Albums table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS albums (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                artist_id INTEGER NOT NULL REFERENCES artists(id),
                year INTEGER,
                song_count INTEGER DEFAULT 0,
                artwork_path TEXT,
                artwork_verified INTEGER DEFAULT 0,
                last_played TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                mbid TEXT,
                folder_path TEXT,
                album_type TEXT,
                secondary_types TEXT
            )
        """
        )

        # Songs table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS songs (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                artist_id INTEGER NOT NULL REFERENCES artists(id),
                album_id INTEGER NOT NULL REFERENCES albums(id),
                track_number INTEGER,
                disc_number INTEGER DEFAULT 1,
                duration INTEGER,
                file_path TEXT NOT NULL UNIQUE,
                file_size INTEGER,
                bitrate INTEGER,
                play_count INTEGER DEFAULT 0,
                skip_count INTEGER DEFAULT 0,
                last_played TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                file_format TEXT,
                is_explicit INTEGER,
                is_hdcd INTEGER
            )
        """
        )

        # Play history table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS play_history (
                id SERIAL PRIMARY KEY,
                song_id INTEGER NOT NULL REFERENCES songs(id),
                played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                completed INTEGER DEFAULT 0,
                completion_percentage INTEGER DEFAULT 0
            )
        """
        )

        # Users table — multi-user auth. user_id 1 is the seeded admin (simpson1045);
        # existing data (playlists/favorites default user_id 1) belongs to them.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT 'user',
                token_version INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )

        # Favorites table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS favorites (
                id SERIAL PRIMARY KEY,
                user_id INTEGER DEFAULT 1,
                item_type TEXT NOT NULL,
                item_id INTEGER NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(user_id, item_type, item_id)
            )
        """
        )

        # Song-Artists junction table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS song_artists (
                id SERIAL PRIMARY KEY,
                song_id INTEGER NOT NULL REFERENCES songs(id),
                artist_id INTEGER NOT NULL REFERENCES artists(id),
                position INTEGER DEFAULT 1,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(song_id, artist_id)
            )
        """
        )

        # Disc names table (for multi-disc albums)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS disc_names (
                id SERIAL PRIMARY KEY,
                album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
                disc_number INTEGER NOT NULL,
                disc_name TEXT NOT NULL,
                UNIQUE(album_id, disc_number)
            )
        """
        )

        # Indexes
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_song_artists_song ON song_artists(song_id)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_song_artists_artist ON song_artists(artist_id)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_favorites_lookup ON favorites(user_id, item_type, item_id)"
        )

        # Excluded paths table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS excluded_paths (
                id SERIAL PRIMARY KEY,
                file_path TEXT NOT NULL UNIQUE,
                original_title TEXT,
                original_artist TEXT,
                original_album TEXT,
                excluded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )

        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_excluded_paths_file ON excluded_paths(file_path)"
        )

        # Unique index on albums (case-insensitive)
        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_albums_unique 
            ON albums(artist_id, LOWER(title))
            """
        )

        # Playlists table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS playlists (
                id SERIAL PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                user_id INTEGER DEFAULT 1,
                song_count INTEGER DEFAULT 0,
                total_duration INTEGER DEFAULT 0,
                pinned INTEGER DEFAULT 0,
                last_played_at TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                source TEXT DEFAULT 'user'
            )
        """
        )

        # Where a playlist came from: 'user' (default) or 'kylie' (AI-generated
        # weekly mixes). Lets the playlists screen feature KYLIE playlists in a
        # dedicated band. ALTER covers databases created before this column.
        cursor.execute(
            "ALTER TABLE playlists ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'user'"
        )

        # Playlist songs junction table
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS playlist_songs (
                id SERIAL PRIMARY KEY,
                playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                song_id INTEGER REFERENCES songs(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                spotify_track_id TEXT,
                spotify_track_name TEXT,
                spotify_artist TEXT,
                spotify_album TEXT,
                mbid TEXT
            )
        """
        )

        # Playback state table (for device sync)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS playback_state (
                id SERIAL PRIMARY KEY,
                device_id TEXT NOT NULL UNIQUE,
                device_name TEXT,
                current_song_id INTEGER,  -- No FK: can be negative for podcast virtual songs
                position_ms INTEGER DEFAULT 0,
                queue_json TEXT,
                original_queue_json TEXT,
                queue_index INTEGER DEFAULT 0,
                shuffle_mode INTEGER DEFAULT 0,
                repeat_mode INTEGER DEFAULT 0,
                volume REAL DEFAULT 0.7,
                is_playing INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 0,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                group_id TEXT,
                group_role TEXT DEFAULT 'independent',
                controlled_by TEXT
            )
        """
        )

        # Song analysis table (Essentia ML results)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS song_analysis (
                id SERIAL PRIMARY KEY,
                song_id INTEGER NOT NULL UNIQUE REFERENCES songs(id),
                bpm REAL,
                bpm_confidence REAL,
                musical_key TEXT,
                musical_scale TEXT,
                key_confidence REAL,
                loudness REAL,
                dynamic_complexity REAL,
                integrated_loudness_lufs REAL,
                loudness_range_lu REAL,
                true_peak_dbfs REAL,
                mood_happy REAL,
                mood_sad REAL,
                mood_aggressive REAL,
                mood_relaxed REAL,
                mood_acoustic REAL,
                mood_electronic REAL,
                mood_danceability REAL,
                mood_instrumental REAL,
                mood_party REAL,
                mood_tonal REAL,
                mood_bright REAL,
                voice_female REAL,
                voice_male REAL,
                genres TEXT,
                instruments TEXT,
                themes TEXT,
                analyzed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )

        # Spotify plays table (imported history)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS spotify_plays (
                id SERIAL PRIMARY KEY,
                ts TIMESTAMP,
                platform TEXT,
                ms_played INTEGER,
                track_name TEXT,
                artist_name TEXT,
                album_name TEXT,
                spotify_track_uri TEXT,
                spotify_artist_uri TEXT,
                reason_start TEXT,
                reason_end TEXT,
                shuffle INTEGER,
                skipped INTEGER,
                offline INTEGER,
                matched_song_id INTEGER REFERENCES songs(id),
                matched_at TIMESTAMP
            )
        """
        )

        # Last.fm scrobbling config (key-value store)
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS lastfm_config (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """
        )

        # Runtime settings overrides (see app/settings.py). Rows here win over
        # .env; absence of a row means "use env/default".
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS app_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )

        # Pairs the user marked as "not actually duplicates" in the
        # duplicate-album resolver UI. Schema CREATE was missing for a
        # long time — find_duplicate_albums + the dismiss endpoint
        # both referenced this table without anything ever creating it,
        # so the endpoints have been erroring with "relation does not
        # exist" until that page was hit fresh. Added 2026-06-01.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS not_duplicate_albums (
                album_id_1 INTEGER NOT NULL,
                album_id_2 INTEGER NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (album_id_1, album_id_2)
            )
        """
        )

        # RSS podcast feeds
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS rss_feeds (
                id SERIAL PRIMARY KEY,
                feed_url TEXT NOT NULL UNIQUE,
                title TEXT,
                description TEXT,
                artwork_url TEXT,
                artwork_cached TEXT,
                author TEXT,
                link TEXT,
                last_fetched_at TIMESTAMP,
                auto_download INTEGER DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )

        # RSS podcast episodes
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS rss_episodes (
                id SERIAL PRIMARY KEY,
                feed_id INTEGER NOT NULL REFERENCES rss_feeds(id) ON DELETE CASCADE,
                guid TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                audio_url TEXT,
                audio_type TEXT,
                audio_duration INTEGER,
                audio_size INTEGER,
                link TEXT,
                published_at TIMESTAMP,
                played_position INTEGER DEFAULT 0,
                is_completed INTEGER DEFAULT 0,
                downloaded_path TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(feed_id, guid)
            )
        """
        )

        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_episodes_feed ON rss_episodes(feed_id)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_episodes_published ON rss_episodes(published_at DESC)"
        )

        # Performance indexes for search and lookup
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_songs_file_path ON songs(file_path)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_songs_album_id ON songs(album_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_songs_title ON songs(title)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_albums_title ON albums(title)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_artists_name ON artists(name)")

        # Schema migrations for existing databases
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS is_hdcd INTEGER")

        # Genres from MusicBrainz (genre_fetcher.py). Top few community
        # genres per album, best first; albums with no votes inherit the
        # artist's. genres_source says which. fetched_at drives resume.
        cursor.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS genres TEXT[]")
        cursor.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS genres_source TEXT")
        cursor.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS genres_fetched_at TIMESTAMP")
        cursor.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS release_group_mbid TEXT")
        cursor.execute("ALTER TABLE artists ADD COLUMN IF NOT EXISTS genres TEXT[]")
        cursor.execute("ALTER TABLE artists ADD COLUMN IF NOT EXISTS genres_fetched_at TIMESTAMP")
        # Where an artist image came from ("spotify:<id>", "fanart:<url>",
        # "manual:<url>", "upload"), so a wrong face is diagnosable.
        cursor.execute("ALTER TABLE artists ADD COLUMN IF NOT EXISTS image_source TEXT")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_albums_genres ON albums USING GIN (genres)")

        # Songs Essentia couldn't analyze (audio_analysis.py). attempts caps
        # retries; permanent = the input itself is the problem. The batch
        # query and the reconciler both skip these, so one poison file can
        # no longer restart the same doomed batch forever.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS song_analysis_failures (
                song_id INTEGER PRIMARY KEY REFERENCES songs(id) ON DELETE CASCADE,
                attempts INTEGER NOT NULL DEFAULT 1,
                last_error TEXT,
                permanent BOOLEAN NOT NULL DEFAULT FALSE,
                last_attempt_at TIMESTAMP
            )
        """
        )

        # MusicBrainz discography cache (discography.py): every release group
        # per artist, refreshed monthly or on demand. Ownership is never
        # cached here; it's matched against albums on each request.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS mb_release_groups (
                id SERIAL PRIMARY KEY,
                artist_id INTEGER NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
                mbid TEXT NOT NULL,
                title TEXT NOT NULL,
                primary_type TEXT,
                secondary_types TEXT,
                first_release_date TEXT,
                year INTEGER,
                category TEXT,
                is_bootleg BOOLEAN DEFAULT FALSE,
                fetched_at TIMESTAMP,
                UNIQUE (artist_id, mbid)
            )
        """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS mb_discography_status (
                artist_id INTEGER PRIMARY KEY REFERENCES artists(id) ON DELETE CASCADE,
                artist_mbid TEXT,
                status TEXT,
                error TEXT,
                fetched_at TIMESTAMP,
                total INTEGER
            )
        """
        )

        # Spectral transcode detection (spectral_analysis.py). cutoff_hz =
        # detected spectral extent / brick-wall frequency; transcode_suspect
        # 0/1 (same int convention as is_hdcd); analyzed_at drives resume.
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS spectral_cutoff_hz INTEGER"
        )
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS transcode_suspect INTEGER"
        )
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS spectral_analyzed_at TIMESTAMP"
        )

        # Surround/Atmos metadata (scanner.py + backfill_audio_meta.py).
        # audio_codec: 'flac','eac3','ac3','aac','alac','mp3','opus',...
        # audio_channels: stream channel count (2 = stereo, 5/6/8 = surround).
        # is_atmos: 0/1 (same int convention as is_hdcd) — E-AC-3 JOC
        # ("Dolby Digital Plus + Dolby Atmos" per ffprobe). Cast passes these
        # bitstreams through the C2's eARC untouched; multichannel PCM gets a
        # .cast.m4a E-AC-3 sidecar instead (the TV folds >2ch PCM to stereo).
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS audio_codec TEXT")
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS audio_channels INTEGER"
        )
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS is_atmos INTEGER")

        # Album editions (ALBUM_EDITIONS_SPEC.md) — Jellyfin-style
        # one-album-many-editions. group_id links editions of the same
        # release; edition_label names the mix ("Dolby Atmos",
        # "SACD 5.0"; NULL = default edition); mb_release_id is the
        # release-LEVEL MusicBrainz id (albums.mbid stays group-level).
        cursor.execute(
            """CREATE TABLE IF NOT EXISTS album_groups (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                artist_id INTEGER REFERENCES artists(id) ON DELETE CASCADE,
                mbid TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )"""
        )
        cursor.execute(
            "ALTER TABLE albums ADD COLUMN IF NOT EXISTS group_id INTEGER "
            "REFERENCES album_groups(id) ON DELETE SET NULL"
        )
        cursor.execute(
            "ALTER TABLE albums ADD COLUMN IF NOT EXISTS edition_label TEXT"
        )
        cursor.execute(
            "ALTER TABLE albums ADD COLUMN IF NOT EXISTS mb_release_id TEXT"
        )

        cursor.execute("ALTER TABLE rss_feeds ADD COLUMN IF NOT EXISTS custom_author TEXT")

        # Playback source context — preserves "Playing from X" on Resume-
        # from-device. Without these, a phone resuming desktop's playlist
        # session gets queue+position but loses the playlist identity, so
        # the Now Playing label falls back to album context.
        cursor.execute("ALTER TABLE playback_state ADD COLUMN IF NOT EXISTS source_type TEXT")
        cursor.execute("ALTER TABLE playback_state ADD COLUMN IF NOT EXISTS source_id INTEGER")
        cursor.execute("ALTER TABLE playback_state ADD COLUMN IF NOT EXISTS source_name TEXT")

        # Podcast refactor (Phase 1) — unify episodes into songs.
        # The legacy virtual-Song pattern (Song(id: -episodeId)) is being
        # replaced with real songs rows flagged source_type='podcast'.
        # Adding columns now; frontend continues to use rss_episodes path
        # until PODCAST_UNIFIED_MODEL flag flips in Phase 3.
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS source_type TEXT NOT NULL DEFAULT 'local'"
        )
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS podcast_feed_id INTEGER REFERENCES rss_feeds(id) ON DELETE CASCADE"
        )
        cursor.execute(
            "ALTER TABLE songs ADD COLUMN IF NOT EXISTS podcast_episode_id INTEGER REFERENCES rss_episodes(id) ON DELETE CASCADE"
        )
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS source_url TEXT")
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS resolved_url TEXT")
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS resolved_url_expires_at TIMESTAMP")
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS played_position INTEGER DEFAULT 0")
        cursor.execute("ALTER TABLE songs ADD COLUMN IF NOT EXISTS is_completed INTEGER DEFAULT 0")
        # Secondary release-group types (Compilation/Live/Soundtrack/...) from
        # MusicBrainz, so studio albums can be told apart from comps/live.
        cursor.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS secondary_types TEXT")
        # Per-album / per-artist Last.fm scrobble opt-out. When either the
        # album or its artist is excluded, plays don't scrobble or update
        # "now playing" (e.g. personal/phone recordings you don't want public).
        cursor.execute("ALTER TABLE albums ADD COLUMN IF NOT EXISTS exclude_from_scrobble BOOLEAN DEFAULT FALSE")
        cursor.execute("ALTER TABLE artists ADD COLUMN IF NOT EXISTS exclude_from_scrobble BOOLEAN DEFAULT FALSE")

        # Cache the resolved CDN URL for podcast episodes so the stream proxy
        # doesn't re-walk the Podtrac/Chartable/Megaphone tracker chain on every
        # HEAD+GET (was ~15-20s per play). Resolve once, cache + expiry, reuse.
        cursor.execute("ALTER TABLE rss_episodes ADD COLUMN IF NOT EXISTS resolved_url TEXT")
        cursor.execute("ALTER TABLE rss_episodes ADD COLUMN IF NOT EXISTS resolved_url_expires_at TIMESTAMP")

        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_songs_source_type ON songs(source_type)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_songs_podcast_episode ON songs(podcast_episode_id)"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_songs_podcast_feed ON songs(podcast_feed_id)"
        )

        # ── Stations: live internet radio (Icecast/Shoutcast direct streams) ──
        # Direct passthrough — the app streams station.url itself (no backend
        # relay), the same way podcasts 302 straight to their CDN.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS stations (
                id SERIAL PRIMARY KEY,
                name TEXT NOT NULL,
                url TEXT NOT NULL UNIQUE,
                genre TEXT,
                description TEXT,
                homepage TEXT,
                favicon TEXT,
                source TEXT DEFAULT 'user',
                sort_order INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 1,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_stations_active ON stations(is_active)"
        )
        # Seed verified featured stations on FIRST run only (count==0), so a user
        # deleting a featured one doesn't get it resurrected on every restart.
        cursor.execute("SELECT COUNT(*) AS n FROM stations")
        if cursor.fetchone()["n"] == 0:
            _featured = [
                ("Nightride FM", "https://stream.nightride.fm/nightride.mp3", "Synthwave", "24/7 synthwave", "https://nightride.fm"),
                ("Nightride — Chillsynth", "https://stream.nightride.fm/chillsynth.mp3", "Chillsynth", "Mellow, dreamy synthwave", "https://nightride.fm"),
                ("Nightride — Darksynth", "https://stream.nightride.fm/darksynth.mp3", "Darksynth", "Darker, harder synthwave", "https://nightride.fm"),
                ("Nightwave Plaza", "https://radio.plaza.one/mp3", "Vaporwave", "Vaporwave, future funk, city pop", "https://plaza.one"),
                ("SomaFM — Groove Salad", "https://ice1.somafm.com/groovesalad-128-mp3", "Ambient / Downtempo", "Chilled ambient beats", "https://somafm.com/groovesalad"),
                ("SomaFM — DEF CON Radio", "https://ice1.somafm.com/defcon-256-mp3", "Electronic", "Music for hacking", "https://somafm.com/defcon"),
                ("SomaFM — Drone Zone", "https://ice1.somafm.com/dronezone-128-mp3", "Ambient", "Atmospheric ambient space music", "https://somafm.com/dronezone"),
            ]
            for _i, (_n, _u, _g, _d, _h) in enumerate(_featured):
                cursor.execute(
                    "INSERT INTO stations (name, url, genre, description, homepage, source, sort_order) "
                    "VALUES (%s, %s, %s, %s, %s, 'featured', %s) ON CONFLICT (url) DO NOTHING",
                    (_n, _u, _g, _d, _h, _i),
                )

        # Play tracking (drives the "most listened" carousel) + artwork backfill
        # for the featured stations (verified-live logo URLs). Idempotent.
        cursor.execute("ALTER TABLE stations ADD COLUMN IF NOT EXISTS play_count INTEGER DEFAULT 0")
        cursor.execute("ALTER TABLE stations ADD COLUMN IF NOT EXISTS last_played_at TIMESTAMP")
        _station_favicons = {
            "https://stream.nightride.fm/nightride.mp3": "https://nightride.fm/apple-touch-icon.png",
            "https://stream.nightride.fm/chillsynth.mp3": "https://nightride.fm/apple-touch-icon.png",
            "https://stream.nightride.fm/darksynth.mp3": "https://nightride.fm/apple-touch-icon.png",
            "https://ice1.somafm.com/groovesalad-128-mp3": "https://somafm.com/img3/groovesalad-400.jpg",
            "https://ice1.somafm.com/defcon-256-mp3": "https://somafm.com/img3/defcon-400.jpg",
            "https://ice1.somafm.com/dronezone-128-mp3": "https://somafm.com/img3/dronezone-400.jpg",
        }
        for _u, _fav in _station_favicons.items():
            cursor.execute(
                "UPDATE stations SET favicon = %s WHERE url = %s AND (favicon IS NULL OR favicon = '')",
                (_fav, _u),
            )

        # Per-feed play order: newest_first (default) or oldest_first.
        # Drives both episode list display AND the queue built on play/resume.
        cursor.execute(
            "ALTER TABLE rss_feeds ADD COLUMN IF NOT EXISTS play_order TEXT NOT NULL DEFAULT 'newest_first'"
        )

        # Per-episode last-progress timestamp. Updated on every progress
        # save (the 15-second timer from the player). Lets the resume
        # banner pick "the episode I was actually most recently
        # listening to" instead of "first episode in list order with
        # progress > 0" — which is what broke quick-resume when the
        # user has multiple in-progress episodes.
        cursor.execute(
            "ALTER TABLE rss_episodes ADD COLUMN IF NOT EXISTS last_played_at TIMESTAMP"
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_rss_episodes_last_played "
            "ON rss_episodes(last_played_at DESC NULLS LAST)"
        )

        # Per-feed intro/outro auto-skip. Seconds to jump forward when
        # an episode starts (skip sponsor reads) and seconds before end
        # to auto-advance (skip outros). 0 disables each side.
        cursor.execute(
            "ALTER TABLE rss_feeds ADD COLUMN IF NOT EXISTS intro_skip_seconds INTEGER DEFAULT 0"
        )
        cursor.execute(
            "ALTER TABLE rss_feeds ADD COLUMN IF NOT EXISTS outro_skip_seconds INTEGER DEFAULT 0"
        )

        # Per-feed retention: auto-delete played episodes older than N
        # days. 0 keeps everything. Applied by a periodic cleanup sweep.
        cursor.execute(
            "ALTER TABLE rss_feeds ADD COLUMN IF NOT EXISTS retention_days INTEGER DEFAULT 0"
        )

        # EBU R128 loudness columns. The existing `loudness` column holds
        # Essentia's Steven's-power-law value (arbitrary positive scale,
        # not LUFS) — kept for backward compat with rows already analyzed.
        # The new columns hold proper EBU R128 / ITU-R BS.1770 values:
        #   - integrated_loudness_lufs: long-term LUFS for normalization
        #     (typically -30 to -5, target is -14 for Spotify-style)
        #   - loudness_range_lu: dynamic range in LU
        #   - true_peak_dbfs: max signal level (negative dB; 0 = clipping)
        # NULL on rows analyzed before the upgrade — backfilled by the
        # next run of analyze_all_songs (resume query covers it).
        cursor.execute(
            "ALTER TABLE song_analysis ADD COLUMN IF NOT EXISTS integrated_loudness_lufs REAL"
        )
        cursor.execute(
            "ALTER TABLE song_analysis ADD COLUMN IF NOT EXISTS loudness_range_lu REAL"
        )
        cursor.execute(
            "ALTER TABLE song_analysis ADD COLUMN IF NOT EXISTS true_peak_dbfs REAL"
        )

        # Chapters live here (works for music too, unused until Phase 4).
        # Source enum: 'rss' (podcast:chapters), 'psc' (Podlove Simple
        # Chapters inline), 'id3' (CHAP/CTOC frames in audio file), 'manual'.
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS song_chapters (
                id                  SERIAL PRIMARY KEY,
                song_id             INTEGER NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
                order_index         INTEGER NOT NULL,
                start_time_seconds  INTEGER NOT NULL,
                end_time_seconds    INTEGER,
                title               TEXT,
                image_url           TEXT,
                link_url            TEXT,
                is_skippable        BOOLEAN DEFAULT FALSE,
                source              TEXT,
                UNIQUE(song_id, order_index)
            )
            """
        )
        cursor.execute(
            "CREATE INDEX IF NOT EXISTS idx_song_chapters_song ON song_chapters(song_id)"
        )

        conn.commit()
        conn.close()
        Database._initialized = True
        print(f"✅ Database initialized successfully! "
              f"({cursor.ran} statements run, {cursor.skipped} already in place)")
