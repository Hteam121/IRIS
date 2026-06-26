//
//  AppDelegate.swift
//  IRIS — Integration (Phase 2, solo)
//
//  Owns the app lifecycle and wires every Phase 1 lane together:
//    WakeWordDetector.onWakeWordDetected → ScreenCapture.capture → IRISBrain.ask → Speaker.speak,
//  driving the shared `AppState` (which the UI lane's orb/overlay observe) on the main actor.
//
//  Per plan.md Phase 2, this is the single integration file; the feature lanes are untouched.
//

import AppKit
import SwiftUI
import Combine
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Shared contract + config (Phase 0). `settings` is mutable so the menu-bar Settings
    // window can update API keys / model and have them apply live (see applySettings).
    private let appState = AppState()
    private var settings = IRISSettings.load()

    // The persistent self-learning "brain": loaded at launch, injected into every prompt path,
    // written to when IRIS is taught something (explicitly or by inference). See Memory.swift.
    private let memory = MemoryStore()

    // Meters OpenAI spend against the monthly budget and decides, per interaction, whether the
    // paid realtime core may run or IRIS should fall back to the free `claude -p` pipeline /
    // on-device voice. See CostGovernor.swift + docs/algorithms.md → Cost Governor.
    private lazy var costGovernor = CostGovernor(
        budgetUSD: settings.monthlyBudgetUSD, realtimeModel: settings.realtimeModel)

    // Components (Phase 1 lanes), retained for the app's lifetime.
    private var panel: FloatingPanel?
    private var statusBarItem: StatusBarItem?
    private var wakeWord: WakeWordDetector?
    private var speaker: Speaker?
    private let screenCapture = ScreenCapture()
    // Concrete type (not the IRISResponder protocol) so we can rebuild it on key changes
    // without touching the frozen Core.swift contract.
    private var brain: IRISBrain?
    // Manages background agent tasks (LangGraph sidecar). Independent of the foreground
    // pipeline below — launching/cancelling background work never touches `currentTask`.
    private var agentManager: AgentManager!
    // Realtime (Jarvis/Cluely) conversational core; replaces the wake-word pipeline when enabled.
    // In realtime mode the wake detector GATES the costly stream: IRIS sleeps (wake-word listening)
    // until "hey iris", runs the realtime conversation, then sleeps again after idle.
    private var realtimeSession: RealtimeSession?
    private var realtimeActive = false
    private let settingsWindowController = SettingsWindowController()

    // In-flight FOREGROUND command tasks, keyed by id. Consecutive questions run CONCURRENTLY
    // (a new command never cancels a previous one); their spoken answers are serialized by the
    // Speaker's queue. Voice barge-in (wake phrase while speaking) and the ⌥⎋ hotkey / menu are
    // how speech is actually stopped. Background agents live in `agentManager`, not here.
    private var foregroundTasks: [UUID: Task<Void, Never>] = [:]

    // Global hotkey monitors (⌥⎋) for interrupting from any app. Two monitors are needed:
    // a global one for when another app is focused, and a local one for when IRIS is focused
    // (e.g. the Settings window) — global monitors don't observe events routed to our own app.
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    // Observers (e.g. keeping the menu-bar Active-agents list in sync with backgroundTasks).
    private var cancellables = Set<AnyCancellable>()

    // Loop guards: ignore an identical command repeated within a short window, and don't open
    // multiple terminals back-to-back — defends against any residual self-hearing echo.
    private var lastCommandText = ""
    private var lastCommandAt = Date.distantPast
    private var lastTerminalLaunchAt = Date.distantPast

    // Conversation memory + follow-up: recent (role, content) turns so IRIS holds context, and a
    // flag so that when IRIS asks a question it auto-listens for the answer (no wake word needed).
    private var conversation: [[String: String]] = []
    private var lastTurnAt = Date.distantPast
    private var expectingFollowUp = false

    // Steerable agents: a background task that paused to ask the user something. While set, IRIS
    // keeps listening and routes the next spoken answer to RESUME that task (via the realtime
    // `answer_task` tool, or the classic follow-up path) instead of normal command routing.
    private var pendingQuestion: (id: String, question: String)?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory: no dock icon, doesn't take over the active app.
        NSApp.setActivationPolicy(.accessory)

        // The brain (hybrid CLI/API routing + intent routing).
        brain = IRISBrain(settings: settings)

        // Load the persistent learned memory ("the brain's brain").
        if settings.memoryEnabled { memory.load() }

        // Floating orb overlay, shown near the cursor and tracking it.
        let panel = FloatingPanel(appState: appState)
        self.panel = panel
        panel.show()

        // Text-to-speech. When speech finishes, return to idle and resume listening.
        let speaker = makeSpeaker()
        self.speaker = speaker

        // Background agent manager (LangGraph sidecar): spawns/supervises the sidecar and
        // streams task state into AppState. Independent of the foreground pipeline.
        let agentManager = AgentManager(settings: settings, appState: appState, speaker: speaker)
        self.agentManager = agentManager
        // Speak background-task results with the MAIN realtime voice when a conversation is live
        // (so they never overlap it); otherwise use the TTS speaker (no main voice to clash with).
        agentManager.onAnnouncement = { [weak self] text in
            guard let self else { return }
            if self.realtimeActive, let rt = self.realtimeSession, rt.isActive {
                rt.announce(text)
            } else {
                self.speaker?.enqueue(text)
            }
        }
        // Human-in-the-loop: a paused task asks the user something; when it resumes, clear state.
        agentManager.onQuestion = { [weak self] task in self?.handleAgentQuestion(task) }
        agentManager.onQuestionResolved = { [weak self] _ in self?.clearPendingQuestion() }
        agentManager.start()

        // Menu-bar 👁: toggle the overlay / open Settings / quit.
        let statusBarItem = StatusBarItem()
        statusBarItem.onToggle = { [weak panel] in panel?.toggle() }
        statusBarItem.onSettings = { [weak self] in self?.showSettings() }
        statusBarItem.onInterrupt = { [weak self] in self?.handleInterruptRequest() }
        statusBarItem.onCancelAgent = { [weak self] id in self?.agentManager.cancel(id) }
        statusBarItem.onQuit = { NSApp.terminate(nil) }
        self.statusBarItem = statusBarItem

        // Keep the menu-bar "Active agents" section in sync with the live task set.
        appState.$backgroundTasks
            .receive(on: DispatchQueue.main)
            .sink { [weak statusBarItem] tasks in statusBarItem?.refresh(tasks: tasks) }
            .store(in: &cancellables)

        // Global hotkey (⌥⎋ Option+Escape): interrupt IRIS from anywhere, even while it's
        // speaking — the voice mic is muted during TTS, so this is the reliable barge-in.
        installInterruptHotkey()

        // Proactively request permissions up front: Microphone + Speech (prompted below), Screen
        // Recording, and — for Mac control — Accessibility. (Automation/Apple Events for Terminal
        // still prompts on first actual use; macOS only allows that on a real Apple Event.)
        requestScreenRecordingPermission()
        if settings.computerUseEnabled {
            _ = ComputerControl.ensureAccessibility(prompt: true)
        }

        if settings.realtimeEnabled {
            // Jarvis/Cluely core, wake-gated: a local "hey iris" listener starts the realtime
            // conversation; it auto-sleeps after `idlePauseSeconds` of no speech (saves cost).
            let rt = RealtimeSession(settings: settings, appState: appState,
                                     agentManager: agentManager, screenCapture: screenCapture,
                                     memory: memory, costGovernor: costGovernor)
            rt.onIdleTimeout = { [weak self] in self?.goToSleep() }
            rt.onBudgetExhausted = { [weak self] in self?.handleBudgetExhausted() }
            self.realtimeSession = rt

            let wake = WakeWordDetector(settings: settings, appState: appState)
            wake.onWakeDetected = { [weak self] in self?.wakeUp() }
            // Budget-fallback path: in the saver/free tiers wakeUp() does NOT open the paid
            // realtime stream — it leaves the detector running so the command it then captures is
            // answered by the free classic `claude -p` pipeline. (In premium mode wakeUp() stops
            // the detector first, so these never fire.)
            wake.onWakeWordDetected = { [weak self] command in self?.handleCommand(command) }
            wake.onBargeIn = { [weak self] in self?.handleVoiceBargeIn() }
            self.wakeWord = wake

            WakeWordDetector.requestAuthorization { [weak self] granted in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    NSLog("[IRIS] mic authorization granted: \(granted)")
                    if granted {
                        wake.start()   // start asleep — listening only for the wake phrase
                    } else {
                        self.appState.responseText =
                            "I need Microphone access to talk. Enable it in System Settings → Privacy & Security."
                    }
                }
            }
        } else {
            // Classic wake-word pipeline (fallback).
            let wake = makeWakeWord()
            self.wakeWord = wake
            WakeWordDetector.requestAuthorization { [weak self] granted in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    NSLog("[IRIS] mic + speech authorization granted: \(granted)")
                    if granted {
                        wake.start()
                    } else {
                        self.appState.responseText =
                            "I need Microphone and Speech Recognition access to listen. Enable them in System Settings → Privacy & Security."
                    }
                }
            }
        }
    }

    /// "Hey IRIS" heard while sleeping. In the .premium budget tier this starts the paid realtime
    /// conversation (and stops the wake listener); in .saver/.free it does NOT — it leaves the
    /// detector running so the captured command is answered by the free classic `claude -p`
    /// pipeline, keeping spend under the monthly cap.
    private func wakeUp() {
        guard settings.realtimeEnabled, let rt = realtimeSession, !realtimeActive else { return }
        let tier = costGovernor.tier()
        guard tier == .premium else {
            IRISLog.log("wake phrase → budget tier \(tier.rawValue): using free claude -p pipeline (realtime suppressed)")
            return   // detector stays live → delivers the command to handleCommand (classic)
        }
        realtimeActive = true
        IRISLog.log("wake phrase → starting realtime conversation")
        wakeWord?.stop()
        appState.status = .listening
        rt.start()
        primeRealtimeOnWake(rt)
    }

    /// On re-wake, surface in-flight context so "Hey IRIS" doesn't start blank: re-ask a task's
    /// pending question, or note a still-running background task. (Queued in the session and
    /// flushed once it's ready.)
    private func primeRealtimeOnWake(_ rt: RealtimeSession) {
        if let pq = pendingQuestion {
            rt.awaitingAnswer = true
            rt.primeContext(
                "A background task is waiting on the user's answer to this question: \"\(pq.question)\". "
                + "Ask the user that now, and when they answer call answer_task with their reply.",
                respond: true)
            return
        }
        let active = appState.backgroundTasks.filter { !$0.state.isFinished }
        if let t = active.first {
            rt.primeContext(
                "Context: a background task \"\(t.title)\" is still running. If the user asks about it, "
                + "tell them it's still in progress.", respond: false)
        }
    }

    /// No speech for `idlePauseSeconds` → pause the realtime stream and return to wake listening.
    private func goToSleep() {
        guard realtimeActive else { return }
        realtimeActive = false
        IRISLog.log("idle → pausing realtime, back to wake-word listening")
        realtimeSession?.stop()
        appState.status = .idle
        appState.transcript = ""
        appState.responseText = ""
        wakeWord?.start()
    }

    /// A turn's spend pushed the monthly budget past the cap mid-conversation: end the paid realtime
    /// stream now and tell the user. The next "hey iris" re-checks the tier in `wakeUp()` and falls
    /// back to the free `claude -p` pipeline, so spend can't keep climbing in one long sitting.
    private func handleBudgetExhausted() {
        guard realtimeActive else { return }
        IRISLog.log("budget cap reached mid-conversation → ending realtime, switching to free pipeline")
        speaker?.enqueue("That's the monthly budget reached, so I'll switch to the free mode now.")
        goToSleep()
    }

    /// Surface the Screen Recording prompt at launch (for screen vision). macOS can't fully grant
    /// it programmatically — this adds IRIS to the list and prompts; the user may still need to
    /// toggle it in System Settings → Privacy & Security → Screen Recording and relaunch.
    private func requestScreenRecordingPermission() {
        DispatchQueue.global(qos: .utility).async {
            let granted = CGRequestScreenCaptureAccess()
            NSLog("[IRIS] screen recording access granted: \(granted)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeWord?.stop()
        realtimeSession?.stop()
        speaker?.stop()
        costGovernor.flush()   // persist any debounced spend before exit
        agentManager?.shutdown()
        panel?.hide()
        if let m = globalHotkeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localHotkeyMonitor { NSEvent.removeMonitor(m) }
    }

    // Accessory app with no standard windows — never quit just because a window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Component factories

    /// Build a Speaker from the current settings, wiring the finished→idle callback.
    private func makeSpeaker() -> Speaker {
        let speaker = Speaker(settings: settings, appState: appState, costGovernor: costGovernor)
        speaker.onFinished = { [weak self] in self?.speechFinished() }
        return speaker
    }

    /// Build a WakeWordDetector from the current settings, wiring the command handler.
    private func makeWakeWord() -> WakeWordDetector {
        let wake = WakeWordDetector(settings: settings, appState: appState)
        wake.onWakeWordDetected = { [weak self] command in
            self?.handleCommand(command)
        }
        wake.onBargeIn = { [weak self] in
            self?.handleVoiceBargeIn()
        }
        return wake
    }

    /// The user spoke over IRIS: stop talking (and any queued announcements) and return to
    /// listening. Background agents are deliberately left running.
    private func handleVoiceBargeIn() {
        guard appState.isSpeaking else { return }
        speaker?.stop()
    }

    // MARK: - Settings window + live apply

    private func showSettings() {
        settingsWindowController.show(settings: settings) { [weak self] anthropic, openAI, model, budget in
            guard let self else { return }
            let new = self.settings.withUpdatedKeys(
                anthropic: anthropic, openAI: openAI, model: model, budget: budget)
            do {
                try new.save()
            } catch {
                NSLog("[IRIS] failed to save settings: \(error.localizedDescription)")
            }
            self.applySettings(new)
        }
    }

    /// Apply updated settings live, rebuilding only the components whose inputs changed.
    private func applySettings(_ new: IRISSettings) {
        let keysChanged = new.anthropicAPIKey != settings.anthropicAPIKey
            || new.openAIAPIKey != settings.openAIAPIKey
            || new.model != settings.model
        let voiceChanged = new.voice != settings.voice
            || new.voiceIdentifier != settings.voiceIdentifier
            || new.ttsRate != settings.ttsRate
            || new.openAITTSEnabled != settings.openAITTSEnabled
            || new.ttsVoice != settings.ttsVoice
            || new.ttsModel != settings.ttsModel
            || new.ttsInstructions != settings.ttsInstructions
            || new.openAIAPIKey != settings.openAIAPIKey   // OpenAI TTS uses this key
        let localeChanged = new.voice != settings.voice

        settings = new

        if keysChanged {
            // The brain captures keys/model at init, so a fresh instance is the only way
            // to pick up new credentials. Cheap, and has no audio impact.
            brain = IRISBrain(settings: new)
        }
        if voiceChanged {
            // Speaker caches the resolved voice lazily; rebuild to re-resolve it.
            let newSpeaker = makeSpeaker()
            speaker = newSpeaker
            agentManager?.setSpeaker(newSpeaker)   // keep completion announcements wired
        }
        // Keep the cost governor in sync with the new budget + realtime model.
        costGovernor.applyBudget(new.monthlyBudgetUSD)
        costGovernor.applyRealtimeModel(new.realtimeModel)
        // Apply sidecar-affecting changes (keys/model/port/python) — may restart the sidecar.
        agentManager?.applySettings(new)
        realtimeSession?.applySettings(new)
        if localeChanged {
            // The detector's SFSpeechRecognizer is locale-bound; restart it. (wakePhrase is
            // read live per-transcript, so a phrase-only change needs no restart.)
            wakeWord?.stop()
            let wake = makeWakeWord()
            wakeWord = wake
            wake.start()
        }
    }

    // MARK: - Interrupt hotkey

    /// ⌥⎋ (Option+Escape). 53 is the virtual keycode for Escape; we additionally require the
    /// Option modifier so it doesn't collide with a bare Escape elsewhere.
    private static let interruptKeyCode: UInt16 = 53

    private func installInterruptHotkey() {
        let matches: (NSEvent) -> Bool = { event in
            event.keyCode == AppDelegate.interruptKeyCode
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
        }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matches(event) else { return }
            // Global monitors run off the main actor's static-isolation guarantee; hop on.
            Task { @MainActor in self?.handleInterruptRequest() }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matches(event) else { return event }
            self?.handleInterruptRequest()
            return nil   // swallow the event so it isn't beeped at as unhandled
        }
    }

    /// User explicitly asked to stop (hotkey or menu). Cancel everything foreground and reset.
    private func handleInterruptRequest() {
        guard !foregroundTasks.isEmpty || appState.isSpeaking || appState.status != .idle else { return }
        interrupt()
        appState.status = .idle
        appState.responseText = ""
    }

    // MARK: - Command pipeline

    /// Route the command, then either answer in the FOREGROUND (concurrently — consecutive
    /// questions don't cancel each other; their answers are serialized by the Speaker queue) or
    /// dispatch a BACKGROUND agent task. Updates `AppState` on the main actor.
    private func handleCommand(_ command: String) {
        // A bare spoken "stop" (or "never mind", "be quiet", …) is a FULL interrupt: cancel all
        // in-flight foreground work and silence IRIS, so a previously-started answer doesn't
        // resume playing after you've told it to stop. (Wake-phrase barge-in already stopped the
        // current utterance the moment "hey iris" was heard; this prevents it coming back.)
        if Self.isStopCommand(command) {
            interrupt()
            appState.status = .idle
            appState.responseText = ""
            return
        }

        // Debounce exact-duplicate commands (defends against self-hearing / stutter loops where
        // IRIS's own words get re-delivered as the same command repeatedly).
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == lastCommandText, Date().timeIntervalSince(lastCommandAt) < 3.0 {
            NSLog("[IRIS] ignoring duplicate command within 3s: \"\(command)\"")
            return
        }
        lastCommandText = normalized
        lastCommandAt = Date()
        expectingFollowUp = false   // recomputed per command (set only when IRIS asks something)

        // If a background task is waiting on the user, this utterance is its answer — route it to
        // resume the task instead of normal command handling. (Realtime mode answers via the
        // `answer_task` tool; this is the classic / free-tier path.)
        if let pq = pendingQuestion {
            clearPendingQuestion()
            agentManager.resume(pq.id, answer: command)
            finishForeground("Okay, passing that along.")
            return
        }

        // Explicit teaching ("remember…", "from now on…", "always…") — store it and confirm,
        // skipping normal routing. Backstop for the non-realtime path (realtime uses the
        // `remember` tool instead).
        if handleTeaching(command) { return }

        // Otherwise consecutive commands run CONCURRENTLY — a new question never cancels an
        // in-flight one (both get answered). Background agents in `agentManager` are untouched.
        appState.status = .thinking
        appState.responseText = ""

        let id = UUID()
        let task = Task { @MainActor in
            defer {
                foregroundTasks[id] = nil
                // If nothing else is working or talking, settle the orb back to idle.
                if foregroundTasks.isEmpty, !appState.isSpeaking, appState.status == .thinking {
                    appState.status = .idle
                }
            }

            // Spoken cancellation of a running agent ("cancel the deal search").
            let lower = command.lowercased()
            if lower.hasPrefix("cancel ") || lower.hasPrefix("stop the ")
                || lower.contains("cancel the") {
                if let title = agentManager.cancelMatching(command) {
                    finishForeground("Okay, I cancelled \(title).")
                    return
                }
            }

            let router = IntentRouter(settings: settings, urlSession: .shared,
                                      costGovernor: costGovernor)
            let intent = await router.route(command)
            if Task.isCancelled { return }

            switch intent {
            case .answer:
                // Answer time/date locally (correct + instant; no "I can't access the clock").
                if let local = LocalAnswers.answer(for: command) {
                    finishForeground(local)
                    return
                }
                let history = historyForLLM()
                var screenshotPath: String? = nil
                if Self.isVisionQuestion(command) {
                    // Acknowledge right away so there's no dead air while we capture + analyze.
                    finishForeground("Let me take a look.")
                    screenshotPath = await screenCapture.capture()
                    if Task.isCancelled { return }
                }
                let memoryBlock = settings.memoryEnabled ? memory.promptBlock() : ""
                let reply = await brain?.ask(transcript: command, screenshotPath: screenshotPath,
                                             history: history, memory: memoryBlock) ?? IRISBrain.genericError
                if Task.isCancelled { return }
                recordTurn(user: command, assistant: reply)
                maybeLearn(from: command, reply: reply)   // inferred ("learns from itself")
                // If IRIS asked something, auto-listen for the reply (no wake word) afterward.
                expectingFollowUp = Self.looksLikeQuestion(reply)
                finishForeground(reply)

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
                // Don't spawn multiple terminals in quick succession (loop guard).
                if Date().timeIntervalSince(lastTerminalLaunchAt) < 5.0 {
                    finishForeground("I just opened a terminal a moment ago.")
                    return
                }
                lastTerminalLaunchAt = Date()
                let target = dir ?? settings.defaultAgentDirectory
                // Open the terminal and, when a Claude session starts, apply any learned screen rule
                // (e.g. the "trust this folder?" prompt) and fold its spoken note into the reply.
                let reply = await ScreenRuleEngine.openTerminalApplyingRules(
                    in: target, startClaude: startClaude, settings: settings,
                    memory: memory, screenCapture: screenCapture, costGovernor: costGovernor)
                if Task.isCancelled { return }
                // If the user named a folder we couldn't resolve, say so instead of pretending.
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
            }
        }
        foregroundTasks[id] = task
    }

    /// A bare "stop"-type command → full interrupt. Phrases WITH an object ("stop the deal
    /// search") are NOT here — those route to agent cancellation.
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

    /// Heuristic: does this question need a screenshot? Non-vision questions skip the capture
    /// (faster); vision ones get an immediate "Let me take a look." ack first.
    private static func isVisionQuestion(_ s: String) -> Bool {
        let l = s.lowercased()
        let keys = ["screen", "looking at", "do you see", "what's this", "what is this",
                    "read this", "this page", "this window", "on my display", "what am i",
                    "see here", "in front of me", "highlighted", "what do you see"]
        return keys.contains { l.contains($0) }
    }

    /// Queue a foreground reply to be spoken (concurrent answers are serialized by the queue)
    /// and show it in the overlay.
    private func finishForeground(_ reply: String) {
        appState.responseText = reply
        speaker?.enqueue(reply)
    }

    /// Hand a task to the background agent manager and immediately acknowledge by voice so
    /// the user can move on to the next request while it runs. Returns to listening at once.
    private func dispatchBackground(
        kind: AgentTaskKind, detail: String, title: String?, cwd: String?, ack: String
    ) {
        agentManager.launch(kind: kind, detail: detail, title: title, cwd: cwd)
        appState.responseText = ack
        speaker?.enqueue(ack)
    }

    /// Cancel ALL in-flight foreground commands and stop any speech. Cancelling the tasks
    /// propagates Swift cancellation into IRISBrain — including terminating a running `claude`
    /// subprocess (see ClaudeProcessRunner) and the Anthropic/OpenAI URLSession calls.
    private func interrupt() {
        for t in foregroundTasks.values { t.cancel() }
        foregroundTasks.removeAll()
        speaker?.stop()   // delegate fires handleSpeechEnded → speechFinished()
    }

    /// Called when IRIS has fully finished talking. If it just asked a question, auto-listen for
    /// the answer (no wake word). Otherwise return to idle when nothing else is in flight.
    private func speechFinished() {
        guard foregroundTasks.isEmpty else { return }
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

    // MARK: - Steerable agents (deliver a paused task's question, route the answer)

    /// A background task paused to ask the user something. Deliver it by voice and arrange to
    /// capture the answer: in realtime via the `answer_task` tool (primed here), or — when asleep /
    /// in the free tier — by speaking it and listening for the next utterance (the follow-up path).
    private func handleAgentQuestion(_ task: AgentTask) {
        let q = task.question ?? "I need a decision from you to continue."
        pendingQuestion = (task.id, q)
        if realtimeActive, let rt = realtimeSession, rt.isActive {
            rt.awaitingAnswer = true
            rt.primeContext(
                "A background task is asking the user: \"\(q)\". Ask the user this now, and when "
                + "they answer call answer_task with their reply.", respond: true)
        } else {
            appState.responseText = q
            speaker?.enqueue(q)
            expectingFollowUp = true   // speechFinished → captureFollowUp() → handleCommand answer
        }
    }

    /// Clear the pending-question state once a task is answered or cancelled.
    private func clearPendingQuestion() {
        pendingQuestion = nil
        realtimeSession?.awaitingAnswer = false
    }

    /// Recent conversation turns to give the model context; cleared when stale (>2 min) so an
    /// unrelated later command doesn't carry old baggage.
    private func historyForLLM() -> [[String: String]] {
        if Date().timeIntervalSince(lastTurnAt) > 120 { conversation.removeAll() }
        return Array(conversation.suffix(8))
    }

    private func recordTurn(user: String, assistant: String) {
        conversation.append(["role": "user", "content": user])
        conversation.append(["role": "assistant", "content": assistant])
        if conversation.count > 16 { conversation.removeFirst(conversation.count - 16) }
        lastTurnAt = Date()
    }

    // MARK: - Learning (foreground backstop; realtime uses the `remember` tool)

    /// Handle a "teach IRIS something" instruction. A pure fact/preference ("remember that I like
    /// Chrome") is stored and confirmed, skipping normal routing. But a standing instruction that
    /// also names an action ("always open Chrome", "from now on start my email") is remembered AND
    /// still carried out — it must not be silently swallowed into an inert note. Returns true when
    /// handled (stored, and possibly dispatched).
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

    /// Whether a taught remainder is really an imperative command (so it should be ACTED ON, not
    /// just stored): a leading action verb, or a remainder the router maps to a concrete intent.
    private func isActionableInstruction(_ remainder: String) -> Bool {
        let lower = remainder.lowercased()
        let verbs = ["open ", "launch ", "start ", "run ", "play ", "close ", "search ", "google ",
                     "look up ", "show ", "go to ", "schedule ", "set ", "create ", "find ",
                     "type ", "press ", "click ", "switch to "]
        if verbs.contains(where: { lower.hasPrefix($0) }) { return true }
        let router = IntentRouter(settings: settings, urlSession: .shared)
        if let intent = router.strongHeuristic(remainder), intent != .answer { return true }
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

    /// "Learns from itself": when a turn carries a preference/correction cue, ask the brain to
    /// extract durable memories and store them (deduped), announcing if anything new was saved.
    /// Gated so it never runs on ordinary turns. No-op in realtime (that path self-saves).
    private func maybeLearn(from userTurn: String, reply: String) {
        guard settings.memoryEnabled, let brain, Self.hasLearningCue(userTurn) else { return }
        Task { @MainActor in
            let candidates = await brain.extractMemories(userTurn: userTurn, assistantTurn: reply)
            let added = candidates.filter {
                memory.add(text: $0, kind: .preference, source: .inferred)
            }
            if !added.isEmpty { speaker?.enqueue("Noted — I'll remember that.") }
        }
    }

    private static func hasLearningCue(_ s: String) -> Bool {
        let l = s.lowercased()
        // Only cues that genuinely signal a durable preference/identity/standing instruction. We
        // deliberately drop broad words ("actually", "instead of", bare "stop "/"don't ") that fire
        // on ordinary commands ("stop the timer", "don't open that") and caused a spurious
        // extractMemories round-trip + out-of-place "Noted — I'll remember that".
        let cues = ["i prefer", "i like", "i always", "i usually", "i hate", "i don't like",
                    "i don't want", "from now on", "my name is", "call me", "i want you to",
                    "please don't", "i'd prefer", "i would prefer"]
        return cues.contains { l.contains($0) }
    }
}
