//
//  CompanionManager.swift
//  IRIS — the central state machine (Clicky's CompanionManager pattern)
//
//  Owns the whole interaction pipeline and every component; AppDelegate is just a
//  bootstrap. One conversation flow, serialized:
//
//    idle → listening (wake word / push-to-talk / follow-up)
//         → routing   (deterministic Router, instant)
//         → thinking  (ONE streaming ClaudeEngine call — or a native action)
//         → speaking  (sentence-streamed TTS queue)
//         → idle      (or listening again for a follow-up)
//
//  Foreground commands are SERIALIZED: a new command cancels the in-flight one
//  (Clicky-style; the old answer's speech is stopped too). Background Claude sessions
//  (`sessions`) are fully parallel and are never touched by foreground transitions.
//  Interrupts (⌥⎋ / "stop" / wake barge-in) drop everything foreground and go idle.
//

import AppKit
import Combine

@MainActor
final class CompanionManager {

    let appState: AppState
    private(set) var settings = IRISSettings.load()

    /// Live permission statuses (drives the onboarding window; AppDelegate reads it).
    let permissions = PermissionsManager()

    // The persistent self-learning "brain": injected into every prompt path.
    private let memory = MemoryStore()
    private lazy var costGovernor = CostGovernor(budgetUSD: settings.monthlyBudgetUSD)

    private var engine: ClaudeEngine?
    private let conversationStore = ConversationStore()
    private var wakeWord: WakeWordDetector?
    private var speaker: Speaker?
    private let screenCapture = ScreenCapture()
    private var screenPointer: ScreenPointer?
    private var skillManager: SkillManager?
    private var sessions: ClaudeSessionManager!
    private var hotkeys: HotkeyManager?

    // The single in-flight FOREGROUND command. A new command cancels it (serialized flow);
    // background sessions live in `sessions` and are untouched.
    private var currentTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    // Loop guards: ignore an identical command repeated within a short window, and don't open
    // multiple terminals back-to-back — defends against any residual self-hearing echo.
    private var lastCommandText = ""
    private var lastCommandAt = Date.distantPast
    private var lastTerminalLaunchAt = Date.distantPast

    // Follow-up: when IRIS asks a question it auto-listens for the answer (no wake word).
    private var expectingFollowUp = false

    // A background task that paused to ask the user something (v1 sessions don't pause;
    // plumbing kept for interactive sessions later).
    private var pendingQuestion: (id: String, question: String)?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Startup

    func start() {
        let engine = ClaudeEngine(settings: settings, costGovernor: costGovernor)
        self.engine = engine

        if settings.pointerEnabled {
            screenPointer = ScreenPointer(settings: settings, screenCapture: screenCapture,
                                          costGovernor: costGovernor)
        }
        if settings.skillsEnabled {
            let skills = SkillManager()
            skills.load()
            skillManager = skills
        }
        if settings.memoryEnabled { memory.load() }

        let speaker = makeSpeaker()
        self.speaker = speaker

        let sessions = ClaudeSessionManager(settings: settings, appState: appState,
                                            speaker: speaker, memory: memory, engine: engine)
        self.sessions = sessions
        sessions.onAnnouncement = { [weak self] text in
            self?.speaker?.enqueue(text)
        }

        // Global hotkeys: ⌥⎋ interrupt + hold-⌥Space push-to-talk.
        let hotkeys = HotkeyManager(settings: settings)
        hotkeys.onInterrupt = { [weak self] in self?.handleInterruptRequest() }
        hotkeys.onPTTDown = { [weak self] in
            guard let self else { return }
            // Holding the key while IRIS talks is a barge-in: go quiet and listen.
            if self.appState.isSpeaking { self.speaker?.stop() }
            self.wakeWord?.beginPushToTalk()
        }
        hotkeys.onPTTUp = { [weak self] in self?.wakeWord?.endPushToTalk() }
        hotkeys.install()
        self.hotkeys = hotkeys

        // Proactively request permissions up front (Phase 6 adds the guided onboarding).
        requestScreenRecordingPermission()
        if settings.computerUseEnabled {
            _ = ComputerControl.ensureAccessibility(prompt: true)
        }

        // Wake-word pipeline: on-device "hey dory" (or bare-name) listening. Deferred until
        // mic + speech are granted (the onboarding window guides the user there).
        let wake = makeWakeWord()
        self.wakeWord = wake
        retryStartListening()
    }

