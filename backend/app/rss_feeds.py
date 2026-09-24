"""RSS podcast feed parsing, refreshing, and episode management."""

import os
import re
import time
import ipaddress
import feedparser
import requests
from urllib.parse import urlparse
from datetime import datetime
from email.utils import parsedate_to_datetime


def _validate_url(url):
    """Validate a URL is safe to fetch (prevent SSRF attacks).

    Only allows http/https schemes and blocks private/loopback IPs.
    Returns True if safe, raises ValueError if not.
    """
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"URL scheme '{parsed.scheme}' not allowed — only http/https")
    hostname = parsed.hostname
    if not hostname:
        raise ValueError("URL has no hostname")
    # Block obvious local targets
    try:
        ip = ipaddress.ip_address(hostname)
        if ip.is_private or ip.is_loopback or ip.is_reserved:
            raise ValueError(f"URL points to private/local address: {hostname}")
    except ValueError as e:
        if "private" in str(e) or "local" in str(e):
            raise
        # Not an IP — it's a hostname, which is fine
    return True


# Maximum download size: 500 MB
MAX_DOWNLOAD_SIZE = 500 * 1024 * 1024


def resolve_audio_url(url, timeout=10):
    """Chase redirects from a podcast audio URL to the final CDN location.

    Podcast distributors wrap episode URLs in tracking redirects
    (Podtrac, Chartable, Megaphone, etc.) — every hop = DNS + TCP + TLS
    + HTTP round trip, which is why first-play latency is 5-10s. If we
    resolve once server-side and cache the final URL, resumes go
    straight to the CDN at ~500ms. IAB Measurement Guidelines dedupe
    downloads by IP+UA/day so the first play still counts; subsequent
    resumes don't re-ring the tracker chain — which is how every major
    podcast app (Overcast, Pocket Casts, Castro, Apple Podcasts) works.

    Returns (final_url, expires_at) where expires_at is a datetime or
    None. Raises on network error or if any URL in the chain is unsafe.

    Strategy: HEAD first (cheap, servers usually honor it). If HEAD
    fails (405 Method Not Allowed is common for some CDNs), fall back
    to GET with stream=True and close the connection as soon as the
    final URL is known.
    """
    _validate_url(url)

    try:
        response = requests.head(url, allow_redirects=True, timeout=timeout)
        if response.status_code == 405 or response.status_code >= 400:
            raise requests.RequestException(f"HEAD returned {response.status_code}")
    except requests.RequestException:
        # Fallback: GET with streaming, close immediately after we have the final URL.
        response = requests.get(url, allow_redirects=True, stream=True, timeout=timeout)
        response.close()

    final_url = response.url
    _validate_url(final_url)  # Redirected target must also be safe (SSRF guard)

    expires_at = _extract_expiry(response, final_url)
    return final_url, expires_at


def _extract_expiry(response, final_url):
    """Best-effort extraction of when a resolved CDN URL stops working.

    Checks (in order): signed-URL Expires query param (AWS/CloudFront
    convention), Expires header, Cache-Control max-age header. Returns
    a datetime or None if nothing reliable is parseable.
    """
    from datetime import timedelta

    # 1. Signed URL with ?Expires=<unix timestamp> (AWS/CloudFront)
    try:
        parsed = urlparse(final_url)
        if parsed.query:
            from urllib.parse import parse_qs
            params = parse_qs(parsed.query)
            if "Expires" in params:
                return datetime.utcfromtimestamp(int(params["Expires"][0]))
    except (ValueError, TypeError, KeyError):
        pass

    # 2. Expires header (HTTP/1.0 style, still widely used)
    expires_header = response.headers.get("Expires")
    if expires_header:
        try:
            return parsedate_to_datetime(expires_header).replace(tzinfo=None)
        except (TypeError, ValueError):
            pass

    # 3. Cache-Control: max-age=N
    cache_control = response.headers.get("Cache-Control", "")
    m = re.search(r"max-age=(\d+)", cache_control)
    if m:
        try:
            seconds = int(m.group(1))
            return datetime.utcnow() + timedelta(seconds=seconds)
        except (ValueError, TypeError):
            pass

    return None


