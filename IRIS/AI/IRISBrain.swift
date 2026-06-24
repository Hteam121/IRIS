//
//  IRISBrain.swift
//  IRIS — Vision + AI lane (Phase 1)
//
//  The `IRISResponder` implementation. Hybrid routing (plan.md / CLAUDE.md):
//   - "iris agent" in the transcript  → AgentMode (agentic task, spoken summary).
//   - ANTHROPIC_API_KEY set            → Anthropic Messages API (true base64 vision).
//   - otherwise                        → `claude -p` via stdin, screenshot as a PNG path.
//
//  plan.md fix #2: never put large content (base64) in argv. The CLI path writes the
//  prompt to a temp file and feeds it via stdin; the screenshot is referenced by path.
//

import Foundation

public final class IRISBrain: IRISResponder {
    private let settings: Settings
    private let urlSession: URLSession

    /// Spoken-output framing (docs/algorithms.md → AI routing → System framing).
    static let systemPrompt = """
    You are IRIS, a voice assistant on the user's Mac. You're in a spoken, back-and-forth \
    conversation, so talk like a real person — warm, natural, casual — not like a document or a \
    formal assistant. Keep every reply to ONE or TWO short sentences. Summarize: give the gist a \
    person would say out loud; never read lists, bullet points, or step-by-step items aloud, and \
    don't itemize — distill it. No markdown, bullets, numbered lists, code, emoji, or spoken-out \
    URLs. If the user asks for more detail, you can go a little longer, but stay conversational. \
    If a screenshot is provided, use it to answer about what's on their screen.
    """

    static let maxTokens = 512

    /// A one-line "you know the current time" context so the model never claims it can't access
    /// the clock and can answer time-relative questions. Computed per request (current time).
    static func nowContext() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return "For reference, the current local date and time is \(f.string(from: Date()))."
    }

    public init(settings: Settings) {
        self.settings = settings
        self.urlSession = .shared
    }

    // MARK: - IRISResponder

    /// Answer a foreground question. Routing happens upstream in AppDelegate; by the time we're
    /// here the command is a plain question to answer (optionally using the screenshot).
    public func ask(transcript: String, screenshotPath: String?) async -> String {
        await ask(transcript: transcript, screenshotPath: screenshotPath, history: [])
    }

    /// History-aware answer. `history` is recent (role, content) turns so IRIS holds a
    /// conversation (e.g. answering a follow-up after it asked a question). role ∈ user/assistant.
    public func ask(transcript: String, screenshotPath: String?,
                    history: [[String: String]]) async -> String {
        if let key = settings.anthropicAPIKey, !key.isEmpty {
            return await askAPI(transcript: transcript, screenshotPath: screenshotPath,
                                apiKey: key, history: history)
        }
        return await askCLI(transcript: transcript, screenshotPath: screenshotPath, history: history)
    }

    // MARK: - Anthropic Messages API (true vision)

    private func askAPI(transcript: String, screenshotPath: String?, apiKey: String,
                        history: [[String: String]]) async -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return Self.genericError
        }

        // Build the user content: optional image block first, then the text.
        var content: [[String: Any]] = []
        if let path = screenshotPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": data.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": transcript])

        // Prior turns (text-only) for conversational continuity, then the current message.
        var messages: [[String: Any]] = history.map {
            ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""]
        }
        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": settings.model,
            "max_tokens": Self.maxTokens,
            "system": Self.systemPrompt + "\n\n" + Self.nowContext(),
            "messages": messages,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return Self.genericError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return Self.networkError }
            guard (200..<300).contains(http.statusCode) else {
                return "The AI request failed with status \(http.statusCode)."
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = obj["content"] as? [[String: Any]] else {
                return Self.genericError
            }
            let text = blocks
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? Self.emptyReply : text
        } catch {
            return Self.networkError
        }
    }

    // MARK: - claude CLI (subscription, best-effort vision via file path)

    private func askCLI(transcript: String, screenshotPath: String?,
                        history: [[String: String]]) async -> String {
        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else {
            return "I can't reach Claude right now — the claude command wasn't found and no API key is set."
        }

        var prompt = Self.systemPrompt + "\n\n" + Self.nowContext() + "\n\n"
        if !history.isEmpty {
            prompt += "Conversation so far:\n"
            for turn in history {
                let who = (turn["role"] == "assistant") ? "IRIS" : "User"
                prompt += "\(who): \(turn["content"] ?? "")\n"
            }
            prompt += "\n"
        }
        if let path = screenshotPath {
            prompt += """
            A screenshot of the user's current screen has been saved to this PNG file. \
            Read that file to see what's on screen before answering:
            \(path)

            """
        }
        prompt += "User: \(transcript)\n"

        // Allow the Read tool only when there's a screenshot to inspect (best-effort
        // CLI vision; the API path is the true-vision route).
        var args = ["-p", "--model", settings.model]
        if screenshotPath != nil {
            args += ["--allowedTools", "Read"]
        }

        let result = await ClaudeProcessRunner.run(binary: binary, args: args, prompt: prompt)
        if result.ok, !result.output.isEmpty {
            return result.output
        }
        return result.output.isEmpty ? Self.cliError : result.output
    }

    // MARK: - Canned replies

    static let genericError = "Sorry, something went wrong while I was thinking."
    static let networkError = "I couldn't reach the network to answer that."
    static let emptyReply = "I didn't get a response that time. Try again?"
    static let cliError = "I had trouble running the Claude command just now."
}

// MARK: - Shared claude subprocess runner

/// Runs the `claude` CLI, feeding the prompt via a temp-file stdin rather than argv
/// (plan.md fix #2 — keeps large content out of `ARG_MAX`). Used by both `IRISBrain`'s
/// CLI path and `AgentMode`. stderr is discarded; only stdout (the reply) is returned.
enum ClaudeProcessRunner {
    /// Thread-safe holder for the running `Process` so a Task cancellation (barge-in) can
    /// terminate it. The continuation resumes normally once the terminated process's stdout
    /// hits EOF, so cancellation never leaks a continuation.
    private final class ProcessBox: @unchecked Sendable {
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
}
