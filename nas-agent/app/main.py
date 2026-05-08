from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from app.chat import run_chat
from app.config import settings
from app.db import init_db, insert_feedback
from app.habits import poll_sonos_and_update_habits, start_scheduler
from app.node_client import NodeRelayClient, NodeRelayError

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

scheduler = BackgroundScheduler()


def _verify_bearer(authorization: Optional[str]) -> None:
    if not settings.agent_user_token:
        raise HTTPException(status_code=503, detail="AGENT_USER_TOKEN is not configured")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Authorization Bearer token required")
    token = authorization.removeprefix("Bearer ").strip()
    if token != settings.agent_user_token:
        raise HTTPException(status_code=401, detail="Invalid token")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    init_db()
    try:
        poll_sonos_and_update_habits()
    except Exception:
        log.exception("initial habit poll failed")
    start_scheduler(scheduler)
    scheduler.start()
    log.info("scheduler started (habit poll every %ss)", settings.habit_poll_seconds)
    yield
    scheduler.shutdown(wait=False)


app = FastAPI(title="Charm for Sonos NAS Agent", lifespan=lifespan)


class ChatBody(BaseModel):
    message: str = Field(..., min_length=1, max_length=8000)


class FeedbackBody(BaseModel):
    kind: str = Field(..., min_length=1, max_length=64)
    payload: Optional[Dict[str, Any]] = None


@app.get("/api/health")
def health() -> dict[str, Any]:
    out: dict[str, Any] = {
        "ok": True,
        "openai_configured": bool(settings.openai_api_key),
        "agent_user_token_configured": bool(settings.agent_user_token),
        "internal_token_configured": bool(settings.internal_api_token),
        "relay": None,
    }
    try:
        node = NodeRelayClient()
        out["relay"] = {"ok": True, "groups": node.public_health().get("groups", [])}
    except Exception as e:
        out["relay"] = {"ok": False, "error": str(e)}
    return out


@app.post("/api/chat")
def chat(body: ChatBody, authorization: Optional[str] = Header(None)) -> dict[str, str]:
    _verify_bearer(authorization)
    reply = run_chat(body.message.strip())
    return {"reply": reply}


@app.post("/api/feedback")
def feedback(body: FeedbackBody, authorization: Optional[str] = Header(None)) -> dict[str, bool]:
    _verify_bearer(authorization)
    insert_feedback(body.kind, body.payload)
    return {"ok": True}


@app.get("/api/habits/summary")
def habits_summary(authorization: Optional[str] = Header(None)) -> dict[str, str]:
    _verify_bearer(authorization)
    from app.db import get_habit_summary_text

    return {"summary": get_habit_summary_text()}
