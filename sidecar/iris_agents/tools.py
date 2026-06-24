"""LangChain tools for IRIS agents: web search/fetch + a Terminal launcher.

`tools_for(kind)` returns the tool subset appropriate to a task kind, including any
Google Calendar tools loaded from an MCP server (see mcp.py).
"""

from __future__ import annotations

import asyncio
import logging
import os
import shlex
import subprocess

from langchain_core.tools import tool

from .mcp import get_mcp_tools
from .models import TaskKind

log = logging.getLogger("iris.tools")


# ---- web --------------------------------------------------------------------

def _web_search_tool():
    """Prefer Tavily (richer) when a key is set, else DuckDuckGo (no key)."""
    if os.environ.get("TAVILY_API_KEY"):
        try:
            from langchain_community.tools.tavily_search import TavilySearchResults
            return TavilySearchResults(max_results=5)
        except ImportError:
            log.warning("TAVILY_API_KEY set but langchain_community Tavily unavailable")
    try:
        from langchain_community.tools import DuckDuckGoSearchResults
        return DuckDuckGoSearchResults(num_results=6)
    except ImportError:
        log.warning("no web search backend available (install duckduckgo-search or set TAVILY_API_KEY)")
        return None


@tool
async def fetch_url(url: str) -> str:
    """Fetch a web page and return its readable text (truncated). Use for product/price pages."""
    import httpx

    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=20) as client:
            resp = await client.get(url, headers={"User-Agent": "Mozilla/5.0 IRIS-agent"})
            resp.raise_for_status()
            text = resp.text
    except Exception as exc:  # noqa: BLE001
        return f"Failed to fetch {url}: {exc}"

    # Cheap HTML→text: strip tags. Good enough for an LLM to read prices.
    import re

    text = re.sub(r"(?is)<(script|style).*?</\1>", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:8000]


# ---- terminal / claude code -------------------------------------------------

def _launch_terminal_claude(directory: str, claude_binary: str | None = None) -> str:
    directory = os.path.expanduser(directory or "~")
    claude = claude_binary or os.environ.get("IRIS_CLAUDE_BINARY") or "claude"
    shell_cmd = f"cd {shlex.quote(directory)} && {shlex.quote(claude)}"
    # Escape for an AppleScript string literal.
    as_literal = shell_cmd.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        'tell application "Terminal"\n'
        "    activate\n"
        f'    do script "{as_literal}"\n'
        "end tell"
    )
    try:
        subprocess.run(["/usr/bin/osascript", "-e", script], check=True,
                       capture_output=True, text=True, timeout=20)
    except subprocess.CalledProcessError as exc:
        return f"Failed to open Terminal: {exc.stderr.strip() or exc}"
    except Exception as exc:  # noqa: BLE001
        return f"Failed to open Terminal: {exc}"
    return f"Opened a terminal in {directory} and started Claude Code."


@tool
async def open_terminal_claude(directory: str) -> str:
    """Open the macOS Terminal in `directory` and start a `claude` Code session there."""
    return await asyncio.to_thread(_launch_terminal_claude, directory)


# ---- selection --------------------------------------------------------------

async def tools_for(kind: TaskKind) -> list:
    search = _web_search_tool()
    web = [t for t in (search, fetch_url) if t is not None]
    calendar = await get_mcp_tools()

    if kind == TaskKind.web:
        return web
    if kind == TaskKind.calendar:
        return calendar or web  # fall back to web if no calendar MCP configured
    if kind == TaskKind.terminal:
        return [open_terminal_claude]
    # agent: everything
    return web + calendar + [open_terminal_claude]
