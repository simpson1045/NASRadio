"""Keep this server's in-app update files current from GitHub releases.

The app asks its own server for updates (/api/update/check reads
updates/version.json), but nothing used to fill that folder, so a stock
install never offered an update. With UPDATE_SOURCE=github (the default) this
polls the latest *stable* GitHub release every few hours and, when it is newer
than what's here, downloads the APK, Windows zip, macOS zip and release notes into
updates/. UPDATE_SOURCE=manual leaves the folder alone, for a server whose
update files are placed by hand (e.g. a beta channel).
"""
import json
import os

import eventlet
import requests

UPDATE_SOURCE = os.environ.get("UPDATE_SOURCE", "github").strip().lower()
UPDATE_GITHUB_REPO = os.environ.get("UPDATE_GITHUB_REPO", "simpson1045/NASRadio").strip()
CHECK_INTERVAL_S = 6 * 3600
FIRST_CHECK_DELAY_S = 90

_BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPDATES_DIR = os.path.join(_BASE_DIR, "updates")
_UA = {"User-Agent": "NASRadio-update-fetcher"}
_ARTIFACTS = {
    "nasradio-android.apk": "android_size",
    "nasradio-windows.zip": "windows_size",
    "nasradio-macos.zip": "macos_size",
    "nasradio-linux.tar.xz": "linux_size",
}


def _local_build(updates_dir):
    try:
        with open(os.path.join(updates_dir, "version.json"), encoding="utf-8-sig") as f:
            return int(json.load(f).get("build_number") or 0)
    except (OSError, ValueError):
        return 0


def _download(url, dest, expected_size=None):
    """Download to dest + '.part' and return that path (renamed later)."""
    tmp = dest + ".part"
    with requests.get(url, headers=_UA, stream=True, timeout=60) as r:
        r.raise_for_status()
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
    if expected_size and os.path.getsize(tmp) != expected_size:
        os.remove(tmp)
        raise ValueError(f"{os.path.basename(dest)}: size mismatch")
    return tmp


def sync_once(updates_dir=UPDATES_DIR, repo=UPDATE_GITHUB_REPO):
    """One check against GitHub. Returns a short status line."""
    r = requests.get(
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers={**_UA, "Accept": "application/vnd.github+json"},
        timeout=20,
    )
    r.raise_for_status()
    release = r.json()
    tag = release.get("tag_name", "")
    assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
    if "version.json" not in assets:
        return f"{tag}: release has no version.json"

    v = requests.get(assets["version.json"], headers=_UA, timeout=20)
    v.raise_for_status()
    info = v.json()
    remote_build = int(info.get("build_number") or 0)
    local_build = _local_build(updates_dir)
    if remote_build <= local_build:
        return f"up to date (build {local_build}; GitHub {tag} is build {remote_build})"

    os.makedirs(updates_dir, exist_ok=True)
    staged = []  # (temp path, final name); version.json goes last
    try:
        for name, size_key in _ARTIFACTS.items():
            if name in assets:
                tmp = _download(assets[name], os.path.join(updates_dir, name), info.get(size_key))
                staged.append((tmp, name))
        notes = requests.get(
            f"https://raw.githubusercontent.com/{repo}/{tag}/CHANGELOG.md", headers=_UA, timeout=20)
        if notes.ok:
            tmp = os.path.join(updates_dir, "CHANGELOG.md.part")
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(notes.text)
            staged.append((tmp, "CHANGELOG.md"))
        tmp = os.path.join(updates_dir, "version.json.part")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(info, f, indent=2)
        staged.append((tmp, "version.json"))
    except Exception:
        for tmp, _ in staged:
            try:
                os.remove(tmp)
            except OSError:
                pass
        raise

    # Files first, version.json last: the app is only offered the update once
    # everything it will download is in place.
    for tmp, name in staged:
        os.replace(tmp, os.path.join(updates_dir, name))
    return f"updated to {info.get('version')} (build {remote_build}) from {tag}"


def start_update_fetcher():
    if UPDATE_SOURCE != "github":
        print(f"📦 Update files: manual (UPDATE_SOURCE={UPDATE_SOURCE}), not polling GitHub")
        return

    def loop():
        eventlet.sleep(FIRST_CHECK_DELAY_S)
        while True:
            try:
                print(f"📦 [updates] {sync_once()}", flush=True)
            except Exception as e:
                print(f"⚠️ [updates] GitHub check failed: {e}", flush=True)
            eventlet.sleep(CHECK_INTERVAL_S)

    eventlet.spawn_n(loop)
    print(f"📦 Update files: from GitHub releases of {UPDATE_GITHUB_REPO}, checked every 6 h")
