# CLAUDE.md — IRIS

Guidance for Claude Code when working in this repo. Read this first; load `docs/*.md` only on demand.

## Project

IRIS (Intelligent Realtime Intelligence System) — a native Swift/macOS floating voice
assistant, **user-facing name: Dory** ("Hey Dory" wake word, product `Dory.app`).
Internal identifiers deliberately keep the IRIS names: bundle id `com.iris.app`, `~/.iris/`
config dir, `IRIS_*` env vars, Swift type names, target/scheme `IRIS` — so TCC grants and
user data persist. Identity strings (name, triggers, system prompts) live in
`IRIS/Core/Persona.swift`; do not hardcode "Dory"/"IRIS" in user-facing strings elsewhere.

Transparent always-on-top panel near the cursor, wake word, screen vision, on-screen
pointing (PointerOverlay/ScreenPointer), markdown skills (`~/.iris/skills/`), local-first
answering (Ollama/Apple FM → cloud), AI routed through `claude -p` (subscription) with an
Anthropic API fallback, TTS replies. Menu-bar app, no dock icon. macOS 13+, Swift 5
language mode, built with `xcodegen`.

The authoritative build plan is `plan.md` (3-agent Kanban). Follow it.

## Build & Run Rules

- **Building: use XcodeBuildMCP tools.** `mcp__XcodeBuildMCP__*` (macOS workflow: `build_macos`,
  `build_run_macos`, etc., plus `discover_projs` / `list_schemes` / `show_build_settings`).
- **NEVER use `xcodebuild` directly** from Bash. Always go through XcodeBuildMCP tools.
- Project files are generated: run `xcodegen generate` (Bash is fine for this) to (re)create
  `IRIS.xcodeproj` from `project.yml`, then build via XcodeBuildMCP.
- At the start of a build session, call `mcp__XcodeBuildMCP__session_show_defaults` before the
  first build/run; use `discover_projs` only if project/scheme are unset.

## Docs (load on demand — do NOT read at startup)

- `docs/algorithms.md` — exact formulas & tuned constants. **When implementing any algorithm,
  animation, scaling, or timing, check `docs/algorithms.md` for the exact formula first.**
- `docs/timeline/YYYY-MM-DD.md` — running change log (see below).
- Reference these files only when a task touches them; never bulk-load all of `docs/`.

## Timeline Documentation

After completing each feature task or significant implementation step, append an entry to the
current day's file in `docs/timeline/` named `YYYY-MM-DD.md` (create it if missing).

Format:

```
## HH:MM — [Feature/Area] Short Description
- What was implemented
- Files created/modified
- Any decisions made or issues encountered
```

Keep entries concise and factual. One entry per completed task/step, newest appended at the bottom.

## Architecture & Conventions (from plan.md)

- **Shared contract lives in `IRIS/Core/Core.swift`** — `IRISStatus`, `AppState` (`@MainActor`
  `ObservableObject`), `IRISResponder`. Lanes depend on it but never edit it after Phase 0.
- **Config in `IRIS/Config/Settings.swift`** — loads `.env` / `~/.iris/config.json`:
  `claudeBinary`, `anthropicAPIKey?`, `model` (default `claude-sonnet-4-6`; `claude-haiku-4-5-20251001`
  for speed), `voice`, `ttsRate`, `wakePhrase`.
- **File ownership is disjoint per lane** to keep parallel work conflict-free. Only `Core.swift`,
  `Settings.swift`, project config (Phase 0) and `AppDelegate.swift` (Phase 2) are single-owner.

## Non-negotiable implementation fixes

1. **`claude` is not on the GUI `PATH`.** Resolve via `Settings.resolveClaudeBinary()`
   (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then `/bin/zsh -lic 'which claude'`); cache it.
2. **No giant base64 in argv.** Write the prompt to a temp file and pipe via **stdin**; pass the
   screenshot as a temp **PNG file path** (CLI) or a base64 content block (API). Never `echo '<base64>' | claude`.
3. **App Sandbox OFF** (`IRIS/IRIS.entitlements`): sandbox false, network client true.
4. **Swift language mode 5** (`SWIFT_VERSION: 5.0`); annotate UI/state with `@MainActor`.
5. **Speech: restart ~every 50s** (SFSpeechRecognizer ~1-min cap) and **pause recognition while
   `AppState.isSpeaking`** so IRIS doesn't hear its own TTS.
6. **ScreenCaptureKit:** `SCScreenshotManager.captureImage` (macOS 14+); build `NSImage` with the
   real pixel size and export **PNG** (not `.zero` / TIFF).

## AI Routing (post-reconstruction, 2026-07)

- `Router.swift` routes every command deterministically (zero LLM classifiers); unmatched
  commands fall through to `.answer`.
- `.answer` → `ClaudeEngine.swift`: local model first (Ollama/Apple FM), then streaming cloud —
  Anthropic Messages API (SSE, prompt caching, base64 vision, server-side web search on
  current-events cues) when `ANTHROPIC_API_KEY` is set, else `claude -p --output-format
  stream-json` via stdin (screenshot as temp PNG path + `--allowedTools Read`).
- Action commands ("create a file…") and "dory agent"/legacy "iris agent" transcripts →
  `ClaudeSessionManager.swift`: background `claude -p` stream-json sessions with live pill
  progress, narrated milestones, `--resume` continuity (`~/.iris/sessions.json`), and
  `--mcp-config ~/.iris/mcp.json` for calendar/MCP tools.
- `CompanionManager.swift` owns the whole pipeline (AppDelegate is a thin bootstrap);
  triggers are the wake word (bare-name allowed) and hold-⌥Space push-to-talk.

## Permissions

App needs Microphone, Speech Recognition, and Screen Recording (TCC). Screen Recording must be
toggled manually in System Settings → Privacy & Security, then relaunch — it can't be granted
programmatically. Usage strings live in `IRIS/Info.plist`.
