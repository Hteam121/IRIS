"""LangGraph agent construction + execution.

`run_task` builds a ReAct agent (Claude via langchain-anthropic) with the tool
subset appropriate to the task kind, runs it to completion, and returns a single
spoken-friendly sentence to hand back to IRIS for TTS.

Heavy imports (langchain / langgraph) are lazy so the FastAPI server can boot and
serve /health even before dependencies are installed — in that "degraded" mode
tasks return a clear stub message instead of crashing.
"""

from __future__ import annotations

import logging
import os

from .models import TaskKind, TaskRequest

log = logging.getLogger("iris.agent")

DEFAULT_MODEL = os.environ.get("IRIS_AGENT_MODEL", "claude-sonnet-4-6")

SYSTEM_PROMPT = (
    "You are an IRIS background agent operating autonomously on the user's Mac. "
    "Carry out the task using the tools available to you. Be efficient and decisive. "
    "When finished, reply with ONE concise sentence that will be spoken aloud — "
    "plain prose only, no markdown, lists, code fences, emoji, or raw URLs read verbatim."
)


def title_for(req: TaskRequest) -> str:
    """Short label for the IRIS overlay pill."""
    if req.title:
        return req.title
    snippet = req.detail.strip()
    if len(snippet) > 32:
        snippet = snippet[:29].rstrip() + "…"
    return {
        TaskKind.calendar: "Calendar appointment",
        TaskKind.web: snippet or "Web search",
        TaskKind.terminal: "Terminal session",
        TaskKind.agent: snippet or "Agent task",
    }[req.kind]


def _seed_message(req: TaskRequest) -> str:
    detail = req.detail.strip()
    if req.kind == TaskKind.web:
        return (
            f"Find current, specific deals and prices for: {detail}. "
            "Use web search and fetch pages as needed. Report the best option(s) and where."
        )
    if req.kind == TaskKind.calendar:
        return (
            f"Schedule this on my Google Calendar: {detail}. "
            "Use the calendar tools to create the event with a sensible title, date, and time. "
            "Confirm what you scheduled and when."
        )
    if req.kind == TaskKind.terminal:
        cwd = req.cwd or "the default directory"
        return f"Open a terminal in {cwd} and start a Claude Code session. Task: {detail}"
    return detail


async def run_task(req: TaskRequest) -> str:
    """Run the agent to completion and return a spoken summary sentence."""
    try:
        return await _run_react_agent(req)
    except ImportError as exc:
        log.warning("agent dependencies unavailable, returning stub: %s", exc)
        return (
            f"I can't run that yet — the agent dependencies aren't installed. ({req.detail})"
        )


def _make_llm(model: str | None):
    """Build the agent LLM from whichever API key is available. Prefers Anthropic for claude
    models; otherwise uses OpenAI (so it works with just an OpenAI key — what most IRIS users
    already have). Returns None if no usable key is set."""
    has_anthropic = bool(os.environ.get("ANTHROPIC_API_KEY"))
    has_openai = bool(os.environ.get("OPENAI_API_KEY"))
    requested = (model or DEFAULT_MODEL).strip()
    wants_openai = requested[:2] in ("gp", "o1", "o3", "o4")  # gpt-*, o1/o3/o4-*

    if has_anthropic and (requested.startswith("claude") or not has_openai):
        from langchain_anthropic import ChatAnthropic
        model_id = requested if requested.startswith("claude") else "claude-sonnet-4-6"
        return ChatAnthropic(model=model_id, max_tokens=1024, timeout=120, max_retries=2)
    if has_openai:
        from langchain_openai import ChatOpenAI
        model_id = requested if wants_openai else "gpt-4o"
        return ChatOpenAI(model=model_id, timeout=120, max_retries=2)
    if has_anthropic:
        from langchain_anthropic import ChatAnthropic
        return ChatAnthropic(model="claude-sonnet-4-6", max_tokens=1024, timeout=120, max_retries=2)
    return None


async def _run_react_agent(req: TaskRequest) -> str:
    # Lazy heavy imports.
    from langchain_core.messages import HumanMessage, SystemMessage
    from langgraph.prebuilt import create_react_agent

    from .tools import tools_for

    llm = _make_llm(req.model)
    if llm is None:
        return (
            "I can't run background tasks without an API key — set OPENAI_API_KEY "
            "(or ANTHROPIC_API_KEY) for the sidecar."
        )

    tools = await tools_for(req.kind)
    agent = create_react_agent(llm, tools)

    messages = [
        SystemMessage(content=SYSTEM_PROMPT),
        HumanMessage(content=_seed_message(req)),
    ]
    # Cap the loop so a confused agent can't run forever.
    result = await agent.ainvoke(
        {"messages": messages},
        config={"recursion_limit": int(os.environ.get("IRIS_RECURSION_LIMIT", "40"))},
    )
    return _final_text(result)


def _final_text(result) -> str:
    """Extract the last assistant message's plain text from a LangGraph result."""
    messages = result.get("messages", []) if isinstance(result, dict) else []
    for msg in reversed(messages):
        content = getattr(msg, "content", None)
        if content is None:
            continue
        if isinstance(content, str):
            text = content.strip()
        elif isinstance(content, list):
            # Anthropic block format: list of {"type": "text", "text": ...} dicts.
            parts = [
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            ]
            text = " ".join(p for p in parts if p).strip()
        else:
            text = str(content).strip()
        if text:
            return text
    return "I finished, but didn't produce a summary."
