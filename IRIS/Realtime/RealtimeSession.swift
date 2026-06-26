//
//  RealtimeSession.swift
//  IRIS — Realtime lane (the Jarvis/Cluely conversational core)
//
//  Owns a WebSocket to the OpenAI Realtime API for continuous speech-to-speech: streams mic audio
//  up, plays the model's voice back, and lets the model call tools (RealtimeTools) to actually do
//  things on the Mac. Server VAD handles turn-taking + barge-in; AEC (RealtimeAudio) stops IRIS
//  hearing itself. Replaces the classic wake-word pipeline when Settings.realtimeEnabled is true.
//

import Foundation
import AVFoundation

/// Tiny thread-safe bool the audio thread can read while the main actor writes it.
private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ initial: Bool) { v = initial }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
}

@MainActor
final class RealtimeSession {
    private var settings: Settings
    private weak var appState: AppState?
    private weak var agentManager: AgentManager?
    private let screenCapture: ScreenCapture
    /// The persistent brain. Its contents are folded into the model's instructions so IRIS recalls
    /// what it has learned, and the `remember`/`forget` tools write back to it mid-conversation.
    private let memory: MemoryStore?

    /// Meters realtime spend (exact, from each turn's `usage`) against the monthly budget.
    private weak var costGovernor: CostGovernor?

    private let audio = RealtimeAudio()
    private let urlSession = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var shouldRun = false
    private var reconnecting = false
    /// True while IRIS is speaking; used to gate the mic in half-duplex (no-AEC) mode.
    private let modelSpeaking = AtomicBool(false)

    /// Fires when the conversation has been idle (no speech) for `idlePauseSeconds` — AppDelegate
    /// pauses the stream and returns to wake-word listening.
    var onIdleTimeout: (() -> Void)?
    /// Fires when a turn's metered spend pushes the budget past the cap mid-conversation — AppDelegate
    /// ends the paid stream now (next wake falls back to the free `claude -p` pipeline) instead of
    /// letting a single long sitting blow past the monthly budget.
    var onBudgetExhausted: (() -> Void)?
    private var idleTimer: Timer?
    private var hideGen = 0

    /// Background-task results to be spoken by the MAIN voice (so they never overlap it). Queued
    /// while a response is in progress, flushed when IRIS finishes the current turn.
    private var pendingAnnouncements: [String] = []
    private var responseActive = false

    /// True after IRIS's last spoken turn ended with a question — extends the idle grace so the
    /// user has time to answer before the session sleeps. Cleared when the user starts speaking.
    private var lastReplyWasQuestion = false
    /// True while the user is actively speaking (between server-VAD speech_started/speech_stopped).
    /// The idle timer is suspended during this window so a long utterance never trips "no speech".
    private var userSpeaking = false
    /// Set by AppDelegate when a background task is waiting on the user's answer — also extends the
    /// idle grace so the answer isn't cut off.
    var awaitingAnswer = false
    /// One-shot system-context messages to inject once the session is ready (e.g. on re-wake, to
    /// surface an in-flight background task or re-ask a task's pending question).
    private var pendingContext: [(text: String, respond: Bool)] = []
    private var sessionReady = false

    init(settings: Settings, appState: AppState, agentManager: AgentManager?,
         screenCapture: ScreenCapture, memory: MemoryStore?, costGovernor: CostGovernor? = nil) {
        self.settings = settings
        self.appState = appState
        self.agentManager = agentManager
        self.screenCapture = screenCapture
        self.memory = memory
        self.costGovernor = costGovernor
    }