def parse_feed(feed_url):
    """Fetch and parse an RSS feed, returning normalized feed + episodes.

    Returns:
        dict with keys: title, description, artwork_url, author, link, episodes[]
        Each episode has: guid, title, description, audio_url, audio_type,
        audio_duration, audio_size, link, published_at, artwork_url
    """
    _validate_url(feed_url)

    # Fetch with requests (certifi CA bundle) and hand the bytes to feedparser,
    # rather than letting feedparser do its own fetch. feedparser uses Python's
    # default SSL trust store, which on this box builds some Let's Encrypt
    # chains through an expired root and wrongly rejects them as "certificate
    # has expired" — even though the cert is valid and requests/curl accept it
    # (this is exactly what killed the A State of Trance feed: miroppb.com).
    # Falls back to feedparser's own fetch if the HTTP request itself fails.
    try:
        resp = requests.get(
            feed_url,
            timeout=20,
            headers={"User-Agent": "NASRadio/1.0 (podcast feed reader)"},
            allow_redirects=True,
        )
        resp.raise_for_status()
        feed = feedparser.parse(resp.content)
    except requests.RequestException as e:
        print(f"  ↳ requests fetch failed for {feed_url} ({e}); "
              "falling back to feedparser direct fetch")
        feed = feedparser.parse(feed_url)

    if feed.bozo and not feed.entries:
        raise ValueError(f"Failed to parse feed: {feed.bozo_exception}")

    # Feed metadata
    channel = feed.feed
    artwork_url = None

    # Try itunes:image first, then standard image
    if hasattr(channel, "image") and hasattr(channel.image, "href"):
        artwork_url = channel.image.href
    elif "image" in channel and isinstance(channel.image, dict):
        artwork_url = channel.image.get("href")

    # itunes:image is more reliable for podcasts
    itunes_image = channel.get("itunes_image")
    if itunes_image:
        artwork_url = itunes_image.get("href", artwork_url)

    # Try Apple Podcasts for higher-res artwork (RSS feeds often have tiny images)
    title = channel.get("title", "")
    if artwork_url and title:
        hires = _get_apple_hires_artwork(title, artwork_url)
        if hires:
            artwork_url = hires

    result = {
        "title": title or "Unknown Podcast",
        "description": _clean_html(channel.get("summary") or channel.get("subtitle", "")),
        "artwork_url": artwork_url,
        "author": channel.get("author") or channel.get("itunes_author", ""),
        "link": channel.get("link", ""),
        "episodes": [],
    }

    for entry in feed.entries:
        episode = _parse_episode(entry)
        if episode:
            result["episodes"].append(episode)

    return result


def _parse_episode(entry):
    """Parse a single feed entry into an episode dict."""
    # Get audio enclosure
    audio_url = None
    audio_type = None
    audio_size = None

    for enclosure in entry.get("enclosures", []):
        enc_type = enclosure.get("type", "")
        if enc_type.startswith("audio/") or enc_type == "":
            audio_url = enclosure.get("href") or enclosure.get("url")
            audio_type = enc_type or "audio/mpeg"
            try:
                audio_size = int(enclosure.get("length", 0)) or None
            except (ValueError, TypeError):
                audio_size = None
            break

    # Also check media:content
    if not audio_url:
        for media in entry.get("media_content", []):
            if media.get("type", "").startswith("audio/"):
                audio_url = media.get("url")
                audio_type = media.get("type")
                break

    # Skip entries without audio (not a podcast episode)
    if not audio_url:
        return None

    # Parse duration from itunes:duration (can be HH:MM:SS, MM:SS, or seconds)
    duration = None
    raw_duration = entry.get("itunes_duration")
    if raw_duration:
        duration = _parse_duration(raw_duration)

    # Parse published date
    published_at = None
    if entry.get("published_parsed"):
        try:
            published_at = datetime(*entry.published_parsed[:6])
        except (TypeError, ValueError):
            pass

    if not published_at and entry.get("published"):
        try:
            published_at = parsedate_to_datetime(entry.published)
        except (TypeError, ValueError):
            pass

    # Episode-specific artwork
    episode_artwork = None
    itunes_image = entry.get("itunes_image")
    if itunes_image:
        episode_artwork = itunes_image.get("href")
    elif entry.get("image"):
        episode_artwork = entry.image.get("href")

    # GUID — use id, then link, then audio URL as fallback
    guid = entry.get("id") or entry.get("link") or audio_url

    return {
        "guid": guid,
        "title": entry.get("title", "Untitled Episode"),
        "description": _clean_html(entry.get("summary") or entry.get("subtitle", "")),
        "audio_url": audio_url,
        "audio_type": audio_type,
        "audio_duration": duration,
        "audio_size": audio_size,
        "link": entry.get("link"),
        "published_at": published_at,
        "artwork_url": episode_artwork,
    }


