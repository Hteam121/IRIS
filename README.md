# IRIS — Intelligent Realtime Intelligence System

> A native **Swift/macOS** floating voice assistant — your own Jarvis. A transparent,
> always-on-top orb sits near your cursor; say **"Hey IRIS"** and talk to it. IRIS holds a
> real-time spoken conversation, sees your screen, controls your Mac, runs background research
> agents, and **learns from you** so it gets more useful over time.

This guide gets you from a fresh clone to your own running copy of IRIS on your Mac, using your
own API keys.

---

## What IRIS can do

- 🎙️ **Real-time voice** — continuous "Hey IRIS" conversation via the OpenAI Realtime API (speech
  in, natural speech out), with barge-in and auto-sleep to save cost.
- 👁️ **Screen vision** — "What's on my screen?" / "Summarize this page." It captures the display
  and reasons about it.
- 🧠 **AI brain** — routes your requests through **Claude** (`claude -p`, your subscription) with an
  Anthropic API fallback for true base64 vision.
- 🖱️ **Mac control** — opens apps, folders, terminals, and **Claude Code** sessions; creates
  folders; runs web searches; and can type/click/press keys (Accessibility).
- 🤖 **Background agents** — long-running research/tasks via a local Python **LangGraph** sidecar.
  They're **steerable**: a blocked agent can ask you a question and resume with your answer, and
  you can redirect a running task ("look elsewhere").
- 💾 **Self-learning memory** — tell it something once ("remember I prefer Chrome") and it persists
  in `~/.iris/memory.json` (+ a readable `~/.iris/IRIS.md`), recalled into every future session.
- 💸 **Cost governor** — meters OpenAI spend against a monthly budget and gracefully degrades
  (realtime → free `claude -p` → on-device voice) as the budget is consumed.
- 🪟 **Unobtrusive** — borderless floating orb, menu-bar 👁 toggle, **no dock icon**.

---

## Requirements

