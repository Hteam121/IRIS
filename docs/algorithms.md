# Algorithms & Tuned Constants

Exact formulas and magic numbers used across IRIS. Update this file when a constant changes;
implementation must match these values.

> **2026-07 reconstruction note:** the OpenAI Realtime speech-to-speech core and the LLM
> command classifiers (gpt-4o + `claude -p` JSON) were removed — routing is fully
> deterministic (`Router.swift`) and answering is one streaming `ClaudeEngine` call.
> Sections below that mention "realtime" or the classifier describe retired paths; the
> current constants are in the sections from "Cursor buddy" onward.

## Floating panel
- Panel size: `320 × 120` pt.
- Cursor offset: origin = `(mouse.x + 20, mouse.y - 60)` (place to lower-right of cursor).
- Window level: `.floating`; collection behavior: `[.canJoinAllSpaces, .fullScreenAuxiliary]`.

## Orb animation
- Diameter: `16 pt`.
- Pulse: `scaleEffect` between `1.0` and `1.3`, `easeInOut`, `duration 0.6s`, `repeatForever(autoreverses:)`.
- State → color: idle = gray, listening = blue, thinking = purple, speaking = green.

## Wake word / speech
- Wake phrase (default): `"hey dory"` (case-insensitive match on the transcript via
  `WakePhraseMatcher`). When the phrase is the default, a variant set of known
  SFSpeechRecognizer mishearings also matches: `hey dory / hey dori / hey dorie / hey dorey /
  hey dora / hey worried / hey dore / hey door e / hey door he / hey doree` — "worried" is
  the most common mishearing of "dough-ree" (observed live 2026-07-05). Tune live; each
  variant also widens the barge-in trigger, so don't add sound-alikes common in dictation
  (e.g. "hey story") without testing. A custom phrase matches as itself, no variants.
- Matching is punctuation/whitespace tolerant: each phrase compiles to a regex of its words
  joined by `[\s\p{P}]+`, word-bounded — so "Hey, worried." still matches. The remainder
  after the phrase is trimmed of punctuation + whitespace.
- Recognizer bias: `request.contextualStrings = ["Dory", "Hey Dory", "dory agent", <phrase>]`
  on both the wake detector and the Transcriber — the highest-leverage fix for "dory" being
  heard as "story"/"dori".
- Stale-config migration: a persisted `wakePhrase` equal to the pre-rename default
  (`"hey iris"`) is treated as "never customized" and replaced with the new default at
  `Settings.load()`; any other custom phrase is respected verbatim.
- Command extraction: strip the wake phrase prefix, trim whitespace; remainder is the command.
- Agent trigger: transcript contains `"dory agent"` (or the legacy `"iris agent"`) → route to
  AgentMode (strip + trim for the task; earliest trigger occurrence wins).