def _parse_duration(raw):
    """Parse itunes:duration which can be HH:MM:SS, MM:SS, or raw seconds."""
    if not raw:
        return None
    raw = str(raw).strip()

    # Already seconds
    if raw.isdigit():
        return int(raw)

    # HH:MM:SS or MM:SS
    parts = raw.split(":")
    try:
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
        elif len(parts) == 2:
            return int(parts[0]) * 60 + int(parts[1])
    except (ValueError, TypeError):
        pass

    return None


def _get_apple_hires_artwork(title, rss_artwork_url):
    """Look up Apple Podcasts for a higher-res artwork URL.

    RSS feeds often serve tiny images (256px). Apple Podcasts usually has
    1400x1400 versions. Returns a high-res URL or None.
    """
    try:
        resp = requests.get(
            "https://itunes.apple.com/search",
            params={"term": title, "media": "podcast", "limit": 3},
            timeout=5,
        )
        if resp.status_code != 200:
            return None
        results = resp.json().get("results", [])
        # Match by title (case-insensitive)
        title_lower = title.lower().strip()
        for r in results:
            name = (r.get("collectionName") or "").lower().strip()
            if name == title_lower or title_lower in name or name in title_lower:
                url600 = r.get("artworkUrl600")
                if url600:
                    # Replace 600x600 with 1400x1400 for max quality
                    return url600.replace("600x600bb", "1400x1400bb")
        return None
    except Exception as e:
        print(f"Apple artwork lookup failed for '{title}': {e}")
        return None


def _clean_html(text):
    """Strip HTML tags from text, keeping it readable."""
    if not text:
        return ""
    # Remove HTML tags
    clean = re.sub(r"<[^>]+>", "", text)
    # Collapse whitespace
    clean = re.sub(r"\s+", " ", clean).strip()
    return clean


def refresh_feed(db, feed_id):
    """Refresh a single feed — fetch new episodes and update metadata.

    Returns the number of new episodes added.
    """
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT * FROM rss_feeds WHERE id = %s", (feed_id,))
        feed_row = cursor.fetchone()
        if not feed_row:
            return 0

        parsed = parse_feed(feed_row["feed_url"])
        new_count = 0

        # Update feed metadata
        cursor.execute(
            """UPDATE rss_feeds
               SET title = %s, description = %s, artwork_url = %s,
                   author = %s, link = %s, last_fetched_at = NOW()
               WHERE id = %s""",
            (
                parsed["title"],
                parsed["description"],
                parsed["artwork_url"],
                parsed["author"],
                parsed["link"],
                feed_id,
            ),
        )

        # Insert new episodes (skip duplicates by guid)
        for ep in parsed["episodes"]:
            cursor.execute(
                """INSERT INTO rss_episodes
                   (feed_id, guid, title, description, audio_url, audio_type,
                    audio_duration, audio_size, link, published_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (feed_id, guid) DO NOTHING""",
                (
                    feed_id,
                    ep["guid"],
                    ep["title"],
                    ep["description"],
                    ep["audio_url"],
                    ep["audio_type"],
                    ep["audio_duration"],
                    ep["audio_size"],
                    ep["link"],
                    ep["published_at"],
                ),
            )
            if cursor.rowcount > 0:
                new_count += 1

        conn.commit()
    except Exception as e:
        conn.rollback()
        print(f"Error refreshing feed {feed_id}: {e}")
        return 0
    finally:
        conn.close()

    # Mirror newly-added rss_episodes into songs (source_type='podcast')
    # and trigger async URL resolution so first-play is sub-second.
    # Wrapped defensively — the feed itself already updated successfully
    # and we don't want the mirror step to mask that.
    if new_count > 0:
        try:
            mirrored = sync_feed_to_songs(db, feed_id, resolve_urls=True)
            if mirrored:
                print(f"[refresh_feed] Feed {feed_id}: mirrored {mirrored} new episode(s) to songs")
        except Exception as e:
            print(f"[refresh_feed] Feed {feed_id}: sync_feed_to_songs failed: {e}")

    # Re-probe recent chapterless episodes. Some producers (e.g. miroppb /
    # A State of Trance) embed ID3 chapter markers a day or two AFTER they
    # publish the episode — so the newest episode plays fine but has no
    # chapters yet. Runs every refresh (not just when new episodes arrive) so
    # those chapters get pulled in automatically once the producer adds them,
    # without the user needing to replay. Bounded to recent episodes so feeds
    # that never embed chapters aren't probed forever.
    try:
        got = retry_missing_chapters(db, feed_id)
        if got:
            print(f"[refresh_feed] Feed {feed_id}: filled chapters for {got} episode(s)")
    except Exception as e:
        print(f"[refresh_feed] Feed {feed_id}: chapter retry failed: {e}")

    return new_count


