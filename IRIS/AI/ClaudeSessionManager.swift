//
//  ClaudeSessionManager.swift
//  IRIS — streaming headless Claude Code sessions
//
//  Replaces AgentMode + AgentManager + SidecarClient + the Python LangGraph sidecar with
//  the `claude` CLI itself: each background task is one
//    claude -p --output-format stream-json --verbose [--resume <id>]
//  subprocess (prompt via temp-file stdin — plan.md fix #2). Tool-use events stream live
//  into the task pill ("Editing README.md"), throttled milestones are narrated by voice,
//  the final result line is spoken (Haiku-digested when long), and every session lands in
//  a registry (~/.iris/sessions.json) so "continue that task" resumes it with full context.
//
//  Background sessions are independent of the foreground voice pipeline — launching one
//  never cancels another, and a foreground barge-in never touches them.
//

import Foundation

@MainActor
final class ClaudeSessionManager {

    /// One remembered session in ~/.iris/sessions.json.
    struct SessionRecord: Codable {
        let sessionId: String
        var title: String
        var prompt: String
        var cwd: String
        let startedAt: Date
        var finishedAt: Date?
        var status: String            // running | succeeded | failed | cancelled
        var lastResultSummary: String?
    }

    static let registryCap = 20
    /// How long a finished task pill lingers before it's removed from the overlay.
    static let pruneDelayNanos: UInt64 = 25_000_000_000
    /// Minimum gap between narrated milestones for one session.
    static let narrationGapSeconds: TimeInterval = 20
    /// Final results longer than this get a one-sentence Haiku digest before being spoken.
    static let spokenResultMaxChars = 350

    static let agentSystemPrompt = """
    You are \(Persona.name) in agent mode, operating on the user's Mac. Carry out the task below \
    using the tools available to you. When finished, reply with a single concise sentence \
    summarizing what you did — it will be spoken aloud, so use plain prose with no markdown, \
    lists, or code fences.
    """

    private var settings: Settings
    private weak var appState: AppState?
    private weak var speaker: Speaker?
    private weak var memory: MemoryStore?
    private weak var engine: ClaudeEngine?

    /// In-flight session tasks by pill id; cancelling one terminates its subprocess.
    private var running: [String: Task<Void, Never>] = [:]
    /// Pill ids the user cancelled (so the terminated run is marked cancelled, not failed).
    private var cancelled: Set<String> = []
    private var lastNarrationAt: [String: Date] = [:]
    private var narratedFirstTool: Set<String> = []
    private var pruneTasks: [String: Task<Void, Never>] = [:]

    private var registry: [SessionRecord] = []
    private let registryURL: URL
    private let logsDir: URL

    /// Spoken announcements route here (AppDelegate → Speaker queue).
    var onAnnouncement: ((String) -> Void)?

    init(settings: Settings, appState: AppState, speaker: Speaker,
         memory: MemoryStore?, engine: ClaudeEngine?) {
        self.settings = settings
        self.appState = appState
        self.speaker = speaker
        self.memory = memory
        self.engine = engine
        let iris = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iris", isDirectory: true)
        self.registryURL = iris.appendingPathComponent("sessions.json")
        self.logsDir = iris.appendingPathComponent("logs", isDirectory: true)
        loadRegistry()
    }

    func applySettings(_ new: Settings) { settings = new }
    func setSpeaker(_ s: Speaker) { speaker = s }
    func setEngine(_ e: ClaudeEngine) { engine = e }

    /// Terminate all running sessions (app quit). They remain resumable via the registry.
    func shutdown() {
        for t in running.values { t.cancel() }
        running.removeAll()
        for t in pruneTasks.values { t.cancel() }
        pruneTasks.removeAll()
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        if let onAnnouncement { onAnnouncement(text) } else { speaker?.enqueue(text) }
    }

    // MARK: - Dispatch

