//
//  StreamJSON.swift
//  IRIS — claude CLI subprocess plumbing
//
//  Two things live here:
//   1. `ClaudeStreamEvent` + `StreamJSONParser` — a tolerant parser for the CLI's
//      `--output-format stream-json` line-delimited JSON (one event per line). Unknown
//      event types are ignored so CLI upgrades can't crash the app; we key only on
//      `type`, `session_id`, and `result` (verified against claude_code_version 2.1.x).
//   2. `ClaudeProcessRunner` — spawns the CLI feeding the prompt via temp-file stdin
//      rather than argv (plan.md fix #2). `run` is the one-shot form (digests, memory
//      extraction); `stream` delivers parsed events live for spoken/streamed replies.
//

import Foundation

/// One parsed event from a `claude -p --output-format stream-json` run.
enum ClaudeStreamEvent {
    /// `system/init`: the session exists; carries the resumable session id.
    case initialized(sessionId: String)
    /// A completed assistant text block (arrives sentence-to-paragraph sized).
    case assistantText(String)
    /// A raw streaming text delta (`stream_event` with `--include-partial-messages`).
    case textDelta(String)
    /// The assistant invoked a tool (agent sessions): name + a short human summary of the input.
    case toolUse(name: String, detail: String)
    /// Terminal event: success flag, final result text, session id, total cost in USD.
    case result(ok: Bool, text: String, sessionId: String?, costUSD: Double?)
}

/// Incremental line-buffer parser for stream-json output. Feed it raw stdout chunks;
/// it emits parsed events. Not thread-safe — confine to one queue/actor.
struct StreamJSONParser {
    private var buffer = Data()

    /// Append a chunk of stdout and return the events completed by it.
    mutating func consume(_ chunk: Data) -> [ClaudeStreamEvent] {
        buffer.append(chunk)
        var events: [ClaudeStreamEvent] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let event = Self.parse(line: line) { events.append(event) }
        }
        return events
    }

    /// Parse any final unterminated line (call once at EOF).
    mutating func finish() -> [ClaudeStreamEvent] {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let event = Self.parse(line: buffer) else { return [] }
        return [event]
    }

    private static func parse(line: Data) -> ClaudeStreamEvent? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        switch type {
        case "system":
            guard obj["subtype"] as? String == "init",
                  let id = obj["session_id"] as? String else { return nil }
            return .initialized(sessionId: id)

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            // One CLI event usually carries one block; handle the first meaningful one.
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        return .assistantText(text)
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    return .toolUse(name: name, detail: toolDetail(
                        name: name, input: block["input"] as? [String: Any] ?? [:]))
                default:
                    continue   // thinking, etc.
                }
            }
            return nil

        case "stream_event":
            // `--include-partial-messages`: raw Anthropic stream events wrapped by the CLI.
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            return .textDelta(text)

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success")
            return .result(
                ok: !isError,
                text: (obj["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                sessionId: obj["session_id"] as? String,
                costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue)

        default:
            return nil
        }
    }

    /// A short human-readable summary of a tool call for pill subtitles / narration
    /// ("Editing AppDelegate.swift", "Running xcodebuild …").
    private static func toolDetail(name: String, input: [String: Any]) -> String {
        func base(_ key: String) -> String? {
            guard let v = input[key] as? String, !v.isEmpty else { return nil }
            return (v as NSString).lastPathComponent
        }
        switch name {
        case "Edit", "Write", "NotebookEdit":
            return base("file_path").map { "Editing \($0)" } ?? "Editing a file"
        case "Read":
            return base("file_path").map { "Reading \($0)" } ?? "Reading a file"
        case "Bash":
            if let cmd = input["command"] as? String {
                let short = cmd.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
                return "Running \(short)"
            }
            return "Running a command"
        case "Grep", "Glob":
            return "Searching the code"
        case "WebSearch", "WebFetch":
            return "Searching the web"
        case "Task", "Agent":
            return "Delegating a subtask"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Planning steps"
        default:
            return "Using \(name)"
        }
    }
}

// MARK: - Shared claude subprocess runner

/// Runs the `claude` CLI, feeding the prompt via a temp-file stdin rather than argv
/// (plan.md fix #2 — keeps large content out of `ARG_MAX`).
enum ClaudeProcessRunner {
    /// Thread-safe holder for the running `Process` so a Task cancellation (barge-in) can
    /// terminate it. The continuation resumes normally once the terminated process's stdout
    /// hits EOF, so cancellation never leaks a continuation.
    final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var terminated = false