def retry_missing_chapters(db, feed_id, limit=5, max_age_days=10):
    """Re-fetch chapters for the newest still-chapterless episodes of a feed.

    Producers often add ID3 CHAP markers after publishing, so an episode can
    go from 0 chapters to a full tracklist a day or two later. This re-checks
    only the newest `limit` episodes published within `max_age_days` (so a feed
    that simply never embeds chapters isn't re-probed indefinitely). Each call
    to ensure_chapters_for_song is a cheap ID3-tag range request and is a no-op
    once chapters exist. Returns the number of episodes that gained chapters.
    """
    from app.chapters import ensure_chapters_for_song

    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            f"""
            SELECT s.id
              FROM songs s
              JOIN rss_episodes e ON e.id = s.podcast_episode_id
             WHERE s.podcast_feed_id = %s
               AND s.source_type = 'podcast'
               AND e.published_at IS NOT NULL
               AND e.published_at > NOW() - INTERVAL '{int(max_age_days)} days'
               AND NOT EXISTS (
                   SELECT 1 FROM song_chapters c WHERE c.song_id = s.id
               )
             ORDER BY e.published_at DESC
             LIMIT %s
            """,
            (feed_id, limit),
        )
        song_ids = [r["id"] for r in cursor.fetchall()]
    finally:
        conn.close()

    filled = 0
    for sid in song_ids:
        try:
            if ensure_chapters_for_song(db, sid) > 0:
                filled += 1
        except Exception as e:
            print(f"[chapters] retry for song {sid} failed: {e}")
    return filled


def apply_retention_policy(db, feed_id=None):
    """Delete completed episodes older than each feed's retention_days.

    Runs per-feed. Only touches episodes where:
      - is_completed = 1 (never prune unplayed)
      - published_at < NOW() - retention_days
      - the feed has retention_days > 0 (0 means "keep forever")

    If `feed_id` is supplied, only that feed's episodes are considered;
    otherwise all feeds with retention configured are swept. Returns the
    total number of episodes deleted.

    Note: the ON DELETE CASCADE from songs.podcast_episode_id to
    rss_episodes keeps the `songs` mirror rows in sync automatically.
    """
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    total_deleted = 0
    try:
        if feed_id is not None:
            cursor.execute(
                "SELECT id, retention_days FROM rss_feeds "
                "WHERE id = %s AND retention_days > 0",
                (feed_id,),
            )
        else:
            cursor.execute(
                "SELECT id, retention_days FROM rss_feeds WHERE retention_days > 0"
            )
        feeds = cursor.fetchall()

        for feed in feeds:
            days = int(feed["retention_days"])
            # Keep downloaded files on disk — just delete the DB rows. If
            # the user wants to re-add them later, a feed refresh will
            # re-insert from the RSS. (Also keeps local file cleanup a
            # separate, reversible operation that we might want toggled
            # independently later.)
            cursor.execute(
                f"""
                DELETE FROM rss_episodes
                 WHERE feed_id = %s
                   AND is_completed = 1
                   AND published_at IS NOT NULL
                   AND published_at < NOW() - INTERVAL '{days} days'
                """,
                (feed["id"],),
            )
            deleted = cursor.rowcount
            total_deleted += deleted
            if deleted:
                print(f"[retention] Feed {feed['id']}: pruned {deleted} completed "
                      f"episode(s) older than {days} days")
        conn.commit()
    except Exception as e:
        conn.rollback()
        print(f"[retention] sweep failed: {e}")
    finally:
        conn.close()
    return total_deleted