    /// Launch a background Claude session for `detail`. Non-blocking; a pill appears at once.
    func launch(kind: AgentTaskKind, detail: String, title: String? = nil, cwd: String? = nil,
                resumeSessionId: String? = nil) {
        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else {
            announce("I can't start that task — the Claude command wasn't found.")
            return
        }
        let active = (appState?.backgroundTasks ?? []).filter { !$0.state.isFinished }
        guard active.count < settings.maxConcurrentAgents else {
            announce("I'm already running \(active.count) tasks — let one finish first.")
            return
        }

        let pillId = UUID().uuidString
        let pillTitle = title ?? Self.shortTitle(from: detail)
        let workDir = cwd ?? settings.defaultAgentDirectory
        var task = AgentTask(id: pillId, kind: kind, title: pillTitle, detail: detail,
                             state: .running)
        task.sessionId = resumeSessionId
        appState?.backgroundTasks.append(task)

        var prompt = Self.agentSystemPrompt
        if settings.memoryEnabled, let block = memory?.promptBlock(), !block.isEmpty {
            prompt += "\n\n" + block
        }
        if kind == .calendar {
            prompt += "\n\nThis is a calendar request. Use the configured calendar MCP tools "
                + "to carry it out; if none are available, say so plainly."
        }
        prompt += "\n\nTask: \(detail)"

        var args = ["-p", "--model", settings.agentModel ?? settings.model,
                    "--output-format", "stream-json", "--verbose"]
        if settings.claudeSkipPermissions { args.append("--dangerously-skip-permissions") }
        if let resumeSessionId { args += ["--resume", resumeSessionId] }
        let mcpConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iris/mcp.json")
        if FileManager.default.fileExists(atPath: mcpConfig.path) {
            args += ["--mcp-config", mcpConfig.path]
        }

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stderrURL = logsDir.appendingPathComponent("session-\(pillId).err")

        IRISLog.log("session: launching \"\(pillTitle)\" in \(workDir)"
                    + (resumeSessionId.map { " (resume \($0.prefix(8)))" } ?? ""))

        running[pillId] = Task { [weak self] in
            let result = await ClaudeProcessRunner.stream(
                binary: binary, args: args, prompt: prompt,
                cwd: workDir, stderrURL: stderrURL
            ) { event in
                Task { @MainActor [weak self] in
                    self?.handle(event, pillId: pillId, prompt: detail, cwd: workDir)
                }
            }
            await MainActor.run { [weak self] in
                self?.finish(pillId: pillId, result: result)
            }
        }
    }

    /// Resume the most recent remembered session with a new instruction
    /// ("continue that task, and also fix the typo").
    func resumeLatest(instruction: String) {
        guard let record = registry.last else {
            announce("I don't have a session to continue yet.")
            return
        }
        announce("Picking up \(record.title).")
        launch(kind: .agent, detail: instruction, title: record.title, cwd: record.cwd,
               resumeSessionId: record.sessionId)
    }

    /// Resume a specific pill's session with the user's answer (pending-question path).
    func resume(_ pillId: String, answer: String) {
        guard let task = appState?.backgroundTasks.first(where: { $0.id == pillId }),
              let sessionId = task.sessionId else {
            announce("That task can't take an answer right now.")
            return
        }
        launch(kind: task.kind, detail: answer, title: task.title,
               cwd: settings.defaultAgentDirectory, resumeSessionId: sessionId)
    }

    // MARK: - Cancellation

    /// Cancel by pill id (menu-bar / pill button). SIGTERM via task cancellation; escalate to
    /// SIGKILL only if the process ignores it (ClaudeProcessRunner resumes on stdout EOF).
    func cancel(_ pillId: String) {
        guard let task = running[pillId] else { return }
        cancelled.insert(pillId)
        task.cancel()
    }

    /// Cancel a running session referenced by a spoken phrase ("cancel the readme task").
    /// Matches on title/detail; if exactly one is active, cancels it. Returns its title, or nil.
    @discardableResult
    func cancelMatching(_ phrase: String) -> String? {
        let p = phrase.lowercased()
        let active = (appState?.backgroundTasks ?? []).filter { !$0.state.isFinished }
        guard !active.isEmpty else { return nil }

        func overlaps(_ field: String) -> Bool {
            let f = field.lowercased()
            return !f.isEmpty && (p.contains(f) || f.contains(p))
        }
        let match = active.first(where: { overlaps($0.title) || overlaps($0.detail) })
            ?? (active.count == 1 ? active.first : nil)
        guard let task = match else { return nil }
        cancel(task.id)
        return task.title
    }

    // MARK: - Event handling (main actor)

    private func handle(_ event: ClaudeStreamEvent, pillId: String, prompt: String, cwd: String) {
        switch event {
        case .initialized(let sessionId):
            updatePill(pillId) { $0.sessionId = sessionId }
            upsertRecord(SessionRecord(
                sessionId: sessionId,
                title: pillTitle(pillId) ?? "task",
                prompt: prompt, cwd: cwd, startedAt: Date(),
                finishedAt: nil, status: "running", lastResultSummary: nil))

        case .toolUse(_, let detail):
            updatePill(pillId) { $0.progressText = detail }
            narrateIfDue(pillId, line: detail)

        case .assistantText(let text):
            let short = text.count > 90 ? String(text.prefix(90)) + "…" : text
            updatePill(pillId) { $0.progressText = short }

        default:
            break   // .textDelta unused here; .result handled by finish()
        }
    }