    /// (Re)request mic + speech and start the wake listener once granted. Called at launch and
    /// again when the user finishes the onboarding window.
    func retryStartListening() {
        WakeWordDetector.requestAuthorization { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSLog("[IRIS] mic + speech authorization granted: \(granted)")
                self.permissions.refresh()
                if granted {
                    self.wakeWord?.start()   // no-op if already running
                } else {
                    self.appState.responseText =
                        "I need Microphone and Speech Recognition access to listen. Enable them in System Settings → Privacy & Security."
                }
            }
        }
    }

    func shutdown() {
        wakeWord?.stop()
        speaker?.stop()
        costGovernor.flush()   // persist any debounced spend before exit
        sessions?.shutdown()   // terminates running claude processes (still resumable)
        hotkeys?.uninstall()
    }

    /// Surface the Screen Recording prompt at launch (for screen vision). macOS can't fully grant
    /// it programmatically — the user may still need to toggle it in System Settings and relaunch.
    private func requestScreenRecordingPermission() {
        DispatchQueue.global(qos: .utility).async {
            let granted = CGRequestScreenCaptureAccess()
            NSLog("[IRIS] screen recording access granted: \(granted)")
        }
    }

    // MARK: - Component factories

    private func makeSpeaker() -> Speaker {
        let speaker = Speaker(settings: settings, appState: appState, costGovernor: costGovernor)
        speaker.onFinished = { [weak self] in self?.speechFinished() }
        return speaker
    }

    private func makeWakeWord() -> WakeWordDetector {
        let wake = WakeWordDetector(settings: settings, appState: appState)
        wake.onWakeWordDetected = { [weak self] command in self?.handleCommand(command) }
        wake.onBargeIn = { [weak self] in self?.handleVoiceBargeIn() }
        return wake
    }

    /// The user spoke over IRIS: stop talking (and any queued announcements) and return to
    /// listening. Background sessions are deliberately left running.
    private func handleVoiceBargeIn() {
        guard appState.isSpeaking else { return }
        speaker?.stop()
    }

    // MARK: - Settings (live apply)

    func applySettings(_ new: IRISSettings) {
        let keysChanged = new.anthropicAPIKey != settings.anthropicAPIKey
            || new.openAIAPIKey != settings.openAIAPIKey
            || new.model != settings.model
            || new.localLLMEnabled != settings.localLLMEnabled   // engine captures it at init
        let voiceChanged = new.voice != settings.voice
            || new.voiceIdentifier != settings.voiceIdentifier
            || new.ttsRate != settings.ttsRate
            || new.openAITTSEnabled != settings.openAITTSEnabled
            || new.ttsVoice != settings.ttsVoice
            || new.ttsModel != settings.ttsModel
            || new.ttsInstructions != settings.ttsInstructions
            || new.ttsSpeed != settings.ttsSpeed
            || new.openAIAPIKey != settings.openAIAPIKey   // OpenAI TTS uses this key
        // The detector binds its locale AND wake matcher at init; rebuild on either change.
        let detectorChanged = new.voice != settings.voice
            || new.wakePhrase != settings.wakePhrase
            || new.wakeNameOnly != settings.wakeNameOnly

        settings = new

        if keysChanged {
            // The engine captures keys/model at init; a fresh instance picks up credentials.
            let newEngine = ClaudeEngine(settings: new, costGovernor: costGovernor)
            engine = newEngine
            sessions?.setEngine(newEngine)
        }
        if voiceChanged {
            let newSpeaker = makeSpeaker()
            speaker = newSpeaker
            sessions?.setSpeaker(newSpeaker)
        }
        costGovernor.applyBudget(new.monthlyBudgetUSD)
        sessions?.applySettings(new)
        if detectorChanged {
            wakeWord?.stop()
            let wake = makeWakeWord()
            wakeWord = wake
            wake.start()
        }
    }

    // MARK: - Interrupt

    /// User explicitly asked to stop (hotkey or menu). Cancel the foreground command and reset.
    func handleInterruptRequest() {
        guard currentTask != nil || appState.isSpeaking || appState.status != .idle else { return }
        interrupt()
        appState.status = .idle
        appState.responseText = ""
    }

    /// Cancel a background session pill (menu-bar action).
    func cancelSession(_ id: String) {
        sessions.cancel(id)
    }

    /// Cancel the in-flight foreground command and stop any speech. Cancellation propagates
    /// into ClaudeEngine — terminating a running `claude` subprocess and the streaming
    /// Anthropic URLSession call.
    private func interrupt() {
        currentTask?.cancel()
        currentTask = nil
        screenPointer?.dismiss()
        speaker?.stop()   // delegate fires → speechFinished()
    }

    // MARK: - Command pipeline (serialized foreground)

    func handleCommand(_ command: String) {
        // A bare spoken "stop" (or "never mind", "be quiet", …) is a FULL interrupt.
        if Self.isStopCommand(command) {
            interrupt()
            appState.status = .idle
            appState.responseText = ""
            return
        }

        // Debounce exact-duplicate commands (defends against self-hearing / stutter loops).
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == lastCommandText, Date().timeIntervalSince(lastCommandAt) < 3.0 {
            NSLog("[IRIS] ignoring duplicate command within 3s: \"\(command)\"")
            return
        }
        lastCommandText = normalized
        lastCommandAt = Date()
        expectingFollowUp = false   // recomputed per command

        // If a background task is waiting on the user, this utterance is its answer.
        if let pq = pendingQuestion {
            pendingQuestion = nil
            sessions.resume(pq.id, answer: command)
            finishForeground("Okay, passing that along.")
            return
        }

        // Explicit teaching ("remember…", "from now on…", "always…").
        if handleTeaching(command) { return }

        // SERIALIZED foreground (the FSM): a new command replaces the in-flight one —
        // cancel it and stop its speech so the new question owns the floor.
        if currentTask != nil {
            currentTask?.cancel()
            currentTask = nil
            speaker?.stop()
        }

        appState.status = .thinking
        appState.responseText = ""

        currentTask = Task { @MainActor in
            defer {
                currentTask = nil
                if !appState.isSpeaking, appState.status == .thinking {
                    appState.status = .idle
                }
            }

            // Spoken cancellation of a running session ("cancel the deal search").
            let lower = command.lowercased()
            if lower.hasPrefix("cancel ") || lower.hasPrefix("stop the ")
                || lower.contains("cancel the") {
                if let title = sessions.cancelMatching(command) {
                    finishForeground("Okay, I cancelled \(title).")
                    return
                }
            }

            let router = Router(skillNames: skillManager?.spokenNames ?? [])
            let intent = router.route(command)   // deterministic — instant, zero network

            switch intent {
            case .answer:
                await answerCommand(command)

            case .openApp(let name):
                let reply = await AppLauncher.open(appName: name)
                if Task.isCancelled { return }
                finishForeground(reply)

            case .openFolder(let dir):
                let target = dir ?? FileManager.default.homeDirectoryForCurrentUser.path
                let reply = FolderOpener.open(target)
                if Task.isCancelled { return }
                finishForeground(reply)

            case .webSearch(let query, let browser):
                let reply = WebSearch.open(query: query, browser: browser)
                if Task.isCancelled { return }
                finishForeground(reply)

            case .terminal(let dir, let startClaude):
                if Date().timeIntervalSince(lastTerminalLaunchAt) < 5.0 {
                    finishForeground("I just opened a terminal a moment ago.")
                    return
                }
                lastTerminalLaunchAt = Date()
                let target = dir ?? settings.defaultAgentDirectory
                guard let engine else { return }
                let reply = await ScreenRuleEngine.openTerminalApplyingRules(
                    in: target, startClaude: startClaude, settings: settings,
                    memory: memory, screenCapture: screenCapture, engine: engine)
                if Task.isCancelled { return }
                if dir == nil, let named = router.spokenDirectoryName(command) {
                    finishForeground("I couldn't find a folder called \(named), so I used your home folder. " + reply)
                } else {
                    finishForeground(reply)
                }

            case .backgroundAgent(let task):
                let webish = ["deal", "price", "buy", "shop", "cheapest", "online", "web", "search for"]
                    .contains { task.lowercased().contains($0) }
                dispatchBackground(
                    kind: webish ? .web : .agent, detail: task, title: nil,
                    cwd: settings.defaultAgentDirectory,
                    ack: "On it — I'll work on that in the background.")

            case .calendar(let detail):
                dispatchBackground(
                    kind: .calendar, detail: detail, title: "Calendar appointment", cwd: nil,
                    ack: "On it — I'll set that up on your calendar.")

            case .skill(let name):
                guard let skill = skillManager?.skill(named: name) else {
                    finishForeground("I couldn't find a skill called \(name).")
                    return
                }
                dispatchBackground(
                    kind: .agent,
                    detail: skill.steps + "\n\nThe user asked: \(command)",
                    title: skill.spokenName, cwd: settings.defaultAgentDirectory,
                    ack: "On it — running \(skill.spokenName).")

            case .resumeSession(let instruction):
                sessions.resumeLatest(instruction: instruction)
            }
        }
    }

    /// The `.answer` path: ONE streaming engine call; each sentence is spoken as it arrives.
    private func answerCommand(_ command: String) async {
        // Answer time/date locally (correct + instant).
        if let local = LocalAnswers.answer(for: command) {
            finishForeground(local)
            return
        }
        guard let engine else { return }
        let history = conversationStore.history()
        var screenshotPath: String? = nil
        var shot: ScreenCapture.Shot? = nil
        if Self.isVisionQuestion(command) {
            finishForeground("Let me take a look.")
            shot = await screenCapture.captureWithInfo()
            screenshotPath = shot?.path
            if Task.isCancelled { return }
        }
        var memoryBlock = settings.memoryEnabled ? memory.promptBlock() : ""
        if let catalog = skillManager?.catalogBlock(), !catalog.isEmpty {
            memoryBlock += (memoryBlock.isEmpty ? "" : "\n\n") + catalog
        }
        let capturedShot = shot
        let reply = await engine.answer(
            transcript: command, screenshotPath: screenshotPath,
            history: history, memory: memoryBlock,
            onSentence: { [weak self] sentence in
                guard let self, !Task.isCancelled else { return }
                let clean = self.stripAndShowPointTags(in: sentence, shot: capturedShot)
                if !clean.isEmpty { self.speaker?.enqueue(clean) }
            },
            onCaption: { [weak self] text in
                self?.appState.responseText = Self.stripPointTags(from: text)
            })
        if Task.isCancelled { return }
        let display = Self.stripPointTags(from: reply)
        appState.responseText = display
        conversationStore.record(user: command, assistant: display)
        conversationStore.digestIfNeeded(using: engine)
        maybeLearn(from: command, reply: display)
        expectingFollowUp = Self.looksLikeQuestion(display)
    }

    /// A bare "stop"-type command → full interrupt. Phrases WITH an object ("stop the deal
    /// search") are NOT here — those route to session cancellation.
    private static func isStopCommand(_ command: String) -> Bool {
        let t = command.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!,?").union(.whitespacesAndNewlines))
        let stops: Set<String> = [
            "stop", "stop it", "stop talking", "be quiet", "quiet", "shut up", "hush",
            "never mind", "nevermind", "enough", "that's enough", "thats enough",
            "forget it", "cancel that", "cancel",
        ]
        return stops.contains(t)
    }

    /// Heuristic: does this question need a screenshot? Non-vision questions skip the capture.
    private static func isVisionQuestion(_ s: String) -> Bool {
        let l = s.lowercased()
        let keys = ["screen", "looking at", "do you see", "what's this", "what is this",
                    "read this", "this page", "this window", "on my display", "what am i",
                    "see here", "in front of me", "highlighted", "what do you see"]
        return keys.contains { l.contains($0) }
    }

    /// Queue a foreground reply to be spoken and show it in the overlay.
    private func finishForeground(_ reply: String) {
        appState.responseText = reply
        speaker?.enqueue(reply)
    }

    /// Strip [POINT:x,y:label] tags from a reply, rendering each as an on-screen pointer.
    private func stripAndShowPointTags(in reply: String, shot: ScreenCapture.Shot?) -> String {
        guard reply.contains("[POINT:"),
              let regex = try? NSRegularExpression(
                pattern: #"\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::([^\]]+))?\]"#) else { return reply }
        let ns = reply as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: reply, range: full)
        guard !matches.isEmpty else { return reply }

        if let shot, let pointer = screenPointer {
            for m in matches {
                guard let x = Double(ns.substring(with: m.range(at: 1))),
                      let y = Double(ns.substring(with: m.range(at: 2))) else { continue }
                let label = (m.range(at: 3).location != NSNotFound)
                    ? ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                    : nil
                pointer.show(imagePoint: CGPoint(x: x, y: y), imageSize: shot.pixelSize,
                             screenFrame: shot.screenFrame, label: label)
            }
        }
        return regex.stringByReplacingMatches(in: reply, range: full, withTemplate: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip [POINT:…] tags WITHOUT rendering pointers — for display/history text whose tags
    /// were already rendered sentence-by-sentence during streaming.
    private static func stripPointTags(from text: String) -> String {
        guard text.contains("[POINT:"),
              let regex = try? NSRegularExpression(
                pattern: #"\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::([^\]]+))?\]"#) else { return text }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: full, withTemplate: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hand a task to the session manager and immediately acknowledge by voice.
    private func dispatchBackground(
        kind: AgentTaskKind, detail: String, title: String?, cwd: String?, ack: String
    ) {
        sessions.launch(kind: kind, detail: detail, title: title, cwd: cwd)
        appState.responseText = ack
        speaker?.enqueue(ack)
    }

    /// Called when IRIS has fully finished talking. If it just asked a question, auto-listen
    /// for the answer (no wake word). Otherwise return to idle when nothing is in flight.
    private func speechFinished() {
        guard currentTask == nil else { return }
        if expectingFollowUp {
            expectingFollowUp = false
            appState.status = .listening
            wakeWord?.captureFollowUp()
        } else {
            appState.status = .idle
        }
    }

    private static func looksLikeQuestion(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }

    // MARK: - Learning (teaching + inferred)

    /// Handle a "teach IRIS something" instruction. A pure fact/preference is stored and
    /// confirmed; a standing instruction that also names an action is remembered AND
    /// still carried out. Returns true when handled.
    private func handleTeaching(_ command: String) -> Bool {
        guard settings.memoryEnabled, let (prefix, remainder) = Self.splitTeaching(command) else {
            return false
        }
        let fact = Self.normalizeTaught(remainder, addAlways: prefix == "always ")
        if isActionableInstruction(remainder) {
            memory.add(text: fact, kind: .preference, source: .explicit)
            handleCommand(remainder)   // remember the rule, but also act on the command now
            return true
        }
        let isNew = memory.add(text: fact, kind: .preference, source: .explicit)
        finishForeground(isNew ? "Got it — I'll remember that." : "I already had that noted.")
        return true
    }

    /// Split a teaching command into (matched cue prefix, raw remainder) when it starts with a
    /// teaching cue; nil otherwise (or when nothing meaningful follows the cue).
    static func splitTeaching(_ command: String) -> (prefix: String, remainder: String)? {
        let t = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let prefixes = [
            "please remember that ", "please remember ", "remember that ", "remember ",
            "note that ", "from now on, ", "from now on ", "don't ask me again, ",
            "don't ask me again ", "always ",
        ]
        for p in prefixes where lower.hasPrefix(p) {
            let idx = t.index(t.startIndex, offsetBy: p.count)
            let rest = String(t[idx...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-"))
            if !rest.isEmpty { return (p, rest) }
        }
        return nil
    }

    /// Back-compat: the normalized stored fact for a teaching command, or nil if it isn't one.
    static func extractTaughtFact(_ command: String) -> String? {
        guard let (p, rest) = splitTeaching(command) else { return nil }
        return normalizeTaught(rest, addAlways: p == "always ")
    }

    /// Whether a taught remainder is really an imperative command (so it should be ACTED ON).
    private func isActionableInstruction(_ remainder: String) -> Bool {
        let lower = remainder.lowercased()
        let verbs = ["open ", "launch ", "start ", "run ", "play ", "close ", "search ", "google ",
                     "look up ", "show ", "go to ", "schedule ", "set ", "create ", "find ",
                     "type ", "press ", "click ", "switch to "]
        if verbs.contains(where: { lower.hasPrefix($0) }) { return true }
        if let intent = Router().strongHeuristic(remainder), intent != .answer { return true }
        return false
    }

    /// Rewrite leading first-person to "User …" so a stored fact isn't ambiguous in the prompt.
    private static func normalizeTaught(_ s: String, addAlways: Bool) -> String {
        var f = s
        let lower = f.lowercased()
        if lower.hasPrefix("i'm ") { f = "User is " + String(f.dropFirst(4)) }
        else if lower.hasPrefix("i am ") { f = "User is " + String(f.dropFirst(5)) }
        else if lower.hasPrefix("my ") { f = "User's " + String(f.dropFirst(3)) }
        else if lower.hasPrefix("i ") { f = "User " + String(f.dropFirst(2)) }
        return addAlways ? "Always " + f : f
    }

    /// "Learns from itself": when a turn carries a preference/correction cue, extract durable
    /// memories and store them (deduped). Gated so it never runs on ordinary turns.
    private func maybeLearn(from userTurn: String, reply: String) {
        guard settings.memoryEnabled, let engine, Self.hasLearningCue(userTurn) else { return }
        Task { @MainActor in
            let candidates = await engine.extractMemories(userTurn: userTurn, assistantTurn: reply)
            let added = candidates.filter {
                memory.add(text: $0, kind: .preference, source: .inferred)
            }
            if !added.isEmpty { speaker?.enqueue("Noted — I'll remember that.") }
        }
    }

    private static func hasLearningCue(_ s: String) -> Bool {
        let l = s.lowercased()
        let cues = ["i prefer", "i like", "i always", "i usually", "i hate", "i don't like",
                    "i don't want", "from now on", "my name is", "call me", "i want you to",
                    "please don't", "i'd prefer", "i would prefer"]
        return cues.contains { l.contains($0) }
    }
}
