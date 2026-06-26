# Code Review — 2026-06-25

Multi-agent review (8 finder angles → 38 candidates → independent verification) of the working
tree vs `main` (`git diff HEAD`). Change set: `CostGovernor`, the `Memory` subsystem, learned
`ScreenRuleEngine` rules, and the new `claude -p` intent/vision path.

**Outcome:** 10 findings reported (32 verified, 6 refuted). The 5 high-severity findings were fixed
in this pass; medium/low remain open (tracked below). Build verified green
(`xcodebuild … -destination 'platform=macOS' build` → BUILD SUCCEEDED).

---

## High severity — FIXED in this pass

### 1. Paid `gpt-4o` calls bypassed the budget tier and were never metered — FIXED
`ScreenRuleEngine.matchRule`, `RealtimeTools.describeScreenOpenAI`, `IntentRouter.classifyWithOpenAI`
ran regardless of `CostGovernor.tier()` and never recorded their spend, violating the documented
`.free` = "zero OpenAI spend" invariant. The `ScreenRuleEngine` vision call fired after *every*
Claude terminal launch.
**Fix:** added `CostGovernor.allowsPaidVision` (false in `.free`) + `recordVision(usage:)` (exact
gpt-4o token cost, flat fallback). `applyLearnedRules`/`matchRule` and `describeScreenOpenAI` are now
gated on the tier and meter their `usage`; `IntentRouter` gained `allowPaidFallback` (set from
`costGovernor.allowsPaidVision`) so the OpenAI classifier is skipped once the budget is spent.

### 2. No mid-session realtime spend ceiling — FIXED
The tier was only evaluated at `wakeUp()`; one long continuous conversation (idle timer resets each
turn) could blow far past the monthly cap before the next wake re-checked.
**Fix:** `RealtimeSession` now checks `costGovernor.allowsRealtime` at the end of every
`response.done` (after metering the turn) and fires a new `onBudgetExhausted` callback;
`AppDelegate.handleBudgetExhausted()` ends the paid stream, speaks a notice, and returns to
wake-word listening so the next wake falls back to the free `claude -p` pipeline.

### 3. Inverted confirm/refuse mapping under negation — FIXED
`RealtimeTools.parseAction` checked confirm words before refusal words and ignored negation, so a
stored action like "do not confirm" / "don't accept" mapped to Enter — auto-confirming a dialog the
user wanted declined.
**Fix:** refusal/negation is now checked first (negation markers `don't`/`do not`/`never`/… →
Escape), and intent words use whole-word matching so "no"/"ok" no longer fire inside "now"/"know".

### 4. `handleTeaching()` swallowed actionable commands — FIXED
Any command prefixed with `always `/`note that `/`remember `/`from now on ` was stored and returned
before normal routing, so "Always open Chrome when I say browser" became an inert note instead of
being acted on.
**Fix:** `handleTeaching` now splits the cue (`splitTeaching`) and, when the remainder is an
imperative (`isActionableInstruction` — leading action verb or a concrete `strongHeuristic` intent),
remembers the standing instruction AND dispatches the command via `handleCommand`. Pure facts
("remember that …") still store-and-confirm as before.