- Audio tap buffer size: `1024` frames; format = input node `outputFormat(forBus: 0)`.
- Session restart cadence: **~50s** (SFSpeechRecognizer caps near 60s); restart timer fires before the cap.
- Restart debounce after a detection/reset: `0.5s` before re-arming the recognizer.
- Self-hearing gate (plan.md fix #5): when **barge-in is disabled** (`bargeInEnabled = false`),
  pause recognition while IRIS is speaking so it never transcribes its own TTS. `AppState.isSpeaking`
  is mirrored (Combine) into a lock-guarded `muted` flag the realtime audio tap reads; while muted
  the tap drops mic buffers instead of appending them. (Do NOT enable input-node voice processing /
  AEC as an alternative — on macOS it can stop the engine from delivering input buffers, breaking
  recognition entirely.)
- Voice barge-in (default, `bargeInEnabled = true`): the tap KEEPS feeding the recognizer while
  IRIS speaks so the user can cut IRIS off — but **only the wake phrase** ("hey dory") triggers it.
  IRIS never says "hey dory", so its own TTS (or background noise) cannot self-trigger a barge-in;
  this avoids IRIS mistaking its own speaker output for the user. On a wake-phrase match while
  speaking, IRIS stops the current utterance and clears the spoken-output queue immediately, then
  captures the new command via the normal settle flow. ⌥⎋ remains a manual backup. Background
  agents are never affected. (We deliberately do NOT trigger on arbitrary speech — speaker bleed
  makes that unreliable.)
- Wake-utterance settle: after the wake phrase is heard, keep accumulating the same utterance
  until **`1.2s`** of no new partial results, then strip the prefix → that remainder is the command.

## Command capture (Transcriber)
- Used when the wake phrase had no trailing command ("hey dory" then a pause): capture the command
  as a fresh utterance.
- Silence finalize: end capture after **`1.5s`** with no new partial results.
- Hard max duration: **`12s`** safety cap so a capture never hangs open.
- On-device recognition preferred when `SFSpeechRecognizer.supportsOnDeviceRecognition` (offline, lower latency).

## Text-to-speech
- **Primary: OpenAI neural TTS** (natural voice) when an OpenAI key is set — `POST
  https://api.openai.com/v1/audio/speech`, model `gpt-4o-mini-tts` (configurable `IRIS_TTS_MODEL`),
  voice default `sage` (`IRIS_TTS_VOICE`; also alloy/ash/coral/verse/ballad/echo/onyx/fable/nova/
  shimmer), `instructions` tone steer (`IRIS_TTS_INSTRUCTIONS`), `response_format` mp3, played via
  `AVAudioPlayer`. Toggle with `IRIS_OPENAI_TTS`.
- **Fallback: AVSpeechSynthesizer** (offline) when no OpenAI key or on failure. Rate `0.52`
  (`IRIS_TTS_RATE`), pitch `1.0`, language `en-US` (`IRIS_VOICE`).
- Volume: `0.8` (a little below max so the mic can pick up the "hey dory" barge-in over IRIS's
  own speaker output).
- All output flows through one serialized queue so concurrent answers/announcements never overlap.

## Screen capture (ScreenCaptureKit)
- Use the first display from `SCShareableContent.current`.
- Config width/height = display pixel dimensions.
- Export as **PNG**; build `NSImage(cgImage:size:)` with the real pixel size (NOT `.zero`).
- Write to a temp file: `NSTemporaryDirectory()/iris-shot-<n>.png`; pass the path downstream.
- Optional downscale before sending to AI: cap longest edge at ~1568 px (Anthropic vision sweet spot)
  to reduce tokens/latency; preserve aspect ratio.

## AI routing
- Default model: `claude-sonnet-4-6`. Fast/cheap alternative: `claude-haiku-4-5-20251001`.
- Anthropic API: `POST https://api.anthropic.com/v1/messages`, header `anthropic-version: 2023-06-01`,
  `max_tokens` ~512 for concise spoken replies.
- System framing: "You are Dory… be concise, response will be spoken aloud, ≤3 sentences unless
  asked" — lives in `IRIS/Core/Persona.swift` (`spokenSystemPrompt`; the realtime persona is
  `realtimeInstructions`). When a screenshot is attached and pointing is on, `pointingHint`
  teaches the `[POINT:x,y:label]` tag (see Screen pointing).
- **Cost routing (CostGovernor):** prefer free `claude -p` for the text-brain call. Intent routing
  tries `strongHeuristic` first, then an LLM classifier, then the keyword `heuristic`. Classifier
  order is **budget-aware**: when the tier allows paid calls (`allowsPaidVision`) **and** an OpenAI
  key is set, the **fast gpt-4o** classifier runs first (the `claude -p` subprocess + sonnet adds
  multi-second latency), falling back to `claude -p`; once the budget is spent (`.free`) or no key
  is set, only the free `claude -p` classifier runs. The paid classifier's `usage` is metered
  (`recordVision`). Realtime screen-vision (`look_at_screen`) uses `claude -p --allowedTools Read` on
  the temp PNG; it falls through to gpt-4o when the `claude` binary is missing **or** the reply reads
  like a vision failure (e.g. "I can't see the image"). The gpt-4o fallback is tier-gated + metered.

## Cost Governor (budget-driven adaptation)
Meters real OpenAI spend against a user-set monthly cap (`Settings.monthlyBudgetUSD`, default **$20**,
`0` = unlimited) and degrades the experience as the cap is approached. Source: `IRIS/Core/CostGovernor.swift`.

- **Realtime model:** default **`gpt-realtime-mini`** (was `gpt-realtime`) — ~3.2× cheaper audio.
- **Metering (exact):** computed from each `response.done` `usage` (no estimation). Rates ($/1M tokens):
  - `gpt-realtime-mini`: audio in **$10**, audio in cached **$0.30**, audio out **$20**, text in
    **$0.60**, text in cached **$0.30**, text out **$2.40**.
  - `gpt-realtime` (full): audio in **$32**, cached **$0.40**, audio out **$64**, text in **$4**,
    cached **$0.40**, text out **$16**. Model→rate chosen by whether the id contains "mini".
  - Audio token rate (for reference): user audio = 1 token / 100 ms (≈600/min); assistant audio =
    1 token / 50 ms (≈1200/min).
  - TTS (`gpt-4o-mini-tts`): estimated at **$15 / 1M characters**, recorded per synthesis.
  - **Paid one-shot gpt-4o calls** (screen-rule vision match, `look_at_screen` OpenAI fallback,
    OpenAI command classifier): metered via `recordVision(usage:)` at **$2.50 / 1M input** and
    **$10 / 1M output** tokens, with a **$0.005** flat fallback when a response omits `usage`.
