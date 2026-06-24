"""TaskManager — launches LangGraph agent runs concurrently and broadcasts state.

Each task is its own asyncio.Task, so N agents run in parallel (bounded by a
semaphore). State changes are pushed to every connected SSE subscriber, and the
latest state per task is snapshotted so a newly-connected client (the IRIS app
after a reconnect) immediately sees in-flight work.
"""

from __future__ import annotations

import asyncio
import logging
import os
import uuid
from typing import Dict, List, Set

from .agent import run_task, title_for
from .models import TaskEvent, TaskRequest, TaskState

log = logging.getLogger("iris.manager")


class TaskManager:
    def __init__(self, max_concurrent: int | None = None) -> None:
        if max_concurrent is None:
            max_concurrent = int(os.environ.get("IRIS_MAX_AGENTS", "4"))
        self._sem = asyncio.Semaphore(max(1, max_concurrent))
        self._tasks: Dict[str, asyncio.Task] = {}
        self._snapshots: Dict[str, TaskEvent] = {}
        self._subscribers: Set["asyncio.Queue[TaskEvent]"] = set()

    # ---- public API -------------------------------------------------------

    def launch(self, req: TaskRequest) -> str:
        """Start a task and return its id immediately (non-blocking)."""
        task_id = uuid.uuid4().hex
        title = req.title or title_for(req)
        # Optimistic queued event so the UI reacts before the agent spins up.
        self._emit(TaskEvent(
            id=task_id, kind=req.kind, title=title,
            state=TaskState.queued, detail=req.detail,
        ))
        t = asyncio.create_task(self._run(task_id, req, title), name=f"task-{task_id}")
        self._tasks[task_id] = t
        t.add_done_callback(lambda _t, i=task_id: self._tasks.pop(i, None))
        return task_id

    def cancel(self, task_id: str) -> bool:
        """Cancel one task. Other tasks keep running. Returns False if unknown."""
        t = self._tasks.get(task_id)
        if t is None:
            return False
        t.cancel()
        return True

    def cancel_all(self) -> None:
        for t in list(self._tasks.values()):
            t.cancel()

    def add_subscriber(self) -> "asyncio.Queue[TaskEvent]":
        q: "asyncio.Queue[TaskEvent]" = asyncio.Queue()
        self._subscribers.add(q)
        return q

    def remove_subscriber(self, q: "asyncio.Queue[TaskEvent]") -> None:
        self._subscribers.discard(q)

    def snapshot(self) -> List[TaskEvent]:
        """Current state of every known task (so a fresh subscriber catches up)."""
        return list(self._snapshots.values())

    # ---- internals --------------------------------------------------------

    async def _run(self, task_id: str, req: TaskRequest, title: str) -> None:
        async with self._sem:
            self._emit(TaskEvent(
                id=task_id, kind=req.kind, title=title,
                state=TaskState.running, detail=req.detail,
            ))
            try:
                summary = await run_task(req)
                self._emit(TaskEvent(
                    id=task_id, kind=req.kind, title=title,
                    state=TaskState.succeeded, summary=summary, detail=req.detail,
                ))
            except asyncio.CancelledError:
                self._emit(TaskEvent(
                    id=task_id, kind=req.kind, title=title,
                    state=TaskState.cancelled, detail=req.detail,
                ))
                raise
            except Exception as exc:  # noqa: BLE001 - surface any agent failure
                log.exception("task %s failed", task_id)
                self._emit(TaskEvent(
                    id=task_id, kind=req.kind, title=title, state=TaskState.failed,
                    summary=f"That task failed: {exc}", detail=req.detail,
                ))

    def _emit(self, event: TaskEvent) -> None:
        self._snapshots[event.id] = event
        # Prune long-finished snapshots so the map doesn't grow unbounded.
        if event.state in (TaskState.succeeded, TaskState.failed, TaskState.cancelled):
            try:
                asyncio.get_running_loop().call_later(60, self._snapshots.pop, event.id, None)
            except RuntimeError:
                pass  # no running loop (shouldn't happen in normal request flow)
        for q in list(self._subscribers):
            q.put_nowait(event)
