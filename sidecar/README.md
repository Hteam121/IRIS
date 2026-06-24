# IRIS Agent Sidecar

A small FastAPI + LangGraph service that runs IRIS's background agents concurrently
and streams their state back to the IRIS macOS app over `localhost` (HTTP + SSE).

IRIS spawns and supervises this process automatically; you only need to install it
once and (optionally) configure Google Calendar.

## Setup

```bash
cd sidecar
./setup.sh                      # creates .venv and installs deps
```

Then tell IRIS where the venv Python is — add to `~/.iris/config.json` (or `.env`):

```json
{ "sidecarPython": "/Users/you/Desktop/IRIS/sidecar/.venv/bin/python" }
```

or set `IRIS_SIDECAR_PYTHON=/…/sidecar/.venv/bin/python`.

The sidecar needs an Anthropic key (it reuses `ANTHROPIC_API_KEY`, which IRIS passes
through when it launches the process).

## Run / test standalone

```bash
.venv/bin/python -m iris_agents.server          # serves on 127.0.0.1:8765
# in another shell:
curl localhost:8765/health
curl -N localhost:8765/events &                 # watch the SSE stream
curl -s -XPOST localhost:8765/tasks -H 'content-type: application/json' \
     -d '{"kind":"web","detail":"deals on Sony WH-1000XM5"}'
```

## Google Calendar (MCP)

```bash
cp mcp_servers.json.example mcp_servers.json
```

The example uses the `@cocal/google-calendar-mcp` npm server via `npx`. Put your
Google OAuth client credentials at `~/.iris/gcp-oauth.keys.json` (Desktop-app OAuth
client from Google Cloud Console, Calendar API enabled). The first calendar task
opens a browser consent screen; the MCP server caches the token afterwards.

If `mcp_servers.json` is absent or the MCP server can't start, calendar tasks fall
back to web tools and the agent reports it couldn't reach your calendar — nothing
crashes.

## HTTP API

| Method | Path                  | Body / result |
|--------|-----------------------|---------------|
| GET    | `/health`             | `{"ok": true}` |
| POST   | `/tasks`              | `{kind, detail, model?, cwd?, title?}` → `{"id"}` |
| GET    | `/events`             | SSE stream of `TaskEvent` JSON |
| POST   | `/tasks/{id}/cancel`  | `{"cancelled": bool}` |

`kind ∈ {calendar, web, agent, terminal}`,
`state ∈ {queued, running, succeeded, failed, cancelled}`.
