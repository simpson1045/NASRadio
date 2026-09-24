"""Incremental scanner module - scans only new files"""

from app.extensions import socketio, safe_emit


def get_existing_file_paths(db):
    """Get set of all file paths already in database"""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("SELECT file_path FROM songs")
        return set(row["file_path"] for row in cursor.fetchall())
    finally:
        conn.close()


def get_excluded_file_paths(db):
    """Get set of all file paths that were manually deleted"""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("SELECT file_path FROM excluded_paths")
        return set(row["file_path"] for row in cursor.fetchall())
    finally:
        conn.close()


def _emit_progress(scanner, current, total, message, status="running"):
    """Emit websocket progress event for incremental scan"""
    if scanner.operation_id:
        safe_emit(
            "scan_progress",
            {
                "operation_id": scanner.operation_id,
                "current": current,
                "total": total,
                "message": message,
                "status": status,
                "songs_added": scanner.songs_added,
                "albums_added": scanner.albums_added,
                "artists_added": scanner.artists_added,
            },
        )


def scan_new_files_only(scanner):
    """Scan library but only import files not already in database"""
    print(f"Incremental scan: {scanner.config.MUSIC_LIBRARY_PATH}")

    import os

    if not os.path.exists(scanner.config.MUSIC_LIBRARY_PATH):
        print(f"Music library path does not exist: {scanner.config.MUSIC_LIBRARY_PATH}")
        if scanner.progress_tracker and scanner.operation_id:
            scanner.progress_tracker.fail_operation(
                scanner.operation_id, "Music library path does not exist"
            )
        _emit_progress(scanner, 0, 0, "Music library path does not exist", "failed")
        return

    # Emit counting status
    _emit_progress(scanner, 0, 0, "Scanning for new files...", "counting")

    # Get existing file paths from database
    existing_paths = get_existing_file_paths(scanner.db)
    print(f"Found {len(existing_paths)} existing files in database")

    # Get excluded file paths (manually deleted)
    excluded_paths = get_excluded_file_paths(scanner.db)
    print(f"Found {len(excluded_paths)} excluded files to skip")

    # First, find all NEW files (not in database and not excluded)
    new_files = []
    skipped_excluded = 0
    for root, dirs, files in os.walk(scanner.config.MUSIC_LIBRARY_PATH):
        # Skip Synology recycle bin and other hidden folders
        if "#recycle" in root.lower() or "/@" in root:
            continue
        for filename in files:
            file_ext = os.path.splitext(filename)[1].lower()
            if file_ext in scanner.config.SUPPORTED_FORMATS:
                file_path = os.path.join(root, filename)
                if file_path in excluded_paths:
                    skipped_excluded += 1
                elif file_path not in existing_paths:
                    new_files.append(file_path)

    total_new = len(new_files)
    print(
        f"Found {total_new} new files to import (skipped {skipped_excluded} excluded)"
    )

    if total_new == 0:
        print("No new files to import!")
        if scanner.progress_tracker and scanner.operation_id:
            scanner.progress_tracker.complete_operation(
                scanner.operation_id, "No new files to import"
            )
        _emit_progress(scanner, 0, 0, "No new files to import", "complete")
        return

    if scanner.progress_tracker and scanner.operation_id:
        scanner.progress_tracker.start_operation(
            scanner.operation_id, total_new, "incremental scan"
        )

    # Emit starting status with total
    _emit_progress(
        scanner, 0, total_new, f"Found {total_new} new files to import", "running"
    )

    # Process only new files
    processed = 0
    for file_path in new_files:
        # Check if cancelled
        if scanner.progress_tracker and scanner.operation_id:
            progress = scanner.progress_tracker.get_progress(scanner.operation_id)
            if progress and progress["status"] == "cancelled":
                print("Scan cancelled by user")
                _emit_progress(
                    scanner, processed, total_new, "Scan cancelled", "cancelled"
                )
                return

        scanner.process_audio_file(file_path)
        processed += 1

        # Update progress (both tracker and websocket)
        display_filename = os.path.basename(file_path)
        if scanner.progress_tracker and scanner.operation_id:
            scanner.progress_tracker.update_progress(
                scanner.operation_id, processed, f"Importing: {display_filename}"
            )

        # Emit websocket progress
        _emit_progress(scanner, processed, total_new, f"Importing: {display_filename}")

    print(f"\nIncremental scan complete!")
    print(f"Files scanned: {scanner.scanned_files}")
    print(f"Artists added: {scanner.artists_added}")
    print(f"Albums added: {scanner.albums_added}")
    print(f"Songs added: {scanner.songs_added}")
    print(f"Artwork extracted: {scanner.artwork_extracted}")

    # Emit complete status
    _emit_progress(
        scanner,
        total_new,
        total_new,
        f"Imported {scanner.songs_added} new songs",
        "complete",
    )

    if scanner.progress_tracker and scanner.operation_id:
        scanner.progress_tracker.complete_operation(
            scanner.operation_id, f"Imported {scanner.songs_added} new songs"
        )
