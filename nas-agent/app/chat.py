"""OpenAI tool-calling loop — tools only talk to Node relay or local habit DB."""

from __future__ import annotations

import json
import logging
from typing import Any

from openai import OpenAI

from app.config import settings
from app.db import get_habit_summary_text
from app.node_client import NodeRelayClient, NodeRelayError

log = logging.getLogger(__name__)

TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "sonos_list_groups",
            "description": "List Sonos groups on the LAN with coordinator IP (groupId), speaker name, now playing title/artist, isPlaying.",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sonos_get_state",
            "description": "Refresh and return playback state for one group (groupId is coordinator IP string).",
            "parameters": {
                "type": "object",
                "properties": {"group_id": {"type": "string", "description": "Coordinator IP / groupId"}},
                "required": ["group_id"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sonos_play",
            "description": "Start or resume playback for the group.",
            "parameters": {
                "type": "object",
                "properties": {"group_id": {"type": "string"}},
                "required": ["group_id"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sonos_pause",
            "description": "Pause playback for the group.",
            "parameters": {
                "type": "object",
                "properties": {"group_id": {"type": "string"}},
                "required": ["group_id"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sonos_next",
            "description": "Skip to next track.",
            "parameters": {
                "type": "object",
                "properties": {"group_id": {"type": "string"}},
                "required": ["group_id"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sonos_previous",
            "description": "Go to previous track.",
            "parameters": {
                "type": "object",
                "properties": {"group_id": {"type": "string"}},
                "required": ["group_id"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sonos_set_volume",
            "description": "Set group volume 0–100.",
            "parameters": {
                "type": "object",
                "properties": {
                    "group_id": {"type": "string"},
                    "volume": {"type": "integer", "minimum": 0, "maximum": 100},
                },
                "required": ["group_id", "volume"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_listening_habits_summary",
            "description": "Short JSON summary of recent listening patterns learned from local polls.",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
        },
    },
]


def _dispatch(name: str, args: dict[str, Any]) -> dict[str, Any]:
    node = NodeRelayClient()
    try:
        if name == "sonos_list_groups":
            return node.groups()
        if name == "sonos_get_state":
            return node.state(args["group_id"])
        if name == "sonos_play":
            return node.play(args["group_id"])
        if name == "sonos_pause":
            return node.pause(args["group_id"])
        if name == "sonos_next":
            return node.next_track(args["group_id"])
        if name == "sonos_previous":
            return node.previous_track(args["group_id"])
        if name == "sonos_set_volume":
            return node.volume(args["group_id"], int(args["volume"]))
        if name == "get_listening_habits_summary":
            return {"summary": get_habit_summary_text()}
    except NodeRelayError as e:
        log.warning("tool %s failed: %s", name, e)
        return {"ok": False, "error": str(e), "status_code": e.status_code}
    return {"ok": False, "error": f"unknown_tool {name}"}


def run_chat(user_message: str, *, max_tool_rounds: int = 8) -> str:
    if not settings.openai_api_key:
        return "Agent misconfigured: OPENAI_API_KEY is empty."

    client = OpenAI(api_key=settings.openai_api_key)
    habits = get_habit_summary_text()
    system = (
        "You are a helpful home music assistant for Sonos on the user's LAN. "
        "You MUST use the provided tools to inspect or change playback — do not invent device IPs. "
        "groupId is always the coordinator IP string returned by sonos_list_groups. "
        "After actions, summarize what you did in plain language.\n\n"
        f"Listening habit summary (JSON): {habits}"
    )

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": system},
        {"role": "user", "content": user_message},
    ]

    for _ in range(max_tool_rounds):
        resp = client.chat.completions.create(
            model=settings.openai_model,
            messages=messages,
            tools=TOOLS,
            tool_choice="auto",
        )
        choice = resp.choices[0]
        msg = choice.message
        assistant_msg: dict[str, Any] = {"role": "assistant", "content": msg.content}
        if msg.tool_calls:
            assistant_msg["tool_calls"] = [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {"name": tc.function.name, "arguments": tc.function.arguments or "{}"},
                }
                for tc in msg.tool_calls
            ]
        messages.append(assistant_msg)

        calls = msg.tool_calls or []
        if not calls:
            return (msg.content or "").strip() or "(empty reply)"

        for tc in calls:
            name = tc.function.name
            try:
                raw_args = tc.function.arguments or "{}"
                args = json.loads(raw_args) if isinstance(raw_args, str) else {}
            except json.JSONDecodeError:
                args = {}
            result = _dispatch(name, args)
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": json.dumps(result, ensure_ascii=False, default=str),
                }
            )

    return "Stopped after maximum tool rounds — try a simpler request."