- **Paid-call gate (`allowsPaidVision`, == `tier != .free`):** every paid one-shot OpenAI call
  above is skipped in `.free`, so that tier's "zero OpenAI spend" guarantee actually holds.
- **Persistence:** `~/.iris/usage.json` = `{month, day, spentUSD, spentTodayUSD}`. Resets on month
  change; `spentTodayUSD` resets on day change. Rollover honored at load and on every access.
  Hot-path writes are **debounced ~1.5s** (coalesced) instead of one write per metered turn; a
  rollover writes immediately, and `flush()` (app termination) bypasses the debounce.
- **Tiers** (`tier()`), in order:
  - budget ≤ 0 → **premium** (unlimited).
  - remaining ≤ **$0.01** → **free**.
  - `spent / budget` ≥ **0.75** → **saver**.
  - daily pacing: `dailyAllowance = remaining / daysLeftInMonth(inclusive)`; if
    `spentTodayUSD ≥ dailyAllowance` → **saver** (throttle for the rest of today).
  - else → **premium**.
- **Behavior per tier:** premium = paid realtime (`gpt-realtime-mini`) conversation allowed;
  saver = realtime suppressed, classic pipeline (local-first router → free `claude -p`) answers
  each command; free = classic pipeline + on-device TTS (`allowsNeuralTTS == false`), zero
  OpenAI spend. In saver/free the LocalRouter loosens its pre-filters (word cap 30 → 60) so
  more traffic is answered by the free local model (see Local routing).
- **Decision point:** tier is evaluated at each wake (`AppDelegate.wakeUp`) — premium opens the paid
  realtime stream, saver/free leave the wake detector live so the captured command is answered by the
  free `claude -p` pipeline. **Mid-session ceiling:** a running realtime conversation is also checked
  after every `response.done` — once a turn's metered spend pushes the tier below premium
  (`allowsRealtime == false`), `onBudgetExhausted` ends the paid stream immediately (rather than
  letting one long sitting, whose idle timer resets each turn, blow past the cap); the next wake then
  re-checks and falls back to the free pipeline.

## Screen pointing (PointerOverlay + ScreenPointer)
Source: `IRIS/UI/PointerOverlay.swift`, `IRIS/Vision/ScreenPointer.swift`. "Show, don't do" —
an animated arrow flies to a screen location with a label bubble; it never clicks.

- **Capture resolution** (`ScreenCapture.captureForPointing`): pick by display aspect ratio —
  4:3 → **1024×768**, 16:10 → **1280×800**, 16:9 → **1366×768** (nearest aspect wins).
  Computer-Use models are calibrated near these sizes; off-aspect resizes distort X.
- **Locate:** Anthropic key set → ONE Messages call with the computer-use tool
  (`computer_20250124`, header `anthropic-beta: computer-use-2025-01-24`), instructing a single
  `mouse_move`; the tool_use `input.coordinate` is the answer. Fallback: JSON `{x,y}` via
  `claude -p --allowedTools Read` (free), then OpenAI vision (paid, `allowsPaidVision`-gated
  + metered).
- **Coordinate math** (three spaces — image px top-left, screen points top-left, AppKit global
  bottom-left; all conversion centralized in `ScreenPointer`):
  ```
  clamp:  xi = clamp(x, 0, imgW-1) ; yi = clamp(y, 0, imgH-1)
  scale:  px = xi × screenW/imgW  ; py = yi × screenH/imgH      (screen points, top-left)
  AppKit: gx = screenFrame.minX + px ; gy = screenFrame.maxY − py
  ```
  v1 targets the first/main display (matches `ScreenCapture`).
- **Overlay window:** borderless, `level = .screenSaver`, `collectionBehavior =
  [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`,
  `ignoresMouseEvents = true`, clear/no-shadow, `canBecomeKey/Main = false`.