    private static let persona = """
    You are IRIS, a witty, capable voice assistant on the user's Mac — think Jarvis from Iron Man. \
    You're in a continuous spoken conversation: be warm, concise, and natural, usually one or two \
    sentences. You can actually DO things by calling your tools — open apps and folders, search the \
    web in the browser, open terminals and start Claude Code sessions, run long tasks in the \
    background, look at the user's screen, and control the Mac by typing and clicking. Prefer doing \
    over explaining: when the user asks for something, call the right tool(s), chaining several when \
    a task needs multiple steps. Ask a brief clarifying question only when you truly need to. Before \
    anything destructive (deleting, sending, overwriting), confirm first. Never read URLs, code, or \
    long lists aloud — summarize. \
    You have a long-term memory: when the user teaches you a durable preference, gives a standing \
    instruction ("from now on", "always", "next time", "don't ask again"), or corrects you, call \
    the `remember` tool and briefly say you'll remember it. For a recurring on-screen step (like a \
    confirmation dialog) also pass a `trigger` describing what's on screen and an `action` like \
    "press enter". Keep memories short and don't save ones you already have; use `forget` to drop \
    something. Apply what you've learned proactively, without being asked. \
    Don't open apps or websites the user didn't ask for. For a research or shopping request, pick \
    ONE approach — either run a background task OR do a web search, not both. When a background \
    task needs a decision it will ask through you: relay its question, and once the user answers \
    call `answer_task` with their reply. If the user wants to redirect a running task ("look \
    elsewhere", "try Amazon instead"), call `redirect_task` with their new instruction.
    """

    /// The model's instructions = persona + the learned-memory block (so IRIS recalls what it
    /// knows). Recomputed whenever memory changes; sent via `session.update`.
    private func instructions() -> String {
        guard settings.memoryEnabled, let memory else { return Self.persona }
        let block = memory.promptBlock(limit: 40)
        return block.isEmpty ? Self.persona : Self.persona + "\n\n" + block
    }

    /// Push updated instructions to the live session after the brain changes mid-conversation
    /// (e.g. right after a `remember`/`forget` tool call), so new learning takes effect at once.
    private func refreshInstructions() {
        guard shouldRun else { return }
        send(["type": "session.update",
              "session": ["type": "realtime", "instructions": instructions()]])
    }

