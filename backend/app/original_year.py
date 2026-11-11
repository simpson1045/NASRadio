"""Original release year per album, from MusicBrainz release groups.

albums.year is whatever the files are tagged with, so a 2014 deluxe reissue
of Reckless reads 2014. Its release group ("Reckless" across every edition)
carries first-release-date 1984-10-29. This fills albums.original_year for
albums that have a release_group_mbid, slowly in the background (MusicBrainz
allows about one request a second; _mb_get keeps that spacing), and the cast
receiver shows it instead of the tagged year.

Each album is looked up once (original_year_checked_at); albums added later,
or given a release group later, are picked up on the next pass.
"""
import eventlet

from app.genre_fetcher import _mb_get

BATCH = 25
FIRST_DELAY_S = 180
IDLE_SLEEP_S = 6 * 3600


def _year(date_str):
    try:
        y = int((date_str or "")[:4])
    except ValueError:
        return None
    return y if 1000 < y < 3000 else None


def fill_batch(db, limit=BATCH):
    """Look up to `limit` unchecked albums. Returns (found, written)."""
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            """SELECT id, release_group_mbid FROM albums
               WHERE release_group_mbid IS NOT NULL AND release_group_mbid <> ''
                 AND original_year_checked_at IS NULL
               ORDER BY id LIMIT %s""", (limit,))
        rows = cur.fetchall()
    finally:
        conn.close()

    written = 0
    for r in rows:
        status, rg = _mb_get(f"release-group/{r['release_group_mbid']}")
        if status == 200:
            year = _year(rg.get("first-release-date"))
        elif status == 404:
            year = None  # stale id: mark checked, keep the tagged year
        else:
            continue     # MusicBrainz busy or down: try again next pass
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute(
                "UPDATE albums SET original_year = %s, original_year_checked_at = NOW() WHERE id = %s",
                (year, r["id"]))
            conn.commit()
        finally:
            conn.close()
        written += 1
    return len(rows), written


def start_original_year_filler():
    def loop():
        eventlet.sleep(FIRST_DELAY_S)
        from app.config import Config
        from app.models import Database
        db = Database(Config.DATABASE_URL)
        total = 0
        while True:
            try:
                found, written = fill_batch(db)
            except Exception as e:
                print(f"⚠️ [original-year] {e}", flush=True)
                found, written = 0, 0
            total += written
            if found:
                if total and total % 250 < written:
                    print(f"📅 [original-year] {total} albums checked so far", flush=True)
                eventlet.sleep(1)
                continue
            if total:
                print(f"📅 [original-year] caught up ({total} albums checked this run)", flush=True)
                total = 0
            eventlet.sleep(IDLE_SLEEP_S)

    eventlet.spawn_n(loop)
    print("📅 Original-year filler started (MusicBrainz release groups)")