def refresh_all_feeds(db):
    """Refresh all subscribed feeds. Returns total new episodes."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT id FROM rss_feeds")
        feed_ids = [row["id"] for row in cursor.fetchall()]
    finally:
        conn.close()

    total_new = 0
    for feed_id in feed_ids:
        total_new += refresh_feed(db, feed_id)

    # Retention sweep: prune completed episodes older than per-feed
    # retention_days. Runs after the refresh so any episodes freshly
    # marked completed in this cycle aren't scoped out by a stale read.
    # Failure is logged inside apply_retention_policy — we don't want
    # a prune error to mask a successful refresh.
    try:
        apply_retention_policy(db)
    except Exception as e:
        print(f"[retention] hook after refresh_all_feeds failed: {e}")

    return total_new


def sync_feed_to_songs(db, feed_id, resolve_urls=True):
    """Mirror rss_episodes for a given feed into songs (source_type='podcast').

    Called after refresh_feed() inserts new episodes, and as part of the
    one-shot backfill. Idempotent — existing song rows are left alone,
    only new rss_episodes without a corresponding songs row get mirrored.

    When resolve_urls=True, each newly inserted song gets its resolved_url
    filled in a background greenthread (via eventlet.spawn_n) so the user
    gets sub-second playback latency on first play. Pass False from batch
    backfill scripts where we control concurrency differently.

    Returns the number of songs rows inserted.
    """
    import eventlet

    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    inserted_song_ids = []
    try:
        cursor.execute("SELECT * FROM rss_feeds WHERE id = %s", (feed_id,))
        feed = cursor.fetchone()
        if not feed:
            return 0

        author = (feed.get("custom_author") or feed.get("author") or feed.get("title") or "Unknown Podcast").strip()
        album_title = (feed.get("title") or "Unknown Podcast").strip()
        artwork_url = feed.get("artwork_url")

        # Artist
        cursor.execute("SELECT id FROM artists WHERE LOWER(name) = LOWER(%s) LIMIT 1", (author,))
        r = cursor.fetchone()
        artist_id = r["id"] if r else None
        if artist_id is None:
            cursor.execute("INSERT INTO artists (name) VALUES (%s) RETURNING id", (author,))
            artist_id = cursor.fetchone()["id"]
            try:
                from app.artist_image_downloader import fetch_artist_image_async
                fetch_artist_image_async(artist_id, author)
            except Exception as e:
                print(f"  artist image fetch not started: {e}")

        # Album
        cursor.execute(
            "SELECT id FROM albums WHERE artist_id = %s AND LOWER(title) = LOWER(%s) LIMIT 1",
            (artist_id, album_title),
        )
        r = cursor.fetchone()
        album_id = r["id"] if r else None
        if album_id is None:
            cursor.execute(
                "INSERT INTO albums (artist_id, title, artwork_path) VALUES (%s, %s, %s) RETURNING id",
                (artist_id, album_title, artwork_url),
            )
            album_id = cursor.fetchone()["id"]

        # Episodes missing from songs
        cursor.execute(
            """
            SELECT e.* FROM rss_episodes e
            LEFT JOIN songs s ON s.podcast_episode_id = e.id
            WHERE e.feed_id = %s AND s.id IS NULL AND e.audio_url IS NOT NULL
            ORDER BY e.published_at ASC
            """,
            (feed_id,),
        )
        missing = cursor.fetchall()

        for ep in missing:
            try:
                cursor.execute(
                    """
                    INSERT INTO songs (
                        title, artist_id, album_id, duration, file_path,
                        source_type, podcast_feed_id, podcast_episode_id, source_url,
                        played_position, is_completed, created_at
                    )
                    VALUES (%s, %s, %s, %s, %s, 'podcast', %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (file_path) DO NOTHING
                    RETURNING id
                    """,
                    (
                        ep["title"],
                        artist_id,
                        album_id,
                        ep.get("audio_duration"),
                        ep["audio_url"],
                        feed_id,
                        ep["id"],
                        ep["audio_url"],
                        ep.get("played_position") or 0,
                        ep.get("is_completed") or 0,
                        ep.get("published_at"),
                    ),
                )
                new_row = cursor.fetchone()
                if new_row:
                    inserted_song_ids.append(new_row["id"])
            except Exception as ex:
                print(f"[sync_feed_to_songs] Feed {feed_id} ep {ep['id']}: {ex}")

        conn.commit()
    except Exception as e:
        conn.rollback()
        print(f"[sync_feed_to_songs] Feed {feed_id}: {e}")
        raise
    finally:
        conn.close()

    # Kick off async URL resolution for each new episode.
    if resolve_urls and inserted_song_ids:
        for song_id in inserted_song_ids:
            eventlet.spawn_n(_resolve_song_url_async, db, song_id)

    return len(inserted_song_ids)


def _resolve_song_url_async(db, song_id):
    """Resolve a single podcast song's URL and persist. Safe to run in a greenthread."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT source_url, file_path FROM songs WHERE id = %s AND resolved_url IS NULL",
            (song_id,),
        )
        row = cursor.fetchone()
        if not row:
            return
        source = row.get("source_url") or row.get("file_path")
        if not source:
            return
        try:
            final_url, expires = resolve_audio_url(source)
        except Exception as e:
            print(f"[resolve bg] Song {song_id}: {e}")
            return
        cursor.execute(
            """
            UPDATE songs
               SET resolved_url = %s,
                   resolved_url_expires_at = %s,
                   source_url = COALESCE(source_url, %s)
             WHERE id = %s
            """,
            (final_url, expires, source, song_id),
        )
        conn.commit()
    except Exception as e:
        conn.rollback()
        print(f"[resolve bg] Song {song_id}: {e}")
    finally:
        conn.close()


