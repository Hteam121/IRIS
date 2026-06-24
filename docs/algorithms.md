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
