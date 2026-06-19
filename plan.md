# IRIS — Build Plan (3-Agent Kanban)

> **Note:** Execution step #1 is to copy this file to `/Users/shaikhatim/Desktop/IRIS/plan.md` so the Kanban board lives in the repo.

## Context

IRIS is a native Swift/macOS floating voice assistant: a transparent always-on-top panel near the cursor, "Hey IRIS" wake word, screen vision, AI routed through `claude -p` (subscription) with an Anthropic API fallback, and TTS replies. The repo is empty (greenfield). Goal: a `.app` that builds via `xcodebuild` and runs end-to-end after first-run permission grants.

**Confirmed decisions:**
- **AI/Vision = Hybrid.** Default to `claude -p` (no key) with the screenshot written to a temp PNG and its path passed in the prompt. If `ANTHROPIC_API_KEY` is present, use the Messages API with real base64 vision instead.
- **Scope = full** (all 9 phases).
- **Build tooling = `xcodegen`** (installed) generates `IRIS.xcodeproj` from `project.yml` — far more robust than a hand-written `pbxproj`.

## Environment (verified)
macOS 26.3 · Xcode 26.2 · Swift 6.2 · `xcodegen`, `claude` (`~/.local/bin/claude`), `node` all present.

## Key corrections to the original spec (these are non-negotiable fixes)
1. **`claude` not on GUI PATH.** A Finder/Xcode-launched app has a minimal `PATH`; bare `bash -c "claude ..."` fails. → `Settings.resolveClaudeBinary()` checks `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then `/bin/zsh -lic 'which claude'`; cache result.
2. **No giant base64 in argv.** `echo '<base64>' | claude -p` exceeds `ARG_MAX` and isn't read as an image. → write prompt to a temp file, pipe via **stdin**; pass the screenshot as a temp **PNG file path** (CLI) or base64 content block (API).
3. **App Sandbox OFF.** Spawning the `claude` subprocess + screen capture require it; entitlements disable sandbox, enable outgoing network (for API fallback).
4. **Swift language mode = 5.** Pin `SWIFT_VERSION: 5.0` so Swift 6 strict-concurrency doesn't reject the code; still annotate UI/state with `@MainActor`.
5. **Speech session limits + self-hearing.** `SFSpeechRecognizer` caps ~1 min → periodic restart timer. Pause recognition while `Speaker` is talking (shared flag in `AppState`) to avoid IRIS hearing itself.
6. **ScreenCaptureKit fixes.** Use `SCScreenshotManager.captureImage` (macOS 14+); build `NSImage` with the real pixel size and export **PNG**, not `.zero`/TIFF.

---

## Architecture & shared contract (authored in Phase 0, frozen before fan-out)

`Core.swift` defines everything the parallel lanes share, so lanes never edit the same file:
- `enum IRISStatus { idle, listening, thinking, speaking }`
- `@MainActor final class AppState: ObservableObject { @Published status; @Published responseText; @Published isSpeaking }`
- `protocol IRISResponder { func ask(transcript:String, screenshotPath:String?) async -> String }`
- `struct Settings` — loads `.env` / `~/.iris/config.json`: `claudeBinary`, `anthropicAPIKey?`, `model` (default `claude-sonnet-4-6`, configurable to `claude-haiku-4-5-20251001` for speed), `voice`, `ttsRate`, `wakePhrase`. Includes `resolveClaudeBinary()`.

**File-ownership rule (prevents merge conflicts):** each agent owns a disjoint set of files. Only Phase 0 (`Core.swift`, `Settings.swift`, project config) and Phase 2 (`AppDelegate.swift`) are written by a single agent.

---

## The Kanban Board

Three lanes (Agent 1 / Agent 2 / Agent 3) run concurrently within each phase. **Phases are barriers** — all three lanes finish a phase before the next begins, because Phase 2 integration depends on every Phase 1 file.

```
        AGENT 1 (lane A)         AGENT 2 (lane B)          AGENT 3 (lane C)
PHASE 0 ┌─────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
(gate)  │ project.yml         │ │ LICENSE (MIT)        │ │ README.md skeleton   │
        │ Info.plist          │ │ .env.example         │ │ (sections, command   │
        │ IRIS.entitlements   │ │ setup.sh             │ │  table, perms notes) │
        │ Core.swift          │ │                      │ │                      │
        │ Settings.swift      │ │ (no code deps)       │ │ (no code deps)       │
        └─────────┬───────────┘ └──────────────────────┘ └──────────────────────┘
                  │  ⟵ BARRIER: Core.swift contract must merge before Phase 1 ⟶
PHASE 1 ┌─────────▼───────────┐ ┌──────────────────────┐ ┌──────────────────────┐
(fan-   │ UI LANE             │ │ VOICE + AUDIO LANE   │ │ VISION + AI LANE     │
 out)   │ FloatingPanel.swift │ │ WakeWordDetector.s   │ │ ScreenCapture.swift  │
        │ OverlayView.swift   │ │ Transcriber.swift    │ │ IRISBrain.swift      │
        │ (OrbView)           │ │ Speaker.swift        │ │  (hybrid routing)    │
        │ StatusBarItem.swift │ │                      │ │ AgentMode.swift      │
        └─────────┬───────────┘ └──────────┬───────────┘ └──────────┬───────────┘
                  │  ⟵ BARRIER: all feature files exist & compile in isolation ⟶
