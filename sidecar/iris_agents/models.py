"""Shared data models for the IRIS agent sidecar.

These mirror the Swift `BackgroundTask` / `TaskEvent` types in the IRIS app so the
two processes agree on the wire format. Keep field names in sync with
IRIS/Core/BackgroundTask.swift and IRIS/AI/SidecarClient.swift.
"""

from __future__ import annotations

from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class TaskKind(str, Enum):
    """What the agent should do. Selects the tool subset + seed prompt."""

    calendar = "calendar"   # schedule something on the user's Google calendar
    web = "web"             # browse/search the web (e.g. find deals)
    agent = "agent"         # free-form autonomous task with all tools
    terminal = "terminal"   # open Terminal + start a `claude` Code session


class TaskState(str, Enum):
    """Lifecycle of a single background task. Matches BackgroundTaskState in Swift."""

    queued = "queued"
    running = "running"
    succeeded = "succeeded"
    failed = "failed"
    cancelled = "cancelled"


class TaskRequest(BaseModel):
    """Body of POST /tasks."""

    kind: TaskKind = TaskKind.agent
    detail: str = Field(..., description="The task text (wake phrase already stripped).")
    model: Optional[str] = Field(None, description="Override the agent LLM model id.")
    cwd: Optional[str] = Field(None, description="Working directory for terminal/file tasks.")
    title: Optional[str] = Field(None, description="Optional UI label; derived if omitted.")


class TaskEvent(BaseModel):
    """One state update for a task, streamed over GET /events (SSE)."""

    id: str
    kind: TaskKind
    title: str
    state: TaskState
    summary: Optional[str] = None   # spoken one-liner once finished
    detail: Optional[str] = None    # original task text (for matching / display)