    /// Narrate the first tool use immediately, then at most one line per 20s.
    private func narrateIfDue(_ pillId: String, line: String) {
        let now = Date()
        if !narratedFirstTool.contains(pillId) {
            narratedFirstTool.insert(pillId)
            lastNarrationAt[pillId] = now
            if let title = pillTitle(pillId) {
                announce("\(title): \(line).")
            }
            return
        }
        if now.timeIntervalSince(lastNarrationAt[pillId] ?? .distantPast) >= Self.narrationGapSeconds {
            lastNarrationAt[pillId] = now
            announce(line + ".")
        }
    }

    private func finish(pillId: String,
                        result: (ok: Bool, text: String, sessionId: String?, costUSD: Double?)) {
        running[pillId] = nil
        lastNarrationAt[pillId] = nil
        narratedFirstTool.remove(pillId)

        let wasCancelled = cancelled.remove(pillId) != nil
        let state: AgentTaskState = wasCancelled ? .cancelled : (result.ok ? .succeeded : .failed)
        updatePill(pillId) {
            $0.state = state
            $0.finishedAt = Date()
            $0.resultSummary = result.text.isEmpty ? nil : result.text
            if let sid = result.sessionId { $0.sessionId = sid }
        }
        if let sid = result.sessionId {
            updateRecord(sid) {
                $0.finishedAt = Date()
                $0.status = state.rawValue
                $0.lastResultSummary = result.text.isEmpty ? nil : result.text
            }
        }
        if let cost = result.costUSD {
            IRISLog.log("session: \(pillId.prefix(8)) \(state.rawValue), cost $\(String(format: "%.4f", cost))")
        }
        schedulePrune(pillId)

        guard !wasCancelled else { return }   // user-initiated; no announcement
        if result.ok, !result.text.isEmpty {
            speakResult(result.text)
        } else if !result.ok {
            announce(result.text.isEmpty
                ? "A background task hit an error — the details are in its log."
                : result.text)
        }
    }

    /// Speak the final result; long results get a one-sentence Haiku digest first (the only
    /// extra LLM call in the whole agent path).
    private func speakResult(_ text: String) {
        guard text.count > Self.spokenResultMaxChars, let engine else {
            announce(text)
            return
        }
        Task { @MainActor [weak self] in
            let digest = await engine.summarize(
                text, instruction: "Condense this task result into ONE short spoken sentence, "
                    + "plain prose, no markdown.")
            self?.announce(digest ?? String(text.prefix(Self.spokenResultMaxChars)))
        }
    }

    // MARK: - Pills

    private func updatePill(_ id: String, _ mutate: (inout AgentTask) -> Void) {
        guard let appState,
              let idx = appState.backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        var t = appState.backgroundTasks[idx]
        mutate(&t)
        appState.backgroundTasks[idx] = t
    }

    private func pillTitle(_ id: String) -> String? {
        appState?.backgroundTasks.first(where: { $0.id == id })?.title
    }

    private func schedulePrune(_ id: String) {
        pruneTasks[id]?.cancel()
        pruneTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pruneDelayNanos)
            guard let self, !Task.isCancelled else { return }
            self.appState?.backgroundTasks.removeAll { $0.id == id }
            self.pruneTasks[id] = nil
        }
    }

    /// A speakable short title from the task text ("add a README badge to…").
    static func shortTitle(from detail: String) -> String {
        let words = detail.split(whereSeparator: \.isWhitespace).prefix(6)
        var t = words.joined(separator: " ")
        if detail.split(whereSeparator: \.isWhitespace).count > 6 { t += "…" }
        return t.isEmpty ? "background task" : t
    }

    // MARK: - Registry (~/.iris/sessions.json)

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else {
            return
        }
        registry = records
    }

    private func saveRegistry() {
        if registry.count > Self.registryCap {
            registry.removeFirst(registry.count - Self.registryCap)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(registry) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    private func upsertRecord(_ record: SessionRecord) {
        if let idx = registry.firstIndex(where: { $0.sessionId == record.sessionId }) {
            // A resumed session: keep its slot but bump it to most-recent.
            var existing = registry.remove(at: idx)
            existing.prompt = record.prompt
            existing.status = "running"
            existing.finishedAt = nil
            registry.append(existing)
        } else {
            registry.append(record)
        }
        saveRegistry()
    }

    private func updateRecord(_ sessionId: String, _ mutate: (inout SessionRecord) -> Void) {
        guard let idx = registry.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        mutate(&registry[idx])
        saveRegistry()
    }
}
