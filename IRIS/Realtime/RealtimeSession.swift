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
    private var idleTimer: Timer?
    private var hideGen = 0

    /// Background-task results to be spoken by the MAIN voice (so they never overlap it). Queued
    /// while a response is in progress, flushed when IRIS finishes the current turn.
    private var pendingAnnouncements: [String] = []
    private var responseActive = false

    init(settings: Settings, appState: AppState, agentManager: AgentManager?,
         screenCapture: ScreenCapture) {
        self.settings = settings
        self.appState = appState
        self.agentManager = agentManager
        self.screenCapture = screenCapture
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
    long lists aloud — summarize.
    """

    // MARK: - Lifecycle

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        connect()
    }

    func stop() {
        shouldRun = false
        idleTimer?.invalidate(); idleTimer = nil
        audio.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Idle / hide

    /// (Re)start the no-speech countdown; firing it pauses the session back to wake-word listening.
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let secs = TimeInterval(max(5, settings.idlePauseSeconds))
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
            "instructions": Self.persona,
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
            "tools": RealtimeTools.schemas(computerUse: settings.computerUseEnabled),
            "tool_choice": "auto",
        ]
        send(["type": "session.update", "session": sessionObj])
    }

    private func startAudio(attempt: Int = 0) {
        audio.onMicPCM16 = { [weak self] data in
            guard let self else { return }
            // Half-duplex when AEC is unavailable: don't feed the mic while IRIS is speaking
            // (stops the mic hearing IRIS and looping). With AEC on we always stream → barge-in.
            if !self.audio.aecActive && self.modelSpeaking.value { return }
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

        case "input_audio_buffer.speech_started":
            // User started talking — barge in: drop IRIS's current audio and listen.
            audio.stopPlayback()
            modelSpeaking.set(false)
            hideGen += 1                 // cancel any pending hide
            appState?.status = .listening
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
            if let text = obj["transcript"] as? String { appState?.transcript = text }

        case "response.function_call_arguments.done":
            handleToolCall(obj)

        case "response.done":
            // IRIS finished talking: hide the overlay shortly after, and restart the idle clock.
            responseActive = false
            modelSpeaking.set(false)
            appState?.status = .idle
            scheduleHide()
            resetIdleTimer()
            flushAnnouncements()   // speak any queued background-task results next

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
                agentManager: agentManager, screenCapture: screenCapture)
            send([
                "type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": callId, "output": result],
            ])
            send(["type": "response.create"])   // let the model speak the result
        }
    }
}
