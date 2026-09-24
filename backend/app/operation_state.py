"""
Persistent operation state management.
Tracks progress of long-running operations and allows resume after restart/cancel.
"""

import psycopg2
import psycopg2.extras
import json
import time
from datetime import datetime


def init_operation_tables(db_url):
    """Create the operation state tables if they don't exist"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Main operation state table
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS operation_state (
            id SERIAL PRIMARY KEY,
            operation_type TEXT NOT NULL UNIQUE,
            status TEXT DEFAULT 'idle',
            current INTEGER DEFAULT 0,
            total INTEGER DEFAULT 0,
            message TEXT,
            eta TEXT,
            started_at TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            completed_at TIMESTAMP,
            error TEXT,
            extra_data TEXT
        )
    """
    )

    # Operation log for tracking what's been processed (for resume)
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS operation_log (
            id SERIAL PRIMARY KEY,
            operation_type TEXT NOT NULL,
            item_id INTEGER,
            item_path TEXT,
            status TEXT DEFAULT 'pending',
            processed_at TIMESTAMP,
            error TEXT
        )
    """
    )

    cursor.execute(
        "CREATE INDEX IF NOT EXISTS idx_op_log_type ON operation_log(operation_type)"
    )
    cursor.execute(
        "CREATE INDEX IF NOT EXISTS idx_op_log_status ON operation_log(operation_type, status)"
    )

    conn.commit()
    conn.close()


class OperationState:
    """Manage persistent operation state"""

    OPERATION_TYPES = [
        "library_scan",
        "artwork_download",
        "artist_images",
        "folder_scan",
        "audio_analysis",
        "transcode",
    ]

    def __init__(self, db_url):
        self.db_url = db_url
        init_operation_tables(db_url)

    def get_connection(self):
        conn = psycopg2.connect(self.db_url)
        return conn

    def get_cursor(self, conn):
        return conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    def start_operation(self, operation_type, total, message="Starting..."):
        """Start or resume an operation"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            INSERT INTO operation_state (operation_type, status, current, total, message, started_at, updated_at)
            VALUES (%s, 'running', 0, %s, %s, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT(operation_type) DO UPDATE SET
                status = 'running',
                current = 0,
                total = excluded.total,
                message = excluded.message,
                started_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP,
                completed_at = NULL,
                error = NULL
        """,
            (operation_type, total, message),
        )

        conn.commit()
        conn.close()

    def update_progress(
        self, operation_type, current, message=None, eta=None, extra_data=None
    ):
        """Update operation progress"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        updates = ["current = %s", "updated_at = CURRENT_TIMESTAMP"]
        params = [current]

        if message:
            updates.append("message = %s")
            params.append(message)
        if eta:
            updates.append("eta = %s")
            params.append(eta)
        if extra_data:
            updates.append("extra_data = %s")
            params.append(json.dumps(extra_data))

        params.append(operation_type)

        cursor.execute(
            f"""
            UPDATE operation_state 
            SET {', '.join(updates)}
            WHERE operation_type = %s
        """,
            params,
        )

        conn.commit()
        conn.close()

    def complete_operation(self, operation_type, message="Complete"):
        """Mark operation as complete"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            UPDATE operation_state 
            SET status = 'complete', message = %s, completed_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
            WHERE operation_type = %s
        """,
            (message, operation_type),
        )

        conn.commit()
        conn.close()

    def fail_operation(self, operation_type, error):
        """Mark operation as failed"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            UPDATE operation_state 
            SET status = 'failed', error = %s, updated_at = CURRENT_TIMESTAMP
            WHERE operation_type = %s
        """,
            (error, operation_type),
        )

        conn.commit()
        conn.close()

    def cancel_operation(self, operation_type):
        """Cancel an operation"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            UPDATE operation_state 
            SET status = 'cancelled', message = 'Cancelled by user', updated_at = CURRENT_TIMESTAMP
            WHERE operation_type = %s
        """,
            (operation_type,),
        )

        conn.commit()
        conn.close()

    def get_state(self, operation_type):
        """Get current state of an operation"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            "SELECT * FROM operation_state WHERE operation_type = %s", (operation_type,)
        )
        row = cursor.fetchone()
        conn.close()

        if not row:
            return {
                "operation_type": operation_type,
                "status": "idle",
                "current": 0,
                "total": 0,
                "message": None,
                "eta": None,
                "percent": 0,
            }

        result = dict(row)
        if result.get("extra_data"):
            result["extra_data"] = json.loads(result["extra_data"])

        # Calculate percent
        if result["total"] > 0:
            result["percent"] = round(result["current"] / result["total"] * 100, 1)
        else:
            result["percent"] = 0

        return result

    def get_all_states(self):
        """Get state of all operations"""
        return {op_type: self.get_state(op_type) for op_type in self.OPERATION_TYPES}

    def is_running(self, operation_type):
        """Check if an operation is currently running"""
        state = self.get_state(operation_type)
        return state["status"] == "running"

    # ==================
    # Operation Log (for resume capability)
    # ==================

    def log_item_pending(self, operation_type, item_id=None, item_path=None):
        """Log an item as pending processing"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            INSERT INTO operation_log (operation_type, item_id, item_path, status)
            VALUES (%s, %s, %s, 'pending')
            ON CONFLICT DO NOTHING
        """,
            (operation_type, item_id, item_path),
        )

        conn.commit()
        conn.close()

    def log_item_complete(self, operation_type, item_id=None, item_path=None):
        """Mark an item as processed"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        if item_id:
            cursor.execute(
                """
                UPDATE operation_log 
                SET status = 'complete', processed_at = CURRENT_TIMESTAMP
                WHERE operation_type = %s AND item_id = %s
            """,
                (operation_type, item_id),
            )
        elif item_path:
            cursor.execute(
                """
                UPDATE operation_log 
                SET status = 'complete', processed_at = CURRENT_TIMESTAMP
                WHERE operation_type = %s AND item_path = %s
            """,
                (operation_type, item_path),
            )

        conn.commit()
        conn.close()

    def log_item_failed(self, operation_type, error, item_id=None, item_path=None):
        """Mark an item as failed"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        if item_id:
            cursor.execute(
                """
                UPDATE operation_log 
                SET status = 'failed', error = %s, processed_at = CURRENT_TIMESTAMP
                WHERE operation_type = %s AND item_id = %s
            """,
                (error, operation_type, item_id),
            )
        elif item_path:
            cursor.execute(
                """
                UPDATE operation_log 
                SET status = 'failed', error = %s, processed_at = CURRENT_TIMESTAMP
                WHERE operation_type = %s AND item_path = %s
            """,
                (error, operation_type, item_path),
            )

        conn.commit()
        conn.close()

    def get_pending_items(self, operation_type):
        """Get items that haven't been processed yet"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            SELECT * FROM operation_log 
            WHERE operation_type = %s AND status = 'pending'
        """,
            (operation_type,),
        )

        rows = cursor.fetchall()
        conn.close()

        return [dict(row) for row in rows]

    def get_completed_count(self, operation_type):
        """Get count of completed items"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            """
            SELECT COUNT(*) FROM operation_log 
            WHERE operation_type = %s AND status = 'complete'
        """,
            (operation_type,),
        )

        count = cursor.fetchone()["count"]
        conn.close()

        return count

    def clear_log(self, operation_type):
        """Clear the log for an operation (for fresh start)"""
        conn = self.get_connection()
        cursor = self.get_cursor(conn)

        cursor.execute(
            "DELETE FROM operation_log WHERE operation_type = %s", (operation_type,)
        )

        conn.commit()
        conn.close()