### 5. `Memory.remove(matching:)` deleted the wrong memories — FIXED
The match used `t.contains(q) || q.contains(t)`; the `q.contains(t)` direction removed any stored
item whose text was a substring of the forget phrase (e.g. "coffee" deleted on "forget my 3pm coffee
chat") — silent data loss.
**Fix:** rewrote to a scored best-match — exact (1.0) / stored-contains-query (0.8) / Jaccard word
overlap, removing the item only at score ≥ 0.4. The dangerous `q.contains(t)` direction is gone; the
generic "forget that/this/it → drop most recent" shortcut is preserved.

---

## Medium severity — FIXED (second pass)

- **6. `hasLearningCue` over-fires — FIXED** (`AppDelegate.hasLearningCue`): dropped the broad cues
  `stop `/`don't `/`actually`/`instead of`; kept only durable preference/identity cues, so ordinary
  commands no longer trigger a spurious `extractMemories` call or "Noted — I'll remember that".
- **7. Blocking `claude -p` classifier latency — FIXED** (`IntentRouter.route`): when the budget
  allows paid calls (`allowsPaidVision`) and an OpenAI key is set, the fast gpt-4o classifier now
  runs first (and is metered via `recordVision`); `claude -p` is the fallback. In `.free`/no-key it
  stays on the free `claude -p` classifier. `IntentRouter` now holds `costGovernor` (replaces the
  `allowPaidFallback` bool).
- **8. Screen-rule false-positive input injection — MITIGATED** (`ScreenRuleEngine.matchRule`): the
  gpt-4o match now returns a `confidence` and IRIS only synthesizes input at `confidence ≥ 0.8`
  (`matchConfidenceFloor`), with a stricter prompt ("when unsure, return 0").
- **9. `describeScreen` short-circuit — FIXED** (`RealtimeTools.describeScreen`): a `claude -p` reply
  that reads like a vision failure ("I can't see the image", "couldn't read", …) now falls through
  to the OpenAI vision path instead of being spoken.

## Low severity — FIXED / deferred (second pass)

- **10. Per-metered-event disk write — FIXED** (`CostGovernor`): `usage.json` writes are now
  debounced (~1.5s, coalesced); rollover writes immediately, and `flush()` (wired into
  `applicationWillTerminate`) persists on exit.
- Convention — FIXED: documented the new constants/behaviors in `docs/algorithms.md` (vision rates,
  `allowsPaidVision`, mid-session ceiling, persist debounce, classifier order, the new "Screen rule
  engine" + "Memory" sections incl. `renderDelay`, confidence floor, `parseAction` precedence,
  `remove(matching:)` scoring).
- **Structural dedups — DONE (third pass):**
  - gpt-4o vision HTTP boilerplate extracted into `IRIS/Vision/OpenAIVision.swift`
    (`OpenAIVision.complete(imageData:instruction:apiKey:maxTokens:jsonMode:)` → `Reply{content, usage}`).
    `ScreenRuleEngine.matchRule` and `RealtimeTools.describeScreenOpenAI` now call it and only differ
    in prompt / json-mode / token budget / how they read the reply. Metering kept at the call sites
    (records `reply.usage` exactly as before). One behaviour delta: the two rare spoken error strings
    in the OpenAI path ("had trouble reading" / "couldn't reach the network") collapse to a single
    "I had trouble reading the screen." message.
  - Post-launch terminal sequence extracted into
    `ScreenRuleEngine.openTerminalApplyingRules(in:startClaude:settings:memory:screenCapture:costGovernor:)`,
    used by both the classic (`AppDelegate.terminal`) and realtime (`RealtimeTools.open_terminal`)
    paths. The mid-sequence cancellation check is preserved inside the helper (skips the paid vision
    call if interrupted right after launch).
  - The trivial "append memory block with `\n\n`" one-liners were left as-is (not worth a cross-lane
    helper).

## Refuted (checked, no action needed)

- `RealtimeSession.refreshInstructions` `session.update` — the Realtime API merges, not resets.
- `Settings.defaultRealtimeModel` `gpt-realtime-mini` — intentional/valid.
- `CostGovernor.load()` rollover vs `rollOverIfNeeded` — consistent; DRY nit only.
- `AppDelegate` outer `memoryEnabled` guard before `applyLearnedRules` — redundant but harmless.
- `IRISBrain.parseJSONStringArray` hand-rolled JSON extraction — works.
- `ScreenRuleEngine.renderDelay = 1.2` — style/doc drift, no runtime effect.

---

## Files changed in the fix pass

`Core/CostGovernor.swift` (vision rates, `recordVision`, `allowsPaidVision`),
`Vision/ScreenRuleEngine.swift` (tier gate + meter), `Realtime/RealtimeTools.swift` (thread
`costGovernor`, gate/meter OpenAI vision, `parseAction` negation fix), `Realtime/RealtimeSession.swift`
(`onBudgetExhausted` + `response.done` ceiling), `AI/IntentRouter.swift` (`allowPaidFallback` gate),
`AppDelegate.swift` (`handleBudgetExhausted`, wired callback, `handleTeaching` actionable split,
pass `costGovernor`/`allowPaidFallback`), `Core/Memory.swift` (scored `remove(matching:)`).