| Need | Why |
| --- | --- |
| **macOS 13+** (14+ recommended) | Screen capture (`SCScreenshotManager`) needs macOS 14 at runtime. |
| **Xcode 15+** + Command Line Tools | Builds the app (Swift 5 language mode). |
| **Homebrew** | Installs `xcodegen` and `node`. |
| **[`xcodegen`](https://github.com/yonaskolb/XcodeGen)** | Generates `IRIS.xcodeproj` from `project.yml`. |
| **Node.js** | Needed by the `claude` CLI and the Google Calendar MCP server. |
| **Python 3.11 or 3.12** | Optional — only for the background-agents sidecar. |
| **An Apple ID / Developer account** | To code-sign the app for your own machine (free tier is fine). |

### API keys & accounts

| Key / account | Recommended? | What it powers |
| --- | --- | --- |
| **OpenAI API key** | ✅ **Recommended** | The real-time "Hey IRIS" voice (Realtime API), neural text-to-speech, spoken-intent routing, and screen-vision. Without it, IRIS falls back to the classic wake-word pipeline + on-device voice. |
| **Claude subscription** (via the [`claude` Code CLI](https://docs.claude.com/en/docs/claude-code)) | ✅ **Basically required** | IRIS's main brain runs through `claude -p`, which uses your Claude Pro/Max **subscription** — no per-token API cost, and it tracks the latest Claude models as they ship. This is the best, most up-to-date way to run IRIS. |
| **Anthropic API key** | Optional | Alternative to the subscription: enables the Anthropic Messages API path with true base64 screen vision. Set `ANTHROPIC_API_KEY` and IRIS uses it automatically. |

> **TL;DR:** add an **OpenAI API key** for the full voice experience, and sign in to **Claude
> Code** with your subscription (or set an Anthropic API key) for the brain.

---

## Setup

### 1. Clone and bootstrap

```bash
git clone https://github.com/Hteam121/IRIS.git
cd IRIS
./setup.sh        # checks macOS/tools, installs xcodegen + node + claude (via brew/npm), creates .env
```

`setup.sh` is idempotent and only installs what's missing. If you don't have Homebrew, install it
from [brew.sh](https://brew.sh) first.

### 2. Add your keys

`setup.sh` copies `.env.example` → `.env`. Edit `.env` (or `~/.iris/config.json`) and add at least:

```bash
OPENAI_API_KEY=sk-...        # for real-time voice, neural TTS, vision (recommended)
ANTHROPIC_API_KEY=           # optional — leave blank to use your Claude subscription via `claude`
```

Then sign in to Claude Code once so the subscription path works:

```bash
claude            # follow the login prompt (uses your Claude Pro/Max subscription)
```

See [Configuration](#configuration) for the full list of options.

### 3. Generate the Xcode project

```bash
xcodegen generate     # creates IRIS.xcodeproj from project.yml
```

### 4. Set your code-signing identity ⚠️ (required for a fresh clone)

`project.yml` ships with the original author's signing identity, which **won't exist in your
keychain**. Point it at your own Apple ID before building. Easiest path:

1. Open the project in Xcode: `open IRIS.xcodeproj`
2. Select the **IRIS** target → **Signing & Capabilities**.
3. Check **Automatically manage signing** and pick your **Team** (your Apple ID).

…or edit `project.yml` and re-run `xcodegen generate`:

```yaml
settings:
  base:
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: "YOUR_TEAM_ID"     # from your Apple Developer account
    # remove/replace the CODE_SIGN_IDENTITY line (it pins a specific cert SHA-1)
```

> **Why a real signing identity matters:** macOS ties microphone/screen-recording permissions
> (TCC) to your code-signing identity. A **stable** identity keeps those grants across rebuilds;
> ad-hoc signing (`-`) re-prompts on every build. Automatic signing with your team is the simplest
> stable option.

### 5. Build & run

In Xcode press **▶︎ Run** (or `⌘R`). IRIS launches as a menu-bar app (look for the 👁 in the menu
bar — there's no dock icon). On first launch, grant the permissions below.

### Run it like a normal app (no Xcode each time)

To stop launching from Xcode, build a Release copy and drop it in `/Applications`:

```bash
./scripts/install-app.sh
```

This builds a Release `IRIS.app`, installs it to **`/Applications`**, and launches it. From then on
it's a normal app — open it from Spotlight/Finder, or add it to **System Settings → General → Login
Items** to start at boot. (Building still needs Xcode; *running* the installed app does not.)

### 6. (Optional) Background-agents sidecar

For long-running research/agent tasks, set up the Python sidecar:

```bash
cd sidecar
./setup.sh        # creates .venv and installs deps (FastAPI + LangGraph)
```

Then tell IRIS where the venv Python is — add to `~/.iris/config.json` (or `.env`):

```json
{ "sidecarPython": "/Users/you/Desktop/IRIS/sidecar/.venv/bin/python" }
```

IRIS spawns and supervises the sidecar automatically. See [`sidecar/README.md`](sidecar/README.md)
for Google Calendar (MCP) setup.

---

## Permissions

On first run, macOS prompts for these. IRIS can't function without them.

| Permission | Why | How to grant |
| --- | --- | --- |
| **Microphone** | Hear "Hey IRIS" and your commands. | Allow at the first-run prompt. |
| **Speech Recognition** | Wake-word / transcription. | Allow at the first-run prompt. |
| **Screen Recording** | Screen vision. | **Not grantable from a prompt** — enable IRIS in **System Settings → Privacy & Security → Screen Recording**, then **relaunch**. |
| **Accessibility** | Mac control (type / click / press keys). | Enable IRIS in **System Settings → Privacy & Security → Accessibility**. |
| **Automation (Terminal)** | Open Terminal / start Claude Code sessions. | Allowed at the first real prompt when IRIS opens Terminal. |

The app runs with the **App Sandbox disabled** (required to spawn `claude` and capture the screen).

---

## Talking to IRIS

Say the wake phrase, then your request:

| Say | What happens |
| --- | --- |
| "Hey IRIS, what time is it?" | Spoken answer. |
| "Hey IRIS, what's on my screen?" | Captures the screen and answers about it. |
| "Hey IRIS, open Chrome" / "open my Desktop" | Launches the app / opens the folder. |
| "Hey IRIS, create a folder called job hunter on my desktop" | Makes the folder and reveals it in Finder. |
| "Hey IRIS, search the web for noise-cancelling headphones" | Opens a browser search. |
| "Hey IRIS, find the top 3 deals on XM5 headphones" | Runs a **background agent**; it can ask you a question or be redirected mid-task. |
| "Hey IRIS, remember I prefer Chrome for searches" | Saves it to long-term memory; applied automatically next time. |
| "Hey IRIS, open a terminal and start Claude in my project" | Opens Terminal and a Claude Code session. |

The orb shows its state: **idle** (gray) → **listening** (blue) → **thinking** (purple) →
**speaking** (green).

---

## Configuration

IRIS reads settings from `.env` (in the repo root or `~/.iris/.env`) **and** `~/.iris/config.json`,
in increasing priority: process env → `.env` → `config.json`. Every value is optional. In
`config.json`, use the camelCase key (e.g. `realtimeVoice`); in `.env`, use the `IRIS_*` env var.

| Env var | `config.json` key | Default | Purpose |
| --- | --- | --- | --- |
| `OPENAI_API_KEY` | `openAIAPIKey` | _(unset)_ | Real-time voice, neural TTS, intent routing, vision. |
| `ANTHROPIC_API_KEY` | `anthropicAPIKey` | _(unset)_ | Use the Anthropic Messages API (true vision) instead of the `claude` subscription. |
| `IRIS_MODEL` | `model` | `claude-sonnet-4-6` | Claude model. `claude-opus-4-8` (most capable) or `claude-haiku-4-5` (fastest) also work. |
| `IRIS_WAKE_PHRASE` | `wakePhrase` | `hey iris` | Wake phrase (case-insensitive). |
| `IRIS_REALTIME` | `realtimeEnabled` | `true` | Use the OpenAI Realtime voice core (needs an OpenAI key). |
| `IRIS_REALTIME_MODEL` | `realtimeModel` | `gpt-realtime-mini` | Realtime model. |
| `IRIS_REALTIME_VOICE` | `realtimeVoice` | `marin` | Realtime voice (marin, cedar, alloy, ash, sage, verse…). |
| `IRIS_TTS_VOICE` | `ttsVoice` | `sage` | Neural TTS voice (OpenAI `gpt-4o-mini-tts`). |
| `IRIS_IDLE_PAUSE` | `idlePauseSeconds` | `15` | Seconds of silence before the realtime stream sleeps. |
| `IRIS_COMPUTER_USE` | `computerUseEnabled` | `true` | Allow Mac control (type/click) via Accessibility. |
| `IRIS_MEMORY` | `memoryEnabled` | `true` | Enable the self-learning memory. |
| `IRIS_MONTHLY_BUDGET` | `monthlyBudgetUSD` | `20` | Monthly OpenAI spend cap in USD (`0` = unlimited). |
| `IRIS_SIDECAR_PYTHON` | `sidecarPython` | _(unset)_ | Path to the sidecar venv Python (enables background agents). |
| `IRIS_CLAUDE_BINARY` | `claudeBinary` | _(auto)_ | Override the `claude` path (auto-resolves `~/.local/bin`, Homebrew, `/usr/local/bin`). |

> More keys exist (TTS rate/instructions, echo cancellation, agent model, sidecar port, etc.) —
> see `IRIS/Config/Settings.swift` for the full list. Secrets in `.env`/`config.json` live outside
> the repo and are git-ignored.

---

## How it works

```
"Hey IRIS"  ──►  Realtime voice (OpenAI Realtime API)  ──►  tool calls
                    │                                          ├─ open app / folder / terminal
                    │                                          ├─ create folder, web search
                    │                                          ├─ look at screen (vision)
                    │                                          ├─ type / press key / click (Mac control)
                    │                                          ├─ remember / forget (memory)
                    │                                          └─ run / steer background agents ──► Python LangGraph sidecar
                    │
        no OpenAI key │  falls back to
                    ▼
            Classic wake word  ──►  IRISBrain.ask()  ──►  Anthropic API (if key) or `claude -p` (subscription)  ──►  spoken reply
```

Shared state flows through `AppState` (`@MainActor ObservableObject`); the orb/overlay react to
`AppState.status`. Architecture details are in `plan.md`; tuned constants in `docs/algorithms.md`;
a running change log in `docs/timeline/`.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| **Build fails on signing** (`No signing certificate` / unknown identity) | Set your own Team in Xcode (Signing & Capabilities → Automatically manage signing), or edit `project.yml` `DEVELOPMENT_TEAM` / `CODE_SIGN_STYLE` and re-run `xcodegen generate`. See step 4. |
| **`claude` not found** | Install Claude Code: `npm install -g @anthropic-ai/claude-code`, then run `claude` once to log in. Or set `ANTHROPIC_API_KEY`. |
| **Mic seems on but IRIS never hears me** (silence) | A known TCC gotcha after re-signing: `tccutil reset Microphone com.iris.app`, then relaunch and re-allow the mic prompt. |
| **Screen vision says it can't capture** | Enable IRIS under System Settings → Privacy & Security → Screen Recording, then **relaunch**. |
| **No real-time voice** | Real-time voice needs `OPENAI_API_KEY`. Without it, IRIS uses the classic wake-word pipeline + on-device TTS. |
| **It says budget reached / switched to free mode** | You hit `IRIS_MONTHLY_BUDGET`. Raise it (or set `0` for unlimited) in `.env`/`config.json`. |
| **Background tasks don't run** | Set up the sidecar (step 6) and set `sidecarPython`. Check it's healthy: `curl localhost:8765/health`. |
| **Logs** | IRIS writes to `~/.iris/iris.log` — `tail -f ~/.iris/iris.log`. |

---

## Distributing IRIS (it's open source)

IRIS is open source under the [MIT license](LICENSE) — anyone can clone, build, modify, and
redistribute it. Two distinct audiences:

- **Developers** clone the repo and build from source (needs Xcode + `xcodegen`).
- **Everyone else** should get a **pre-built `IRIS.app`** and just double-click it — they need
  **no Xcode and no toolchain**, because macOS ships the Swift runtime.

To publish builds others can run without a toolchain, the maintainer signs the app with a
**Developer ID** certificate and **notarizes** it with Apple (`notarytool` + `stapler`), then
uploads a `.dmg`/`.zip` to **GitHub Releases**. Notarization (a paid Apple Developer account) is
what lets recipients open it with no Gatekeeper warning. Open source and signed binaries coexist
fine: the source stays public, while the official downloads are signed by the maintainer's
identity (your signing certificate is a secret and never goes in the repo — forks sign with their
own). Two honest caveats for downloaders: IRIS still needs the **`claude` CLI** (a Claude login)
for its brain and an **OpenAI key** for real-time voice, so a first run involves a little setup.

## Project layout

- `IRIS/` — Swift sources (Core contract, Config, UI, Voice/Audio, Vision, Realtime, Actions, AI).
- `sidecar/` — Python FastAPI + LangGraph background-agent service.
- `project.yml` — XcodeGen spec (generates `IRIS.xcodeproj`).
- `plan.md` — build plan / architecture. `docs/` — `algorithms.md` + `timeline/` change log.
- `CLAUDE.md` — guidance for working in this repo with Claude Code.

---

## License

[MIT](LICENSE).
