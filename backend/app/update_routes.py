from flask import Blueprint, jsonify, send_file, abort, request
import os
import json
import re

update_api = Blueprint("update_api", __name__)

# Base directory for the backend (parent of app/)
_BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_UPDATES_DIR = os.path.join(_BASE_DIR, "updates")
_CHANGELOG_PATH = os.path.join(os.path.dirname(_BASE_DIR), "CHANGELOG.md")


def _read_version_json():
    """Read and return parsed version.json.

    Uses utf-8-sig to tolerate a UTF-8 BOM (PowerShell's default UTF8
    encoding on Windows writes one, and json.load chokes on it).
    """
    path = os.path.join(_UPDATES_DIR, "version.json")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def _parse_latest_changelog():
    """Parse the first section from CHANGELOG.md and return it as markdown text.

    utf-8-sig tolerates a BOM; without it, a leading BOM prevents the
    regex from matching '## ' at position 0 and we'd return the wrong
    section (next one down).
    """
    if not os.path.exists(_CHANGELOG_PATH):
        return ""
    with open(_CHANGELOG_PATH, "r", encoding="utf-8-sig") as f:
        content = f.read()

    # Split on ## headers, take the first section
    sections = re.split(r"(?=^## )", content, flags=re.MULTILINE)
    for section in sections:
        section = section.strip()
        if section.startswith("## "):
            return section
    return ""


def _parse_changelog_since(since_build):
    """Return EVERY changelog section newer than the user's installed build,
    concatenated newest-first — so someone updating from an old version sees all
    the changes in between, not just the latest version's notes.

    CHANGELOG.md is reverse-chronological, so we walk from the top and stop the
    moment we reach a section whose `(build N)` is <= the user's build. Sections
    without a parseable build number (rare, near the top) are included. Falls
    back to the latest section if the user is already current.
    """
    if not os.path.exists(_CHANGELOG_PATH):
        return ""
    with open(_CHANGELOG_PATH, "r", encoding="utf-8-sig") as f:
        content = f.read()
    sections = [s.strip() for s in re.split(r"(?=^## )", content, flags=re.MULTILINE)
                if s.strip().startswith("## ")]
    out = []
    for section in sections:
        m = re.search(r"\(build (\d+)\)", section)
        if m and int(m.group(1)) <= since_build:
            break
        out.append(section)
    if out:
        return "\n\n".join(out)
    return sections[0] if sections else ""


@update_api.route("/api/update/check", methods=["GET"])
def check_update():
    """Return current version info + latest changelog section."""
    version_data = _read_version_json()
    if not version_data:
        return jsonify({"status": "error", "message": "No version info available"}), 404

    # The app sends ?since=<its current build> so we can return the cumulative
    # notes for every version between theirs and current. Old apps that don't
    # send it get just the latest section (backward compatible).
    since = request.args.get("since", type=int)
    changelog = _parse_changelog_since(since) if since is not None else _parse_latest_changelog()

    return jsonify({
        "status": "ok",
        "version": version_data.get("version", "0.0.0"),
        "build_number": version_data.get("build_number", 0),
        "changelog": changelog,
        "android_size": version_data.get("android_size", 0),
        "windows_size": version_data.get("windows_size", 0),
        # linux_size is optional — only populated by release-linux.sh on
        # machines that actually produced a Linux build. 0 when absent so
        # the frontend can treat "no Linux artifact this release" as the
        # same as "no update for me" rather than erroring.
        "linux_size": version_data.get("linux_size", 0),
        "released_at": version_data.get("released_at", ""),
    })


@update_api.route("/api/update/download/<platform>", methods=["GET"])
def download_update(platform):
    """Stream the update file for the given platform (android, windows, or linux)."""
    platform_files = {
        "android": "nasradio-android.apk",
        "windows": "nasradio-windows.zip",
        "linux": "nasradio-linux.tar.xz",
    }
    if platform not in platform_files:
        return (
            jsonify({
                "error": "Invalid platform. Use 'android', 'windows', or 'linux'."
            }),
            400,
        )

    filename = platform_files[platform]
    filepath = os.path.join(_UPDATES_DIR, filename)
    if not os.path.exists(filepath):
        return jsonify({"error": f"No update file available for {platform}"}), 404

    return send_file(
        filepath,
        as_attachment=True,
        download_name=filename,
    )
