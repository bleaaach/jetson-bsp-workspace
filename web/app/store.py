"""
store.py - SQLite persistence for devices and job history.

Design rules (per project decision):
  * Device records NEVER store SSH passwords — only host/port/user and an
    *optional* key path. Passwords stay in per-request / per-session memory.
  * Job history stores only metadata (what, when, status, message), not logs.
"""
from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path
from typing import Optional

WORKSPACE = Path("/home/seeed/bsp-workspace")
DATA_DIR = WORKSPACE / "web" / "data"
DB_PATH = DATA_DIR / "web.db"

_lock = threading.Lock()
_conn: Optional[sqlite3.Connection] = None


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        _conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _init_schema(_conn)
    return _conn


def _init_schema(conn: sqlite3.Connection):
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS devices (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        host        TEXT NOT NULL,
        port        INTEGER NOT NULL DEFAULT 22,
        user        TEXT NOT NULL DEFAULT 'nvidia',
        key_path    TEXT NOT NULL DEFAULT '',
        note        TEXT NOT NULL DEFAULT '',
        created_at  REAL NOT NULL,
        UNIQUE(host, port, user)
    );

    CREATE TABLE IF NOT EXISTS jobs (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        kind        TEXT NOT NULL,        -- build | push | download
        target      TEXT NOT NULL,        -- module / version / host
        status      TEXT NOT NULL,        -- running | ok | error
        message     TEXT NOT NULL DEFAULT '',
        created_at  REAL NOT NULL,
        finished_at REAL
    );
    """)


def _now() -> float:
    return time.time()


# =============================================================================
# Devices
# =============================================================================

def list_devices() -> list[dict]:
    with _lock:
        cur = _get_conn().execute(
            "SELECT id, name, host, port, user, key_path, note, created_at "
            "FROM devices ORDER BY name, host"
        )
        rows = cur.fetchall()
    return [dict(r) for r in rows]


def get_device(device_id: int) -> Optional[dict]:
    with _lock:
        cur = _get_conn().execute(
            "SELECT id, name, host, port, user, key_path, note, created_at "
            "FROM devices WHERE id=?", (device_id,)
        )
        row = cur.fetchone()
    return dict(row) if row else None


def save_device(name: str, host: str, port: int, user: str,
                key_path: str = "", note: str = "",
                device_id: Optional[int] = None) -> dict:
    port = int(port) or 22
    user = user or "nvidia"
    with _lock:
        conn = _get_conn()
        if device_id is not None:
            conn.execute(
                "UPDATE devices SET name=?, host=?, port=?, user=?, key_path=?, note=? WHERE id=?",
                (name, host, port, user, key_path, note, device_id),
            )
            new_id = device_id
        else:
            cur = conn.execute(
                "INSERT INTO devices (name, host, port, user, key_path, note, created_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (name, host, port, user, key_path, note, _now()),
            )
            new_id = cur.lastrowid
        conn.commit()
    return get_device(new_id)


def delete_device(device_id: int) -> bool:
    with _lock:
        conn = _get_conn()
        conn.execute("DELETE FROM devices WHERE id=?", (device_id,))
        conn.commit()
    return True


# =============================================================================
# Jobs
# =============================================================================

def create_job(kind: str, target: str) -> int:
    with _lock:
        conn = _get_conn()
        cur = conn.execute(
            "INSERT INTO jobs (kind, target, status, message, created_at) "
            "VALUES (?,?,?,?,?)",
            (kind, target, "running", "", _now()),
        )
        conn.commit()
        return cur.lastrowid


def finish_job(job_id: int, status: str, message: str = ""):
    with _lock:
        conn = _get_conn()
        conn.execute(
            "UPDATE jobs SET status=?, message=?, finished_at=? WHERE id=?",
            (status, message, _now(), job_id),
        )
        conn.commit()


def list_jobs(limit: int = 50) -> list[dict]:
    with _lock:
        cur = _get_conn().execute(
            "SELECT * FROM jobs ORDER BY id DESC LIMIT ?", (limit,)
        )
        rows = cur.fetchall()
    return [dict(r) for r in rows]