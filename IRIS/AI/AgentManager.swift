//
//  AgentManager.swift
//  IRIS — Vision + AI lane
//
//  Owns the SidecarClient and bridges background agent tasks into the app: it submits
//  tasks (non-blocking), consumes the sidecar's SSE event stream, mirrors each task into
//  `AppState.backgroundTasks` (so the overlay/menu show N agents running in parallel), and
//  speaks a completion announcement per task via the Speaker's announcement queue.
//
//  Background tasks are independent of the foreground voice pipeline — launching one never
//  cancels another, and a foreground barge-in never cancels background agents.
//

import Foundation

@MainActor
final class AgentManager {
    private let client: SidecarClient
    private weak var appState: AppState?
    private weak var speaker: Speaker?
    private var settings: Settings

    private var eventsTask: Task<Void, Never>?
    private var announced: Set<String> = []           // task ids whose result we've spoken
    private var pruneTasks: [String: Task<Void, Never>] = [:]

    /// Whether the sidecar is currently reachable (set after `start()` completes its probe).
    private(set) var isAvailable = false

    /// How long a finished task pill lingers before it's removed from the overlay.
    private let pruneDelayNanos: UInt64 = 25_000_000_000

    init(settings: Settings, appState: AppState, speaker: Speaker) {
        self.settings = settings
        self.appState = appState
        self.speaker = speaker
        self.client = SidecarClient(settings: settings)
    }

    // MARK: - Lifecycle

    func start() {
        eventsTask = Task { [weak self] in
            guard let self else { return }
            self.isAvailable = await self.client.start()
            if !self.isAvailable {
                NSLog("[IRIS] agent sidecar unreachable — background tasks disabled until it starts")
            }
            // Stream events until the task is cancelled (shutdown). The client reconnects
            // internally if the sidecar drops, so this loop is long-lived.
            for await event in self.client.events() {
                self.apply(event)
            }
        }
    }

    func shutdown() {
        eventsTask?.cancel()
        eventsTask = nil
        for t in pruneTasks.values { t.cancel() }
        pruneTasks.removeAll()
        client.stop()
    }

    /// Re-point at a rebuilt Speaker (AppDelegate rebuilds it when the voice changes).
    func setSpeaker(_ s: Speaker) { self.speaker = s }

    /// How to speak an announcement. AppDelegate routes this to the MAIN realtime voice when a
    /// conversation is active (so it doesn't overlap), or the TTS Speaker otherwise.
    var onAnnouncement: ((String) -> Void)?

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        if let onAnnouncement { onAnnouncement(text) } else { speaker?.enqueue(text) }
    }

    func applySettings(_ new: Settings) {
        let needsRestart = new.sidecarPort != settings.sidecarPort
            || new.sidecarPython != settings.sidecarPython
            || new.anthropicAPIKey != settings.anthropicAPIKey
            || new.agentModel != settings.agentModel
        settings = new
        client.applySettings(new)
        if needsRestart {
            shutdown()
            start()
        }
    }

    // MARK: - Dispatch

    /// Launch a background task. Non-blocking; the resulting pill is created from the
    /// sidecar's `queued` event. Speaks an error only if submission fails.
    func launch(kind: AgentTaskKind, detail: String, title: String? = nil, cwd: String? = nil) {
        guard isAvailable else {
            announce("I can't start background tasks right now — the agent service isn't running.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.submit(kind: kind, detail: detail, cwd: cwd, title: title)
            } catch {
                NSLog("[IRIS] agent submit failed: \(error)")
                self.announce("I couldn't start that background task.")
            }
        }
    }

    func cancel(_ id: String) {
        Task { [weak self] in await self?.client.cancel(id) }
    }

    /// Cancel a running task referenced by a spoken phrase ("cancel the deal search").
    /// Matches on title/detail; if exactly one task is active, cancels it. Returns the
    /// cancelled task's title, or nil if nothing matched.
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

    // MARK: - Event handling

    private func apply(_ event: SidecarTaskEvent) {
        guard let appState else { return }
        let finished = event.state.isFinished

        if let idx = appState.backgroundTasks.firstIndex(where: { $0.id == event.id }) {
            var t = appState.backgroundTasks[idx]
            t.kind = event.kind
            t.title = event.title
            if let d = event.detail { t.detail = d }
            t.state = event.state
            if let s = event.summary { t.resultSummary = s }
            if finished && t.finishedAt == nil { t.finishedAt = Date() }
            appState.backgroundTasks[idx] = t
        } else {
            appState.backgroundTasks.append(AgentTask(
                id: event.id, kind: event.kind, title: event.title,
                detail: event.detail ?? "", state: event.state,
                finishedAt: finished ? Date() : nil,
                resultSummary: event.summary))
        }

        if finished {
            announceIfNeeded(event)
            schedulePrune(event.id)
        }
    }

    private func announceIfNeeded(_ event: SidecarTaskEvent) {
        guard !announced.contains(event.id) else { return }
        announced.insert(event.id)
        switch event.state {
        case .succeeded:
            if let s = event.summary, !s.isEmpty { announce(s) }
        case .failed:
            announce(event.summary ?? "A background task failed.")
        default:
            break   // cancelled tasks are user-initiated; no announcement
        }
    }

    private func schedulePrune(_ id: String) {
        pruneTasks[id]?.cancel()
        pruneTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.pruneDelayNanos ?? 25_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.appState?.backgroundTasks.removeAll { $0.id == id }
            self.announced.remove(id)
            self.pruneTasks[id] = nil
        }
    }
}
