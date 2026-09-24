"""
NASRadio user management CLI.

Usage:
  python manage_users.py list
  python manage_users.py create <username> [admin|user]   # prompts for password
  python manage_users.py passwd <username>                # prompts for password
  python manage_users.py check  <username>                # test a password matches
  python manage_users.py role   <username> <admin|user>
  python manage_users.py revoke <username>      # log out all their devices

Passwords are entered at a hidden prompt (paste your generated one in) — never
on the command line, so any symbols work and nothing lands in shell history.

Run from the backend/ dir with the venv:
  venv\\Scripts\\python.exe manage_users.py create yourname admin
"""

import getpass
import sys

from app.config import Config
from app.models import Database
from app import auth


def _prompt_password():
    pw = getpass.getpass("Password (paste it; input is hidden): ")
    if not pw:
        print("no password entered"); sys.exit(1)
    return pw


def _db():
    # migrate=True: this CLI may be the first thing run against a fresh database.
    return Database(Config().DATABASE_URL, migrate=True)


def cmd_list():
    db = _db(); conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT id, username, role, token_version, created_at FROM users ORDER BY id")
        rows = cur.fetchall()
    finally:
        conn.close()
    if not rows:
        print("(no users yet)")
        return
    for r in rows:
        print(f"  #{r['id']:<3} {r['username']:<20} {r['role']:<6} v{r['token_version']}  {r['created_at']}")


def cmd_create(username, role="user"):
    if role not in ("admin", "user"):
        print(f"role must be admin or user, got {role!r}"); sys.exit(1)
    password = _prompt_password()
    if len(password) < 8:
        print("password must be at least 8 characters"); sys.exit(1)
    db = _db(); conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT id FROM users WHERE LOWER(username) = LOWER(%s)", (username,))
        if cur.fetchone():
            print(f"user {username!r} already exists — use passwd to change the password"); sys.exit(1)
        cur.execute(
            "INSERT INTO users (username, password_hash, role) VALUES (%s, %s, %s) RETURNING id",
            (username, auth.hash_password(password), role),
        )
        uid = cur.fetchone()["id"]
        conn.commit()
    finally:
        conn.close()
    print(f"created user #{uid} {username!r} ({role})")


def cmd_passwd(username):
    password = _prompt_password()
    if len(password) < 8:
        print("password must be at least 8 characters"); sys.exit(1)
    db = _db(); conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "UPDATE users SET password_hash = %s, token_version = token_version + 1 WHERE LOWER(username) = LOWER(%s)",
            (auth.hash_password(password), username),
        )
        n = cur.rowcount
        conn.commit()
    finally:
        conn.close()
    print(f"updated password for {username!r}" if n else f"no such user {username!r}")


def cmd_check(username):
    user = auth.get_user_by_username(username)
    if not user:
        print(f"no such user {username!r}"); return
    password = _prompt_password()
    if auth.verify_password(password, user["password_hash"]):
        print(f"✓ password MATCHES for {username!r} — you're good")
    else:
        print(f"✗ password does NOT match for {username!r} — re-run 'passwd {username}' to reset it")


def cmd_role(username, role):
    if role not in ("admin", "user"):
        print(f"role must be admin or user, got {role!r}"); sys.exit(1)
    db = _db(); conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("UPDATE users SET role = %s WHERE LOWER(username) = LOWER(%s)", (role, username))
        n = cur.rowcount
        conn.commit()
    finally:
        conn.close()
    print(f"set {username!r} role to {role}" if n else f"no such user {username!r}")


def cmd_revoke(username):
    db = _db(); conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("UPDATE users SET token_version = token_version + 1 WHERE LOWER(username) = LOWER(%s)", (username,))
        n = cur.rowcount
        conn.commit()
    finally:
        conn.close()
    print(f"revoked all tokens for {username!r}" if n else f"no such user {username!r}")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); sys.exit(1)
    cmd, rest = args[0], args[1:]
    try:
        if cmd == "list":
            cmd_list()
        elif cmd == "create":
            cmd_create(*rest)
        elif cmd == "passwd":
            cmd_passwd(*rest)
        elif cmd == "check":
            cmd_check(*rest)
        elif cmd == "role":
            cmd_role(*rest)
        elif cmd == "revoke":
            cmd_revoke(*rest)
        else:
            print(__doc__); sys.exit(1)
    except TypeError:
        print(f"wrong number of arguments for {cmd!r}\n"); print(__doc__); sys.exit(1)


if __name__ == "__main__":
    main()
