"""Load MCP server tools (e.g. Google Calendar) into LangChain via langchain-mcp-adapters.

Reads sidecar/mcp_servers.json — a map of server name → launch spec — and exposes
every server's tools to the agent. The result is cached for the process lifetime.

mcp_servers.json example (Google Calendar via the npm google-calendar MCP):

    {
      "google-calendar": {
        "command": "npx",
        "args": ["-y", "@cocal/google-calendar-mcp"],
        "transport": "stdio",
        "env": { "GOOGLE_OAUTH_CREDENTIALS": "~/.iris/gcp-oauth.keys.json" }
      }
    }

First run opens a Google consent screen; the MCP server caches the OAuth token.
If the file is missing or the adapter isn't installed, calendar tasks degrade to
web tools (no crash). See sidecar/README.md.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Optional

log = logging.getLogger("iris.mcp")

_CONFIG_PATH = Path(__file__).resolve().parent.parent / "mcp_servers.json"

_cached_tools: Optional[list] = None
_loaded = False


def _expand(spec: dict) -> dict:
    """Expand ~ and env in an MCP server spec's env values + args."""
    out = dict(spec)
    if "env" in out and isinstance(out["env"], dict):
        out["env"] = {
            k: os.path.expanduser(os.path.expandvars(str(v)))
            for k, v in out["env"].items()
        }
    if "args" in out and isinstance(out["args"], list):
        out["args"] = [os.path.expanduser(os.path.expandvars(str(a))) for a in out["args"]]
    out.setdefault("transport", "stdio")
    return out


async def get_mcp_tools() -> list:
    """Return MCP tools (cached). Empty list if nothing is configured/available."""
    global _cached_tools, _loaded
    if _loaded:
        return _cached_tools or []
    _loaded = True

    if not _CONFIG_PATH.exists():
        log.info("no mcp_servers.json at %s — calendar/MCP tools disabled", _CONFIG_PATH)
        _cached_tools = []
        return _cached_tools

    try:
        from langchain_mcp_adapters.client import MultiServerMCPClient
    except ImportError:
        log.warning("langchain-mcp-adapters not installed — MCP tools disabled")
        _cached_tools = []
        return _cached_tools

    try:
        raw = json.loads(_CONFIG_PATH.read_text())
        servers = {name: _expand(spec) for name, spec in raw.items()}
        client = MultiServerMCPClient(servers)
        _cached_tools = await client.get_tools()
        log.info("loaded %d MCP tool(s) from %s", len(_cached_tools), list(servers))
    except Exception as exc:  # noqa: BLE001 - never let MCP setup crash the agent
        log.exception("failed to load MCP tools: %s", exc)
        _cached_tools = []
    return _cached_tools or []