- **Swoop animation:** `CAKeyframeAnimation(position)` along a quadratic Bézier; control point
  = midpoint offset perpendicular by `clamp(0.25 × distance, 60…220 pt)`; duration **0.6s**
  easeInEaseOut; label bubble fades in **0.2s** after arrival; auto-dismiss **4s**; pointer
  size 36 pt (tip = anchor). First show rises from the bottom edge.
- **Classic-pipeline fallback:** with a screenshot attached, the spoken prompt includes
  `Persona.pointingHint`; replies may embed `[POINT:x,y:label]` (regex
  `\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::([^\]]+))?\]`). Tags are stripped before speaking and
  each is rendered via the pointer, scaled from the shot's pixel size.

## Skills (capabilities as files)
Source: `IRIS/Core/Skills.swift`; files in `~/.iris/skills/*.md`; bundled examples seeded from
`Dory.app/Contents/Resources/Skills/` on first launch (only when the dir doesn't exist, so
deletions stick).

- **Frontmatter grammar** (deliberately tiny, no YAML dep): file starts `---`; flat
  `key: value` lines; `key:` alone opens a `- item` string list; closed by `---`; the rest is
  the body (the steps). Required: `name`, `description`, non-empty body. Optional: `mode`
  (`inline` default | `agent`), `tools` list (informational). Malformed files are skipped
  with an IRISLog line.
- **Catalog:** one line per skill (`- name: description`), capped at **20 skills / ~1500
  chars** (+ "…and N more"), appended to the realtime instructions (persona + memory +
  catalog — every byte is billed per turn) and to the classic prompt's memory block.
- **Name matching:** normalize = lowercase, non-alphanumerics → single spaces; exact
  normalized match first, then substring either way. `spokenNames` feed
  `IntentRouter.strongHeuristic` for deterministic `.skill` routing.
- **Execution:** realtime `run_skill` tool — `inline` returns the steps as the tool output
  for the model to chain with its existing tools; `agent` launches an AgentManager sidecar
  task. Classic pipeline: both modes dispatch as a background agent (the classic brain can't
  chain tools).

