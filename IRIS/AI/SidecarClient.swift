//
//  SidecarClient.swift
//  IRIS — Vision + AI lane
//
//  Client + supervisor for the Python LangGraph agent sidecar (sidecar/). IRIS spawns
//  the sidecar process (when `Settings.sidecarPython` is set), waits for /health, submits
//  background tasks over HTTP, and consumes the /events SSE stream of task state updates.
//
//  The sidecar runs each task as its own asyncio job, so multiple agents run in parallel
//  without blocking IRIS's foreground voice pipeline. See sidecar/README.md for the wire API.
//

import Foundation

/// One state update for a background task, decoded from the sidecar's SSE stream.
/// Mirrors `TaskEvent` in sidecar/iris_agents/models.py.
struct SidecarTaskEvent: Decodable, Sendable {
    let id: String
    let kind: AgentTaskKind
    let title: String
    let state: AgentTaskState
    let summary: String?
    let detail: String?
    let question: String?   // set when state == .waitingForUser (the agent's question)
}

@MainActor
final class SidecarClient {
    private var settings: Settings
    private var process: Process?
    private let session: URLSession

    init(settings: Settings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        // SSE: rely on the sidecar's 15s heartbeat to keep the request alive within the
        // default 60s inactivity window; allow the stream itself to run indefinitely.
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        self.session = URLSession(configuration: config)
    }

    func applySettings(_ new: Settings) { self.settings = new }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.sidecarPort)")! }

    enum SidecarError: Error { case badStatus, notReachable }

    // MARK: - Lifecycle

    /// Spawn the sidecar (if configured) and wait until /health responds. Returns whether
    /// the sidecar is reachable. Safe to call again; it won't double-spawn a live process.
    @discardableResult
    func start() async -> Bool {
        if await isHealthy() { return true }   // already running (e.g. launched manually)
        spawnIfPossible()
        for _ in 0..<40 {                       // poll up to ~20s
            if await isHealthy() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await isHealthy()
    }

    private func spawnIfPossible() {
        if let p = process, p.isRunning { return }
        guard let python = settings.sidecarPython, !python.isEmpty,
              FileManager.default.isExecutableFile(atPath: python) else {
            NSLog("[IRIS] sidecar: no usable sidecarPython; will only try to connect to a running instance")
            return
        }

        // venv layout: <sidecar>/.venv/bin/python → the sidecar dir is three levels up.
        let pythonURL = URL(fileURLWithPath: python)
        let sidecarDir = pythonURL
            .deletingLastPathComponent()   // bin
            .deletingLastPathComponent()   // .venv
            .deletingLastPathComponent()   // sidecar

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = ["-m", "iris_agents.server"]
        proc.currentDirectoryURL = sidecarDir

        var env = ProcessInfo.processInfo.environment
        env["IRIS_SIDECAR_HOST"] = "127.0.0.1"
        env["IRIS_SIDECAR_PORT"] = String(settings.sidecarPort)
        env["IRIS_MAX_AGENTS"] = String(settings.maxConcurrentAgents)
        if let key = settings.anthropicAPIKey, !key.isEmpty { env["ANTHROPIC_API_KEY"] = key }
        // Pass the OpenAI key too: with no Anthropic key, the agent runs on OpenAI (gpt-4o),
        // so background agents work with the key the user already has.
        if let key = settings.openAIAPIKey, !key.isEmpty { env["OPENAI_API_KEY"] = key }
        if let m = settings.agentModel, !m.isEmpty { env["IRIS_AGENT_MODEL"] = m }
        if !settings.claudeBinary.isEmpty { env["IRIS_CLAUDE_BINARY"] = settings.claudeBinary }
        proc.environment = env

        // Discard the sidecar's stdio; it logs to its own stderr which we don't need inline.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            process = proc
            NSLog("[IRIS] sidecar spawned: \(python) -m iris_agents.server (port \(settings.sidecarPort))")
        } catch {
            NSLog("[IRIS] sidecar spawn failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = obj["ok"] as? Bool {
                return ok
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Tasks

    private struct SubmitResponse: Decodable { let id: String }

    /// Submit a background task. Returns the sidecar task id (matches the SSE events' `id`).
    func submit(kind: AgentTaskKind, detail: String, cwd: String?, title: String?) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("tasks"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        var body: [String: Any] = ["kind": kind.rawValue, "detail": detail]
        if let cwd { body["cwd"] = cwd }
        if let title { body["title"] = title }
        if let m = settings.agentModel, !m.isEmpty { body["model"] = m }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SidecarError.badStatus
        }
        return try JSONDecoder().decode(SubmitResponse.self, from: data).id
    }

    func cancel(_ id: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("tasks/\(id)/cancel"))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        _ = try? await session.data(for: req)
    }

    /// Resume a paused (human-in-the-loop) task with the user's answer.
    func resume(_ id: String, answer: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("tasks/\(id)/resume"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["answer": answer])
        _ = try? await session.data(for: req)
    }

    // MARK: - Event stream (SSE)

    /// Stream task events, reconnecting with a short backoff until the stream is cancelled
    /// (e.g. when the consuming Task is cancelled at app shutdown).
    func events() -> AsyncStream<SidecarTaskEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                while !Task.isCancelled {
                    do {
                        try await self.streamOnce(into: continuation)
                    } catch {
                        // Sidecar not up yet or the connection dropped; retry after a pause.
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamOnce(into continuation: AsyncStream<SidecarTaskEvent>.Continuation) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("events"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SidecarError.badStatus
        }
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }   // ignore ": ping" heartbeats
            let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !json.isEmpty, let data = json.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(SidecarTaskEvent.self, from: data) {
                continuation.yield(event)
            }
        }
    }
}