        func set(_ p: Process) {
            lock.lock(); defer { lock.unlock() }
            // If cancellation already arrived, terminate immediately.
            if terminated { p.terminate() } else { process = p }
        }
        func terminate() {
            lock.lock(); defer { lock.unlock() }
            terminated = true
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    /// One-shot run: returns (exit ok, full trimmed stdout). stderr is discarded.
    static func run(binary: String, args: [String], prompt: String) async -> (ok: Bool, output: String) {
        let promptURL = URL(fileURLWithPath: NSTemporaryDirectory() + "iris-prompt-\(UUID().uuidString).txt")
        guard (try? prompt.write(to: promptURL, atomically: true, encoding: .utf8)) != nil else {
            return (false, "")
        }
        defer { try? FileManager.default.removeItem(at: promptURL) }

        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(ok: Bool, output: String), Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let inHandle = try? FileHandle(forReadingFrom: promptURL) else {
                        continuation.resume(returning: (false, ""))
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args
                    process.standardInput = inHandle

                    let outPipe = Pipe()
                    process.standardOutput = outPipe
                    // Discard stderr to avoid a full-buffer deadlock while we drain stdout.
                    process.standardError = FileHandle.nullDevice

                    box.set(process)   // expose for cancellation (terminate-on-barge-in)

                    do {
                        try process.run()
                    } catch {
                        try? inHandle.close()
                        continuation.resume(returning: (false, ""))
                        return
                    }

                    // Read stdout to EOF (process closes it on exit or termination), then reap.
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    try? inHandle.close()

                    let out = String(data: outData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (process.terminationStatus == 0, out))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Streaming run: parses stream-json stdout and delivers each event via `onEvent`
    /// (called on an arbitrary queue — hop to the main actor in the handler). Returns the
    /// final `.result` event's fields once the process exits. `cwd` sets the working
    /// directory; `stderrURL` captures stderr for debugging (nil discards it).
    @discardableResult
    static func stream(
        binary: String, args: [String], prompt: String,
        cwd: String? = nil, stderrURL: URL? = nil,
        onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void
    ) async -> (ok: Bool, text: String, sessionId: String?, costUSD: Double?) {
        let promptURL = URL(fileURLWithPath: NSTemporaryDirectory() + "iris-prompt-\(UUID().uuidString).txt")
        guard (try? prompt.write(to: promptURL, atomically: true, encoding: .utf8)) != nil else {
            return (false, "", nil, nil)
        }
        defer { try? FileManager.default.removeItem(at: promptURL) }

        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<
                (ok: Bool, text: String, sessionId: String?, costUSD: Double?), Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let inHandle = try? FileHandle(forReadingFrom: promptURL) else {
                        continuation.resume(returning: (false, "", nil, nil))
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args
                    process.standardInput = inHandle
                    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

                    let outPipe = Pipe()
                    process.standardOutput = outPipe
                    if let stderrURL {
                        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                        process.standardError = (try? FileHandle(forWritingTo: stderrURL))
                            ?? FileHandle.nullDevice
                    } else {
                        process.standardError = FileHandle.nullDevice
                    }

                    box.set(process)

                    do {
                        try process.run()
                    } catch {
                        try? inHandle.close()
                        continuation.resume(returning: (false, "", nil, nil))
                        return
                    }

                    // Drain stdout incrementally, parsing line-delimited JSON as it arrives.
                    var parser = StreamJSONParser()
                    var final: (ok: Bool, text: String, sessionId: String?, costUSD: Double?)?
                    var sessionId: String?
                    let handle = outPipe.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }   // EOF
                        for event in parser.consume(chunk) {
                            if case .initialized(let id) = event { sessionId = id }
                            if case .result(let ok, let text, let sid, let cost) = event {
                                final = (ok, text, sid ?? sessionId, cost)
                            }
                            onEvent(event)
                        }
                    }
                    for event in parser.finish() {
                        if case .result(let ok, let text, let sid, let cost) = event {
                            final = (ok, text, sid ?? sessionId, cost)
                        }
                        onEvent(event)
                    }
                    process.waitUntilExit()
                    try? inHandle.close()

                    continuation.resume(returning: final
                        ?? (process.terminationStatus == 0, "", sessionId, nil))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}
