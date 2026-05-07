from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from app.config import settings


def _connect() -> sqlite3.Connection:
    Path(settings.database_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(settings.database_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


@contextmanager
def get_conn():
    conn = _connect()
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with get_conn() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS playback_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              group_id TEXT NOT NULL,
              title TEXT,
              artist TEXT,
              album TEXT,
              is_playing INTEGER NOT NULL,
              source TEXT NOT NULL DEFAULT 'poll'
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS habit_summary (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              summary_json TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_feedback (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts TEXT NOT NULL,
              kind TEXT NOT NULL,
              payload TEXT
            )
            """
        )


def insert_playback_event(
    *,
    group_id: str,
    title: str | None,
    artist: str | None,
    album: str | None,
    is_playing: bool,
    source: str = "poll",
) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO playback_events (ts, group_id, title, artist, album, is_playing, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (ts, group_id, title or "", artist or "", album or "", 1 if is_playing else 0, source),
        )


def insert_feedback(kind: str, payload: dict | None = None) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO user_feedback (ts, kind, payload) VALUES (?, ?, ?)",
            (ts, kind, json.dumps(payload) if payload else None),
        )


def get_habit_summary_text() -> str:
    with get_conn() as conn:
        row = conn.execute("SELECT summary_json FROM habit_summary WHERE id = 1").fetchone()
        if not row:
            return "(no listening history summarised yet — play music at home for a while)"
        return row["summary_json"]


def set_habit_summary(summary: dict) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    blob = json.dumps(summary, ensure_ascii=False)
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO habit_summary (id, summary_json, updated_at)
            VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET summary_json = excluded.summary_json,
              updated_at = excluded.updated_at
            """,
            (blob, ts),
        )


def aggregate_events_for_summary() -> dict:
    """Simple aggregates for LLM context (last ~500 rows)."""
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT artist, title, is_playing, ts FROM playback_events
            ORDER BY id DESC LIMIT 500
            """
        ).fetchall()

    if not rows:
        return {"eventCount": 0, "note": "No playback events recorded yet."}

    from collections import Counter

    artists = Counter((r["artist"] or "").strip() for r in rows if (r["artist"] or "").strip())
    top_artists = [a for a, _ in artists.most_common(8)]
    playing_ratio = sum(1 for r in rows if r["is_playing"]) / len(rows)

    hours: Counter[int] = Counter()
    for r in rows:
        try:
            h = datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).hour
            hours[h] += 1
        except ValueError:
            continue
    peak_hours = [h for h, _ in hours.most_common(3)]

    return {
        "recentSamples": len(rows),
        "topArtists": top_artists,
        "fractionPlayingSamples": round(playing_ratio, 3),
        "peakListeningHoursUtc": peak_hours,
    }