    // MARK: - Lifecycle

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        connect()
    }

    func stop() {
        shouldRun = false
        userSpeaking = false
        idleTimer?.invalidate(); idleTimer = nil
        audio.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Idle / hide

    /// (Re)start the no-speech countdown; firing it pauses the session back to wake-word listening.
    /// When IRIS just asked a question (or a background task is waiting on the user), use a much
    /// longer grace so the answer isn't cut off by the normal short idle pause.
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        // Never sleep while the user is mid-utterance — a long request can exceed the idle window
        // and should not be cut off. The timer restarts when they stop speaking (speech_stopped).
        guard !userSpeaking else { idleTimer = nil; return }
        let base = max(5, settings.idlePauseSeconds)
        let secs = TimeInterval((lastReplyWasQuestion || awaitingAnswer) ? max(45, base) : base)
        idleTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                IRISLog.log("realtime: idle \(Int(secs))s with no speech — pausing")
                self.onIdleTimeout?()
            }
        }
    }

    /// After IRIS finishes talking, hide the overlay shortly after (unless new activity arrives).
    private func scheduleHide() {
        hideGen += 1
        let g = hideGen
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, g == self.hideGen, self.appState?.status == .idle else { return }
            self.appState?.transcript = ""
        }
    }

    func applySettings(_ new: Settings) { settings = new }

    /// Whether the realtime session is live (used to decide if announcements go to the main voice).
    var isActive: Bool { shouldRun }

    /// Have the MAIN voice speak a background-task result as its next turn (no overlap).
    func announce(_ text: String) {
        guard shouldRun, !text.isEmpty else { return }
        pendingAnnouncements.append(text)
        flushAnnouncements()
    }

    /// Inject a one-shot system-context message once the session is ready. Used on re-wake to tell
    /// the model about an in-flight background task or to re-ask a task's pending question. When
    /// `respond` is true, IRIS speaks immediately (e.g. to re-ask the question); otherwise it just
    /// holds the context until the user speaks.
    func primeContext(_ text: String, respond: Bool = false) {
        guard shouldRun, !text.isEmpty else { return }
        pendingContext.append((text, respond))
        flushContext()
    }

    private func flushContext() {
        guard shouldRun, sessionReady, !pendingContext.isEmpty else { return }
        let items = pendingContext
        pendingContext.removeAll()
        var wantsResponse = false
        for item in items {
            send([
                "type": "conversation.item.create",
                "item": ["type": "message", "role": "system",
                         "content": [["type": "input_text", "text": item.text]]],
            ])
            if item.respond { wantsResponse = true }
        }
        if wantsResponse, !responseActive {
            send(["type": "response.create"])
            responseActive = true
        }
    }

    private func flushAnnouncements() {
        guard shouldRun, !responseActive, !pendingAnnouncements.isEmpty else { return }
        let text = pendingAnnouncements.removeFirst()
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": "system",
                "content": [["type": "input_text",
                             "text": "A background task you were running just finished. Tell the user now, in one short sentence: \(text)"]],
            ],
        ])
        send(["type": "response.create"])
        responseActive = true
    }

    // MARK: - Connection

    private func connect() {
        guard let key = settings.openAIAPIKey, !key.isEmpty else {
            NSLog("[IRIS] realtime: no OpenAI key — cannot start realtime session")
            return
        }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(settings.realtimeModel)") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // NB: do NOT send "OpenAI-Beta: realtime=v1" — that selects the disabled beta shape.
        // The GA API uses the nested `audio` session shape configured below.

        let task = urlSession.webSocketTask(with: req)
        socket = task
        task.resume()
        IRISLog.log("realtime: connecting to \(settings.realtimeModel)")

        sessionReady = false
        userSpeaking = false
        configureSession()
        receive()
        startAudio()
        resetIdleTimer()
    }

    private func configureSession() {
        // GA Realtime session shape: audio config nested under `audio.input` / `audio.output`,
        // PCM at 24 kHz, server VAD for turn-taking + barge-in.
        let sessionObj: [String: Any] = [
            "type": "realtime",
            "instructions": instructions(),
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 500,
                    ],
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": settings.realtimeVoice,
                ],
            ],
            "tools": RealtimeTools.schemas(computerUse: settings.computerUseEnabled,
                                           memoryEnabled: settings.memoryEnabled),
            "tool_choice": "auto",
        ]
        send(["type": "session.update", "session": sessionObj])
    }

    private func startAudio(attempt: Int = 0) {
        audio.onMicPCM16 = { [weak self] data in
            guard let self else { return }
            // Half-duplex when AEC is unavailable: don't feed the mic while IRIS's audio is
            // actually playing out the speaker (+ a short decay grace) — this is tied to real
            // playback, not the WS event, so the mic never hears IRIS's tail and loops. With AEC
            // on we always stream → true barge-in.
            if !self.audio.aecActive && self.audio.isOutputting { return }
            self.sendRaw(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
        }
        do {
            try audio.start(preferAEC: settings.echoCancellation)
            appState?.status = .listening
            IRISLog.log("realtime: mic streaming started (AEC preferred: \(settings.echoCancellation))")
        } catch {
            // Mic often isn't ready immediately at launch — retry a few times.
            IRISLog.log("realtime: audio start failed (attempt \(attempt)): \(error.localizedDescription)")
            if attempt < 12, shouldRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.shouldRun else { return }
                    self.startAudio(attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Send

    /// Send on the main actor.
    private func send(_ obj: [String: Any]) { sendRaw(obj) }

    /// Send from any thread (URLSessionWebSocketTask.send is thread-safe + non-blocking).
    nonisolated private func sendRaw(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor [weak self] in
            self?.socket?.send(.string(str)) { err in
                if let err { NSLog("[IRIS] realtime send error: \(err.localizedDescription)") }
            }
        }
    }

    // MARK: - Receive

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.shouldRun else { return }
                switch result {
                case .failure(let error):
                    IRISLog.log("realtime socket closed: \(error.localizedDescription)")
                    self.scheduleReconnect()
                case .success(let message):
                    switch message {
                    case .string(let s): self.handleEvent(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handleEvent(s) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldRun, !reconnecting else { return }
        reconnecting = true
        audio.stop()
        socket = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.reconnecting = false
            if self.shouldRun { self.connect() }
        }
    }

    // MARK: - Events

    private func handleEvent(_ raw: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "session.created":
            IRISLog.log("realtime: session.created")
        case "session.updated":
            IRISLog.log("realtime: session.updated (ready)")
            sessionReady = true
            flushContext()   // inject any queued re-wake context now that the session is live

        case "input_audio_buffer.speech_started":
            // User started talking — barge in: drop IRIS's current audio and listen.
            audio.stopPlayback()
            modelSpeaking.set(false)
            lastReplyWasQuestion = false   // the user is responding; back to normal idle grace
            userSpeaking = true            // suspend the idle timer for the whole utterance
            hideGen += 1                 // cancel any pending hide
            appState?.status = .listening
            resetIdleTimer()

        case "input_audio_buffer.speech_stopped":
            // User finished an utterance — start the silence countdown from now (not from when
            // they began), so a long request never trips the idle pause mid-sentence.
            userSpeaking = false
            resetIdleTimer()

        case "response.created":
            responseActive = true
            hideGen += 1
            appState?.status = .thinking
            appState?.transcript = ""   // fresh caption for this reply
            resetIdleTimer()

        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = obj["delta"] as? String, let data = Data(base64Encoded: b64) {
                modelSpeaking.set(true)
                appState?.status = .speaking
                audio.playPCM16(data)
                resetIdleTimer()
            }

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = obj["delta"] as? String {
                appState?.transcript = (appState?.transcript ?? "") + delta
            }

        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let text = obj["transcript"] as? String {
                appState?.transcript = text
                // If IRIS just asked something, keep listening longer for the answer.
                lastReplyWasQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            }

        case "response.function_call_arguments.done":
            handleToolCall(obj)

        case "response.done":
            // Meter this turn's exact spend against the monthly budget (audio/text in+out,
            // cached vs uncached) before resetting state.
            if let resp = obj["response"] as? [String: Any],
               let usage = resp["usage"] as? [String: Any] {
                costGovernor?.recordRealtime(usage: usage)
            }
            // IRIS finished talking: hide the overlay shortly after, and restart the idle clock.
            responseActive = false
            modelSpeaking.set(false)
            appState?.status = .idle
            scheduleHide()
            resetIdleTimer()
            flushAnnouncements()   // speak any queued background-task results next
            // Hard budget ceiling: if this turn's spend pushed us out of the premium tier, end the
            // paid session now rather than waiting for the idle timer — otherwise a single long
            // back-and-forth (idle timer resets each turn) can run far past the monthly cap.
            if costGovernor?.allowsRealtime == false {
                IRISLog.log("realtime: budget exhausted mid-session — ending paid stream")
                onBudgetExhausted?()
            }

        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? raw
            IRISLog.log("realtime ERROR: \(msg)")

        default:
            break
        }
    }

    private func handleToolCall(_ obj: [String: Any]) {
        guard let name = obj["name"] as? String,
              let callId = obj["call_id"] as? String else { return }
        let argsStr = obj["arguments"] as? String ?? "{}"
        let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
        IRISLog.log("realtime tool call: \(name) \(argsStr)")

        Task { @MainActor in
            let result = await RealtimeTools.run(
                name: name, args: args, settings: settings,
                agentManager: agentManager, screenCapture: screenCapture, memory: memory,
                costGovernor: costGovernor)
            // Memory changed mid-conversation → push refreshed instructions so it applies now.
            if name == "remember" || name == "forget" { refreshInstructions() }
            send([
                "type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": callId, "output": result],
            ])
            send(["type": "response.create"])   // let the model speak the result
        }
    }
}
