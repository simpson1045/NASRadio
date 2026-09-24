import os
import shutil
import threading
import time
from datetime import datetime


class DatabaseBackup:
    def __init__(
        self, database_path: str, backup_dir: str = None, max_backups: int = 10
    ):
        self.database_path = database_path
        self.backup_dir = backup_dir or os.path.join(
            os.path.dirname(database_path), "backups"
        )
        self.max_backups = max_backups
        self._stop_event = threading.Event()
        self._thread = None

        os.makedirs(self.backup_dir, exist_ok=True)

    def create_backup(self) -> str:
        """Create a timestamped backup of the database."""
        if not os.path.exists(self.database_path):
            print(f"⚠️ Database not found: {self.database_path}")
            return None

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_filename = f"nasradio_backup_{timestamp}.db"
        backup_path = os.path.join(self.backup_dir, backup_filename)

        try:
            shutil.copy2(self.database_path, backup_path)
            print(f"💾 Backup created: {backup_filename}")
            self._cleanup_old_backups()
            return backup_path
        except Exception as e:
            print(f"❌ Backup failed: {e}")
            return None

    def _cleanup_old_backups(self):
        """Keep only the most recent max_backups."""
        backups = []
        for filename in os.listdir(self.backup_dir):
            if not filename.startswith("nasradio_backup_"):
                continue
            filepath = os.path.join(self.backup_dir, filename)
            backups.append((filepath, os.path.getmtime(filepath)))

        # Sort by time, newest first
        backups.sort(key=lambda x: x[1], reverse=True)

        # Remove excess backups
        for filepath, _ in backups[self.max_backups :]:
            try:
                os.remove(filepath)
                print(f"🗑️ Removed old backup: {os.path.basename(filepath)}")
            except Exception as e:
                print(f"⚠️ Failed to remove {filepath}: {e}")

    def start_scheduled_backups(self, interval_hours: int = 24):
        """Start background thread for scheduled backups."""

        def backup_loop():
            while not self._stop_event.is_set():
                self.create_backup()
                self._stop_event.wait(interval_hours * 3600)

        self._thread = threading.Thread(target=backup_loop, daemon=True)
        self._thread.start()
        print(f"🔄 Scheduled backups every {interval_hours} hours")

    def stop(self):
        """Stop scheduled backups."""
        self._stop_event.set()
