"""FastAPI server exposing the IRIS agent sidecar over localhost.

Endpoints (consumed by IRIS/AI/SidecarClient.swift):
    GET  /health            -> {"ok": true, "version": ...}
    POST /tasks             -> {"id": "<hex>"}                 (starts a task, non-blocking)
    GET  /events            -> text/event-stream of TaskEvent   (all tasks, one stream)
    POST /tasks/{id}/cancel -> {"cancelled": bool}

Run:  uvicorn iris_agents.server:app --host 127.0.0.1 --port 8765
or:   python -m iris_agents.server   (honors IRIS_SIDECAR_PORT / IRIS_SIDECAR_HOST)
"""

from __future__ import annotations

import asyncio
import logging
import os

from fastapi import FastAPI
from fastapi.responses import StreamingResponse

from . import __version__
from .manager import TaskManager
from .models import TaskRequest

# Load sidecar/.env if present (does not override vars IRIS already passed in the spawn env).
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

logging.basicConfig(
    level=os.environ.get("IRIS_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("iris.server")

app = FastAPI(title="IRIS Agent Sidecar", version=__version__)
manager = TaskManager()


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "version": __version__}


@app.post("/tasks")
async def create_task(req: TaskRequest) -> dict:
    task_id = manager.launch(req)
    log.info("launched task %s kind=%s detail=%r", task_id, req.kind, req.detail[:80])
    return {"id": task_id}


@app.post("/tasks/{task_id}/cancel")
async def cancel_task(task_id: str) -> dict:
    return {"cancelled": manager.cancel(task_id)}


@app.get("/events")
async def events() -> StreamingResponse:
    async def gen():
        # Initial comment so the client knows the stream is live.
        yield ": iris-agent stream open\n\n"
        q = manager.add_subscriber()
        try:
            for ev in manager.snapshot():
                yield f"data: {ev.model_dump_json()}\n\n"
            while True:
                try:
                    ev = await asyncio.wait_for(q.get(), timeout=15)
                    yield f"data: {ev.model_dump_json()}\n\n"
                except asyncio.TimeoutError:
                    yield ": ping\n\n"   # heartbeat keeps the client's connection alive
        finally:
            manager.remove_subscriber(q)

    headers = {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",
    }
    return StreamingResponse(gen(), media_type="text/event-stream", headers=headers)


def main() -> None:
    import uvicorn

    host = os.environ.get("IRIS_SIDECAR_HOST", "127.0.0.1")
    port = int(os.environ.get("IRIS_SIDECAR_PORT", "8765"))
    uvicorn.run(app, host=host, port=port, log_level=os.environ.get("IRIS_LOG_LEVEL", "info").lower())


if __name__ == "__main__":
    main()
