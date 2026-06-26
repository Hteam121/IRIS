# Algorithms & Tuned Constants

Exact formulas and magic numbers used across IRIS. Update this file when a constant changes;
implementation must match these values.

## Floating panel
- Panel size: `320 × 120` pt.
- Cursor offset: origin = `(mouse.x + 20, mouse.y - 60)` (place to lower-right of cursor).
- Window level: `.floating`; collection behavior: `[.canJoinAllSpaces, .fullScreenAuxiliary]`.

## Orb animation
- Diameter: `16 pt`.
- Pulse: `scaleEffect` between `1.0` and `1.3`, `easeInOut`, `duration 0.6s`, `repeatForever(autoreverses:)`.
- State → color: idle = gray, listening = blue, thinking = purple, speaking = green.

## Wake word / speech
- Wake phrase (default): `"hey iris"` (case-insensitive `contains` match on the lowercased transcript).
- Command extraction: strip the wake phrase prefix, trim whitespace; remainder is the command.
- Agent trigger: transcript contains `"iris agent"` → route to AgentMode (strip + trim for the task).
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
  IRIS speaks so the user can cut IRIS off — but **only the wake phrase** ("hey iris") triggers it.
  IRIS never says "hey iris", so its own TTS (or background noise) cannot self-trigger a barge-in;
  this avoids IRIS mistaking its own speaker output for the user. On a wake-phrase match while
  speaking, IRIS stops the current utterance and clears the spoken-output queue immediately, then
  captures the new command via the normal settle flow. ⌥⎋ remains a manual backup. Background
  agents are never affected. (We deliberately do NOT trigger on arbitrary speech — speaker bleed
  makes that unreliable.)
- Wake-utterance settle: after the wake phrase is heard, keep accumulating the same utterance
  until **`1.2s`** of no new partial results, then strip the prefix → that remainder is the command.

## Command capture (Transcriber)
- Used when the wake phrase had no trailing command ("hey iris" then a pause): capture the command
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
- Volume: `0.8` (a little below max so the mic can pick up the "hey iris" barge-in over IRIS's
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
- System framing: "You are IRIS… be concise, response will be spoken aloud, ≤3 sentences unless asked."
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
  saver = realtime suppressed, classic free `claude -p` pipeline answers each command;
  free = classic pipeline + on-device TTS (`allowsNeuralTTS == false`), zero OpenAI spend.
- **Decision point:** tier is evaluated at each wake (`AppDelegate.wakeUp`) — premium opens the paid
  realtime stream, saver/free leave the wake detector live so the captured command is answered by the
  free `claude -p` pipeline. **Mid-session ceiling:** a running realtime conversation is also checked
  after every `response.done` — once a turn's metered spend pushes the tier below premium
  (`allowsRealtime == false`), `onBudgetExhausted` ends the paid stream immediately (rather than
  letting one long sitting, whose idle timer resets each turn, blow past the cap); the next wake then
  re-checks and falls back to the free pipeline.

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