def download_episode(db, episode_id, download_dir, progress_cb=None):
    """Download a podcast episode audio file to the NAS.

    Saves to: {download_dir}/{feed_title}/{episode_title}.{ext}
    Updates downloaded_path in the database.

    progress_cb(downloaded_bytes, total_bytes) is called every ~1 MB so the UI
    can show download progress (caller passes a websocket-emit lambda).
    """
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """SELECT e.*, f.title as feed_title
               FROM rss_episodes e
               JOIN rss_feeds f ON e.feed_id = f.id
               WHERE e.id = %s""",
            (episode_id,),
        )
        episode = cursor.fetchone()
        if not episode or not episode["audio_url"]:
            return None

        # Idempotent: if it's already downloaded and the file is still on disk,
        # don't re-fetch. Lets download-on-play fire blindly every time.
        existing = episode.get("downloaded_path")
        if existing and os.path.exists(existing):
            return existing

        # Validate audio URL before downloading
        _validate_url(episode["audio_url"])

        # Build safe folder and filename — strip path separators and traversal
        feed_folder = re.sub(r'[<>:"/\\|?*.]', "", episode["feed_title"] or "Unknown Podcast").strip()
        safe_title = re.sub(r'[<>:"/\\|?*.]', "", episode["title"] or "episode").strip()
        # Extra safety: use basename to prevent any remaining traversal
        feed_folder = os.path.basename(feed_folder) or "Unknown Podcast"
        safe_title = os.path.basename(safe_title) or "episode"

        # Get file extension from URL or content type
        ext = "mp3"
        if episode["audio_type"]:
            type_map = {"audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac",
                        "audio/ogg": "ogg", "audio/opus": "opus", "audio/x-m4a": "m4a"}
            ext = type_map.get(episode["audio_type"], "mp3")

        folder_path = os.path.join(download_dir, feed_folder)
        # Verify resolved path stays within download_dir
        real_folder = os.path.realpath(folder_path)
        real_download_dir = os.path.realpath(download_dir)
        if not real_folder.startswith(real_download_dir):
            raise ValueError(f"Path traversal blocked: {folder_path}")

        os.makedirs(folder_path, exist_ok=True)
        file_path = os.path.join(folder_path, f"{safe_title}.{ext}")

        # Stream download with size limit
        response = requests.get(episode["audio_url"], stream=True, timeout=30)
        response.raise_for_status()

        # Check Content-Length if available
        content_length = response.headers.get("Content-Length")
        if content_length and int(content_length) > MAX_DOWNLOAD_SIZE:
            raise ValueError(f"File too large: {int(content_length)} bytes (max {MAX_DOWNLOAD_SIZE})")

        downloaded = 0
        total = int(content_length) if content_length else 0
        last_emit = 0
        with open(file_path, "wb") as f:
            for chunk in response.iter_content(chunk_size=8192):
                downloaded += len(chunk)
                if downloaded > MAX_DOWNLOAD_SIZE:
                    f.close()
                    os.remove(file_path)
                    raise ValueError(f"Download exceeded {MAX_DOWNLOAD_SIZE} bytes limit")
                f.write(chunk)
                # Report progress ~every 1 MB so the UI has a live signal.
                if progress_cb and total and downloaded - last_emit >= 1024 * 1024:
                    last_emit = downloaded
                    try:
                        progress_cb(downloaded, total)
                    except Exception:
                        pass

        # Final 100% tick so the UI can clear the indicator cleanly.
        if progress_cb and total:
            try:
                progress_cb(total, total)
            except Exception:
                pass

        # Update database
        cursor.execute(
            "UPDATE rss_episodes SET downloaded_path = %s WHERE id = %s",
            (file_path, episode_id),
        )
        conn.commit()

        print(f"Downloaded episode: {file_path}")
        return file_path

    except Exception as e:
        conn.rollback()
        print(f"Error downloading episode {episode_id}: {e}")
        return None
    finally:
        conn.close()