PHASE 2 ┌─────────▼───────────┐ ┌──────────▼───────────┐ ┌──────────▼───────────┐
(integ) │ INTEGRATION (solo)  │ │ README finalize      │ │ TROUBLESHOOTING.md   │
        │ AppDelegate.swift   │ │ (real usage, demo    │ │ + verify setup.sh    │
        │ IRISApp.swift       │ │  gif placeholder)    │ │   on clean checkout  │
        │ wire all components │ │                      │ │                      │
        │ xcodegen+xcodebuild │ │                      │ │                      │
        │ fix compile/concur. │ │                      │ │                      │
        └─────────┬───────────┘ └──────────────────────┘ └──────────────────────┘
                  │
PHASE 3  VERIFICATION (you + me): build, launch, grant TCC, smoke test all commands
```

### Run order in plain terms
1. **Phase 0 first.** Agent 1 builds the project skeleton + shared contract; Agents 2 & 3 do dependency-free tooling/docs in parallel (no idle agents). **Gate:** Phase 0 merges before anyone starts Phase 1.
2. **Phase 1 = the real parallelism.** Three feature lanes, fully independent (disjoint files, only depend on `Core.swift`). This is where 3-at-once pays off.
3. **Phase 2.** Integration is **solo on Agent 1** (touches one file, depends on all lanes); Agents 2 & 3 finish docs in parallel.
4. **Phase 3.** Manual verification.

### What can / cannot be parallel
- **Parallel:** all of Phase 1; all of Phase 0 except the order that `Core.swift` must exist before Phase 1; docs in Phases 0 & 2.
- **Serial (gates):** Phase 0 → Phase 1 (need the contract), Phase 1 → Phase 2 (need all files), Phase 2 → Phase 3 (need a building app).

---

## Per-task detail

### Phase 0 — Foundation
- **`project.yml`** (xcodegen): app target `IRIS`, bundle id `com.iris.app`, `DEPLOYMENT_TARGET 13.0`, `SWIFT_VERSION 5.0`, `LSUIElement: YES` (no dock icon), Info.plist + entitlements wired, automatic signing for local dev.
- **`Info.plist`**: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSScreenCaptureUsageDescription`.
- **`IRIS.entitlements`**: `com.apple.security.app-sandbox = false`, `com.apple.security.network.client = true`.
- **`Core.swift` + `Settings.swift`**: shared types above; config loader; `resolveClaudeBinary()`.

### Phase 1 — Feature lanes
- **Lane A (UI):** `FloatingPanel` (borderless non-activating `NSPanel`, `.floating`, joins all spaces, `followCursor()`); `OverlayView` + animated `OrbView` driven by `AppState.status`; `StatusBarItem` (menu-bar 👁 toggle + quit).
- **Lane B (Voice+Audio):** `WakeWordDetector` (continuous `SFSpeechRecognizer`, "hey iris" trigger, ~50s restart timer, pause while `isSpeaking`); `Transcriber` (post-wake command capture); `Speaker` (`AVSpeechSynthesizer`, sets `isSpeaking`, `onFinished` resumes mic).
- **Lane C (Vision+AI):** `ScreenCapture` (ScreenCaptureKit → temp PNG path); `IRISBrain` implements `IRISResponder` with **hybrid routing** (API if key else `claude -p` via stdin; routes "iris agent" → `AgentMode`); `AgentMode` (spawns `claude -p` for agentic tasks, returns summary).

### Phase 2 — Integration (solo)
- `AppDelegate`: `.accessory` policy, build `AppState`, panel, status item, wire `WakeWordDetector.onWakeWordDetected` → capture → `IRISBrain.ask` → `Speaker.speak`, update `AppState`/`followCursor` on `@MainActor`.
- `IRISApp`: `@main`, `Settings { EmptyView() }`.
- Run `xcodegen generate` (Bash) to produce `IRIS.xcodeproj`, then **build via XcodeBuildMCP tools — never `xcodebuild` directly** (see `CLAUDE.md`); fix all compile/concurrency errors until green.

---

## Verification (Phase 3)
1. `xcodegen generate` (Bash), then build with **XcodeBuildMCP tools** (macOS workflow — e.g. `build_macos` / `build_run_macos`; **never `xcodebuild` directly**, per `CLAUDE.md`) → **must succeed**.
2. Launch the built `.app`; grant **Microphone**, **Speech Recognition**, **Screen Recording** on first prompt (Screen Recording requires toggling in System Settings → Privacy, then relaunch).
3. Smoke tests:
   - 👁 menu-bar icon present, no dock icon; floating orb visible near cursor.
   - "Hey IRIS, what time is it?" → orb cycles listening→thinking→speaking; spoken reply.
   - "Hey IRIS, what's on my screen?" → screenshot captured, contextual reply.
   - "IRIS agent, create a hello.txt file" → `AgentMode` runs `claude`, spoken summary.
4. Confirm `setup.sh` works on a clean clone (checks macOS ≥13, installs CLI tools / `claude`, copies `.env`).

## Risks / call-outs
- **claude CLI vision is best-effort** (reads a file path); the API path gives true vision — that's exactly why Hybrid exists.
- **Screen Recording TCC** can't be granted programmatically; needs your one-time toggle + relaunch.
- **Wake-word accuracy** with Apple Speech is decent but not Picovoice-grade; tunable later.
- Parallel agents stay conflict-free only because file ownership is disjoint and the `Core.swift` contract is frozen at the Phase 0 barrier.
