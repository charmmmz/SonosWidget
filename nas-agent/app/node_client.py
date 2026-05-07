"""HTTP client for Node relay /internal/sonos APIs."""

from __future__ import annotations

from typing import Any

import httpx

from app.config import settings


class NodeRelayError(Exception):
    def __init__(self, message: str, status_code: int | None = None, body: Any = None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


class NodeRelayClient:
    def __init__(self) -> None:
        self._base = settings.node_base_url.rstrip("/")
        self._headers = {"X-Internal-Token": settings.internal_api_token}

    def _request(self, method: str, path: str, **kw: Any) -> dict[str, Any]:
        if not settings.internal_api_token:
            raise NodeRelayError("INTERNAL_API_TOKEN is not configured on the agent", status_code=503)
        url = f"{self._base}{path}"
        try:
            with httpx.Client(timeout=15.0) as client:
                r = client.request(method, url, headers=self._headers, **kw)
        except httpx.RequestError as e:
            raise NodeRelayError(f"Node relay unreachable: {e}") from e

        try:
            data = r.json() if r.content else {}
        except ValueError:
            data = {"raw": r.text}

        if r.status_code >= 400:
            raise NodeRelayError(
                data.get("error", r.text) or f"HTTP {r.status_code}",
                status_code=r.status_code,
                body=data,
            )
        return data if isinstance(data, dict) else {"data": data}

    def groups(self) -> dict[str, Any]:
        return self._request("GET", "/internal/sonos/groups")

    def state(self, group_id: str) -> dict[str, Any]:
        return self._request("GET", "/internal/sonos/state", params={"groupId": group_id})

    def play(self, group_id: str) -> dict[str, Any]:
        return self._request("POST", "/internal/sonos/play", json={"groupId": group_id})

    def pause(self, group_id: str) -> dict[str, Any]:
        return self._request("POST", "/internal/sonos/pause", json={"groupId": group_id})

    def next_track(self, group_id: str) -> dict[str, Any]:
        return self._request("POST", "/internal/sonos/next", json={"groupId": group_id})

    def previous_track(self, group_id: str) -> dict[str, Any]:
        return self._request("POST", "/internal/sonos/previous", json={"groupId": group_id})

    def volume(self, group_id: str, volume: int) -> dict[str, Any]:
        return self._request("POST", "/internal/sonos/volume", json={"groupId": group_id, "volume": volume})

    def public_health(self) -> dict[str, Any]:
        """No internal token — confirms relay HTTP is up."""
        url = f"{self._base}/api/health"
        with httpx.Client(timeout=5.0) as client:
            r = client.get(url)
            r.raise_for_status()
            return r.json()
