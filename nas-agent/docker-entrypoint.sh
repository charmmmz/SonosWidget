#!/bin/sh
set -e
exec uvicorn app.main:app --host 0.0.0.0 --port "${AGENT_PORT:-8790}"