## Local routing (local-first answering)
Source: `IRIS/AI/LocalRouter.swift`, `IRIS/AI/LocalBrain.swift`. Fronts the cloud brain for
classic `.answer` questions only (realtime speech-to-speech can't be served locally).

- **Backends** (preference order): Apple Foundation Models (macOS 26+, `SystemLanguageModel
  .default.availability == .available`), then Ollama (`IRIS_OLLAMA_URL`, default
  `http://localhost:11434`, `POST /api/chat`, non-streaming, model `IRIS_LOCAL_MODEL` default
  `llama3.2` — falls back to the first installed model when that one isn't pulled).
- **Timeouts:** availability probe `GET /api/tags` **1.5s**, result cached **60s** (a stopped
  Ollama never adds latency); chat request hard cap **8s**; a failed chat invalidates the
  probe cache.
- **Escalate to cloud when** (pre-filters, checked before calling local): screenshot
  attached; history > **6** turns; transcript > **30** words (premium tier) / **60** words
  (saver/free — keeps more traffic free once the budget is tight); recency cue present
  (`today, tonight, latest, news, price(s), cost of, who won, stock, weather, right now,
  currently, this week, yesterday, tomorrow, score`).
- **Escape hatch:** the local system prompt ends with "reply with exactly ESCALATE if
  unsure". Escalate when the reply is/contains `ESCALATE`, is empty, exceeds **600** chars
  (runaway), or errored/timed out.
- Every decision is logged (`localRouter: answered locally / cloud (<reason>)`) for tuning.

## Screen rule engine (reactive `uiRule` application)
Source: `IRIS/Vision/ScreenRuleEngine.swift`. Runs only right after IRIS performs an action that
commonly surfaces a known dialog (e.g. it just started a Claude Code session) — never always-on.
- **Render delay:** wait **`1.2s`** after the triggering action for the UI to render before looking.
- **Gates:** `memoryEnabled` + `computerUseEnabled` + an OpenAI key + `allowsPaidVision` (tier-gated,
  metered) — so it never spends in `.free`.
- **Match:** gpt-4o, strict `json_object`, `max_tokens 100`, returns
  `{match, confidence, x?, y?}`. Acts only when `match ≥ 1` **and** `confidence ≥ 0.8`
  (`matchConfidenceFloor`) — a false-positive keypress/click into the focused window is worse than a
  miss. Missing `confidence` is treated as certain (match ≥ 1 already implies a hit).
- **Action precedence (`RealtimeTools.parseAction`):** explicit `type X` → named key → single digit →
  **refusal/negation → Escape** → confirmation → Enter. Refusal/negation (`no`, `don't`, `do not`,
  `never`, …) is checked **before** confirmation so a negated phrase ("don't confirm") maps to Escape,
  not Enter. Short intent words use whole-word matching ("no" won't fire inside "now"/"know").

## Memory (persistent brain)
Source: `IRIS/Core/Memory.swift`. `~/.iris/memory.json` (source of truth) + regenerated `IRIS.md` mirror.
- **Capacity:** hard cap **200** items; pruned by useCount, then recency (`lastUsedAt ?? createdAt`).
- **Recall ranking (`promptBlock`, default limit 40):** most-used first, then most-recent.
- **Dedup on add:** same normalized text, or (for `uiRule`s) same normalized trigger → bump useCount.
- **Forget (`remove(matching:)`):** scored best-match — exact text `1.0`, stored-text-contains-query
  `0.8`, else Jaccard word overlap; removes only at score **≥ 0.4**. Deliberately does NOT match when
  the stored text is merely a substring of the query (that deleted unrelated short memories). Generic
  "forget that/this/it" drops the most-recent item.
- **Foreground learning (`AppDelegate`):** explicit teaching cues ("remember…", "note that…",
  "from now on…", "always…") store the fact; if the remainder is an actionable command it is
  remembered AND dispatched (not swallowed). Inferred learning (`maybeLearn`) only runs on durable
  preference/identity cues ("i prefer", "from now on", "my name is", … — NOT broad words like
  "actually"/"stop"/"don't" that fire on ordinary commands).

## Cursor buddy (FloatingPanel buddy mode — 2026-07 reconstruction)

- Canvas: 400×300 transparent, click-through, content top-leading.
- Target: panel top-left at `(mouse.x + 20, mouse.y - 60)` (below-right of cursor); flips to
  the LEFT of the cursor when it would run off the right screen edge; clamped to the
  `visibleFrame` of the screen containing the cursor (multi-monitor hop).
- Follow: 30 Hz timer, exponential smoothing `pos += (target - pos) * 0.25` per tick; ticks
  are skipped once within 0.5 pt (an idle cursor costs nothing). Snaps (no glide) on show.
- Notch island remains available via `uiMode: "notch"` / `IRIS_UI_MODE=notch`.

## Sentence chunking (streamed reply → TTS)

- Boundary: `.` `!` `?` followed by whitespace, or a newline, at/after **40 chars** minimum.
- The chunker emits each completed sentence to the Speaker queue as it forms (speech starts
  ~1 s into generation); the tail is flushed when the stream ends.

## Context digest (ConversationStore)

- History sent per request = 1 digest paragraph (as a leading user note) + last **4 turns**
  verbatim.
- Digest pass fires (fire-and-forget, `claude-haiku-4-5`) when held turns > **8** or total
  > **2,500 chars**; staleness reset unchanged at **120 s**.

## Prompt caching (ClaudeEngine API path)

- `system` = 2 blocks, each with `cache_control: ephemeral`: (1) persona + pointing hint —
  byte-stable; (2) memory + skills catalog — rewrites only on remember/forget/skill change.
- The timestamp (`nowContext`) lives in the FINAL USER TURN, never the system prefix
  (a system-prefix timestamp invalidates the whole cache every call).
- Verify hits via `usage.cache_read_input_tokens` in the log; Sonnet needs a ≥2048-token
  prefix or caching is a silent no-op.

## Claude sessions (ClaudeSessionManager)

- Spawn: `claude -p --output-format stream-json --verbose [--resume <id>]
  [--mcp-config ~/.iris/mcp.json]`, prompt via temp-file stdin, stderr →
  `~/.iris/logs/session-<id>.err`.
- Narration throttle: first tool-use narrated immediately, then ≤ 1 line per **20 s**;
  final result always spoken, Haiku-digested when > **350 chars**.
- Registry `~/.iris/sessions.json` capped at **20**; finished pills prune after **25 s**;
  concurrency capped by `maxConcurrentAgents` (default 4).

## Push-to-talk (HotkeyManager + WakeWordDetector)

- Chord: hold **⌥Space** (`pttKeyCode` 49 + `pttModifiers` option), key-repeat ignored.
- Key-down: fresh recognition session (clean transcript baseline), wake matching bypassed;
  key-up: deliver verbatim immediately — no wake phrase, no settle timeout.
- Bare-name wake (`wakeNameOnly`, default on): variants `dory|dori|dorie` anywhere in a
  sentence; when the text AFTER the name is empty, the text BEFORE it is the command.
