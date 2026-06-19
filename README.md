# IRIS — Intelligent Realtime Intelligence System

> A native Swift/macOS floating voice assistant. A transparent, always-on-top panel
> follows your cursor; say **"Hey IRIS"** to talk to it. IRIS can see your screen, route
> your request through Claude, and speak the answer back.

<!-- Phase 0 skeleton — finalized in Phase 2 (real usage, demo gif). -->

---

## Features

- 🎙️ **Wake word** — continuous listening for "Hey IRIS" (Apple `SFSpeechRecognizer`).
- 👁️ **Screen vision** — captures the current display and reasons about what's on it.
- 🧠 **Hybrid AI routing** — Anthropic Messages API when `ANTHROPIC_API_KEY` is set (true
  base64 vision), otherwise the `claude -p` CLI (subscription, no key) with the screenshot
  passed as a temp PNG path.
- 🤖 **Agent mode** — say "IRIS agent …" to spawn `claude` for agentic tasks.
- 🔊 **Spoken replies** — `AVSpeechSynthesizer` TTS; mic pauses while IRIS speaks.
- 🪟 **Unobtrusive** — borderless floating orb near the cursor, menu-bar 👁 toggle, **no dock icon**.

---

## Requirements

- macOS **13.0+** (Screen capture uses APIs that require macOS 14+ at runtime).
- Xcode 26 / Swift 6 toolchain (project builds in **Swift 5 language mode**).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — generates `IRIS.xcodeproj` from `project.yml`.
- The [`claude`](https://docs.claude.com/en/docs/claude-code) CLI on `PATH` (for the no-key path),
  **or** an `ANTHROPIC_API_KEY` (for the API path). Either is sufficient; both is fine.

---

## Setup

```bash
# 1. Clone, then run the bootstrap script (checks macOS version, tools, copies .env).
./setup.sh

# 2. Configure your environment.
cp .env.example .env        # then edit values (see Configuration below)

# 3. Generate the Xcode project and build.
xcodegen generate
# Build via XcodeBuildMCP tooling (see CLAUDE.md) — do NOT call `xcodebuild` directly.

# 4. Launch the built IRIS.app and grant permissions on first run (see Permissions).
```

> **Build note:** this project is always built through the XcodeBuildMCP tools, never with a
> bare `xcodebuild` invocation. See `CLAUDE.md` for the rationale and exact workflow.

---

## Voice commands

Speak the wake phrase, then your request. The wake phrase is matched case-insensitively.

| Say | What happens |
| --- | --- |
| **"Hey IRIS, what time is it?"** | General Q&A — spoken reply, no screenshot needed. |
| **"Hey IRIS, what's on my screen?"** | Captures the screen and answers with visual context. |
| **"Hey IRIS, summarize this page."** | Screen vision over whatever is in front. |
| **"IRIS agent, create a hello.txt file"** | Routes to **Agent mode** — spawns `claude` to perform the task, then speaks a summary. |

The orb cycles through its states as it works: **idle** (gray) → **listening** (blue) →
**thinking** (purple) → **speaking** (green).

---

## Configuration

IRIS reads settings from a `.env` file (see `.env.example`) and/or `~/.iris/config.json`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | _(unset)_ | If present, use the Anthropic Messages API (true vision). Otherwise fall back to the `claude` CLI. |
| `IRIS_MODEL` | `claude-sonnet-4-6` | Model id. Use `claude-haiku-4-5-20251001` for faster/cheaper replies. |
| `IRIS_WAKE_PHRASE` | `hey iris` | Wake phrase to listen for. |
| `IRIS_VOICE` | `en-US` | TTS voice language. |
| `IRIS_TTS_RATE` | `0.52` | TTS speaking rate. |
| `IRIS_CLAUDE_BINARY` | _(auto-resolved)_ | Override the `claude` binary path. Auto-resolution checks `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then `zsh -lic 'which claude'`. |

> **Why the binary is resolved manually:** a Finder/Xcode-launched app gets a minimal `PATH`,
> so a bare `claude` call fails. `Settings.resolveClaudeBinary()` locates and caches it.

---

## Permissions

On first run macOS will prompt for the following. IRIS cannot function without them.

| Permission | Why | How to grant |
| --- | --- | --- |
| **Microphone** | Hear the wake word and your commands. | Allow at the first-run prompt. |
| **Speech Recognition** | Transcribe speech to text. | Allow at the first-run prompt. |
| **Screen Recording** | Capture the screen for vision. | **Cannot be granted from a prompt** — toggle IRIS on in **System Settings → Privacy & Security → Screen Recording**, then **relaunch** the app. |

Usage descriptions are declared in `IRIS/Info.plist`. The app runs with the App Sandbox
**disabled** (required to spawn the `claude` subprocess and to capture the screen).

---

## How it works

```
Wake word → command capture → screen capture (PNG) → IRISBrain.ask() ──► API (if key)
                                                                    └──► claude -p (stdin + PNG path)
                                                                    └──► AgentMode (if "iris agent")
                                                          ↓
                                                   spoken reply (TTS)
```

State is shared through `AppState` (a `@MainActor ObservableObject`); the floating panel and orb
react to `AppState.status`. See `plan.md` for the full architecture and `docs/algorithms.md` for
tuned constants.

---

## Troubleshooting

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) _(added in Phase 2)_ for common issues
(no audio, `claude` not found, screen recording not taking effect until relaunch, etc.).

---

## Project layout

- `plan.md` — authoritative 3-agent build plan (Kanban).
- `CLAUDE.md` — guidance + build rules for working in this repo.
- `project.yml` — XcodeGen spec (generates `IRIS.xcodeproj`).
- `IRIS/` — Swift sources (Core contract, Config, UI, Voice/Audio, Vision/AI lanes).
- `docs/` — `algorithms.md` (constants/formulas) and `timeline/` (running change log).

---

## License

[MIT](LICENSE).
