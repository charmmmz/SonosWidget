"""Periodic Sonos snapshot polling via Node → SQLite habits."""

from __future__ import annotations

import logging

from app.config import settings
from app.db import aggregate_events_for_summary, insert_playback_event, set_habit_summary
from app.node_client import NodeRelayClient, NodeRelayError

log = logging.getLogger(__name__)

_last_fingerprint: dict[str, str] = {}


def poll_sonos_and_update_habits() -> None:
    client = NodeRelayClient()
    try:
        data = client.groups()
    except NodeRelayError as e:
        log.debug("habit poll skipped: %s", e)
        return

    groups = data.get("groups") or []
    for g in groups:
        gid = g.get("groupId")
        if not gid:
            continue
        title = g.get("trackTitle") or ""
        artist = g.get("artist") or ""
        album = g.get("album") or ""
        is_playing = bool(g.get("isPlaying"))
        fp = f"{title}|{artist}|{is_playing}"
        if _last_fingerprint.get(gid) == fp:
            continue
        _last_fingerprint[gid] = fp
        insert_playback_event(
            group_id=str(gid),
            title=title or None,
            artist=artist or None,
            album=album or None,
            is_playing=is_playing,
            source="poll",
        )

    summary = aggregate_events_for_summary()
    set_habit_summary(summary)


def start_scheduler(scheduler) -> None:
    scheduler.add_job(
        poll_sonos_and_update_habits,
        "interval",
        seconds=max(15, settings.habit_poll_seconds),
        id="habit_poll",
        replace_existing=True,
    )