def delete_episode_download(db, episode_id):
    """Delete a downloaded episode file from the NAS and clear downloaded_path.
    Safe + idempotent — used when an episode is marked completed."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT downloaded_path FROM rss_episodes WHERE id = %s", (episode_id,)
        )
        row = cursor.fetchone()
        path = row.get("downloaded_path") if row else None
        if not path:
            return
        if os.path.exists(path):
            try:
                os.remove(path)
                print(f"🧹 [podcast] removed completed download: {path}")
            except OSError as e:
                print(f"[podcast cleanup] could not remove {path}: {e}")
        cursor.execute(
            "UPDATE rss_episodes SET downloaded_path = NULL WHERE id = %s", (episode_id,)
        )
        conn.commit()
    except Exception as e:
        conn.rollback()
        print(f"[podcast cleanup] delete download failed for {episode_id}: {e}")
    finally:
        conn.close()


def cleanup_podcast_downloads(db, cap_bytes=5 * 1024 * 1024 * 1024):
    """Bound podcast download storage. (1) Drop downloads for completed
    episodes (belt-and-suspenders for the on-completion delete). (2) If the
    total still exceeds cap_bytes, evict the least-recently-played downloads
    until under the cap. Runs periodically so abandoned half-listens can't
    pile up. Returns (completed_removed, evicted_for_cap)."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    completed_removed = 0
    evicted = 0
    try:
        # 1. Completed episodes — their downloads are dead weight.
        cursor.execute(
            "SELECT id, downloaded_path FROM rss_episodes "
            "WHERE is_completed = 1 AND downloaded_path IS NOT NULL"
        )
        for row in cursor.fetchall():
            p = row.get("downloaded_path")
            if p and os.path.exists(p):
                try:
                    os.remove(p)
                except OSError:
                    pass
            cursor.execute(
                "UPDATE rss_episodes SET downloaded_path = NULL WHERE id = %s",
                (row["id"],),
            )
            completed_removed += 1
        conn.commit()

        # 2. Size cap — evict oldest-played downloads until under cap.
        cursor.execute(
            "SELECT id, downloaded_path FROM rss_episodes "
            "WHERE downloaded_path IS NOT NULL "
            "ORDER BY last_played_at ASC NULLS FIRST"
        )
        sized = []
        total = 0
        for row in cursor.fetchall():
            p = row.get("downloaded_path")
            if p and os.path.exists(p):
                try:
                    sz = os.path.getsize(p)
                except OSError:
                    sz = 0
                sized.append((row["id"], p, sz))
                total += sz
        for ep_id, p, sz in sized:
            if total <= cap_bytes:
                break
            try:
                os.remove(p)
            except OSError:
                pass
            cursor.execute(
                "UPDATE rss_episodes SET downloaded_path = NULL WHERE id = %s",
                (ep_id,),
            )
            total -= sz
            evicted += 1
        conn.commit()
        if completed_removed or evicted:
            print(
                f"🧹 [podcast] cleanup: {completed_removed} completed, "
                f"{evicted} evicted for cap"
            )
    except Exception as e:
        conn.rollback()
        print(f"[podcast cleanup] sweep failed: {e}")
    finally:
        conn.close()
    return completed_removed, evicted
