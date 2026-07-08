//
//  ClaudeEngine.swift
//  IRIS — the one answering brain (replaces IRISBrain + LocalRouter)
//
//  Clicky-style single streaming call per interaction, with a local-first ladder in front:
//   1. Free local model (Apple FM / Ollama) for simple text questions (escalation rules
//      ported from the OpenJarvis-style LocalRouter — see docs/algorithms.md → Local routing).
//   2. Anthropic Messages API (SSE streaming, prompt caching, true base64 vision) when a key
//      is set — the stable system prefix carries `cache_control` breakpoints and the
//      timestamp lives in the user turn so it can't invalidate the cache.
//   3. Otherwise `claude -p --output-format stream-json` (subscription, $0) via stdin,
//      screenshot as a PNG path + `--allowedTools Read` (plan.md fix #2).
//
//  Replies stream: each completed sentence is handed to `onSentence` (→ Speaker queue) so
//  speech starts ~a second into generation, and the accumulating text goes to `onCaption`
//  for the live overlay caption.
//

import Foundation

@MainActor
public final class ClaudeEngine: IRISResponder {
    private let settings: Settings
    private let urlSession: URLSession
    private let local: LocalBrain
    private weak var costGovernor: CostGovernor?

    static let maxTokens = 768
    /// Cheap model for side-calls (digests, memory extraction, long-result summaries).
    static let digestModel = "claude-haiku-4-5"

    // Local-first ladder constants (docs/algorithms.md → Local routing).
    static let maxWordsPremium = 30
    static let maxWordsSaver = 60
    static let maxHistoryTurns = 6
    static let maxLocalReplyChars = 600
    static let escalateToken = "ESCALATE"
    static let recencyCues = [
        "today", "tonight", "latest", "news", "price", "prices", "cost of",
        "who won", "stock", "weather", "right now", "currently", "this week",
        "yesterday", "tomorrow", "score",
    ]

    /// Current-events cues → give the model live web search (server tool on the API path,
    /// the CLI's native WebSearch otherwise) so "what's going on in the world" gets a real
    /// summary instead of an apology or a described-but-not-run search.
    static let webSearchCues = [
        "news", "headlines", "current events", "going on in the world", "happening in the world",
        "what's happening", "whats happening", "today", "latest", "right now", "this week",
        "stock", "price of", "weather", "score", "who won",
    ]

    static func needsWebSearch(_ transcript: String) -> Bool {
        let l = transcript.lowercased()
        return webSearchCues.contains { l.contains($0) }
    }

    /// Appended to the user turn when web search is enabled — rides with the question (not the
    /// system prefix) so the cacheable prefix stays byte-stable.
    static let webSearchHint = """
    (You can search the web. Do it briefly, then give a SHORT spoken summary of the main \
    points — two or three sentences, like a friend catching me up. No URLs, no lists, no \
    source names unless I ask.)
    """

    /// A one-line "you know the current time" context so the model never claims it can't access
    /// the clock. Computed per request and placed in the USER turn — never the system prefix,
    /// where it would invalidate the prompt cache on every call.
    static func nowContext() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return "For reference, the current local date and time is \(f.string(from: Date()))."
    }

    public init(settings: Settings, costGovernor: CostGovernor? = nil) {
        self.settings = settings
        self.costGovernor = costGovernor
        self.local = LocalBrain(settings: settings)
        self.urlSession = .shared
    }

    // MARK: - IRISResponder (contract continuity)

    public func ask(transcript: String, screenshotPath: String?) async -> String {
        await answer(transcript: transcript, screenshotPath: screenshotPath,
                     history: [], memory: "", onSentence: { _ in }, onCaption: { _ in })
    }

    // MARK: - The one answer call

    /// Answer a foreground question, streaming the reply. `onSentence` receives each completed
    /// speakable sentence (including one-shot local/error replies); `onCaption` receives the
    /// accumulating raw text for the live overlay. Returns the full final text (POINT tags
    /// included — the caller strips/renders them per sentence and for display).
    func answer(transcript: String, screenshotPath: String?,
                history: [[String: String]], memory: String,
                onSentence: @escaping (String) -> Void,
                onCaption: @escaping (String) -> Void) async -> String {
        let wantsWeb = screenshotPath == nil && Self.needsWebSearch(transcript)

        // 1) Free local model when enabled and the question is safely simple (never for
        //    current-events questions — a local model can only hallucinate those).
        if settings.localLLMEnabled,
           screenshotPath == nil, !wantsWeb,
           escalationReason(transcript: transcript, history: history) == nil,
           await local.isAvailable() {
            var system = Persona.spokenSystemPrompt + "\n\n" + Self.nowContext()
            if !memory.isEmpty { system += "\n\n" + memory }
            system += "\n\nIf you are not sure you can answer this correctly and completely on "
                + "your own, reply with exactly the single word \(Self.escalateToken) and nothing else."
            if let reply = await local.answer(system: system, transcript: transcript, history: history),
               !reply.contains(Self.escalateToken),
               reply.count <= Self.maxLocalReplyChars {
                IRISLog.log("engine: answered locally (\(reply.count) chars)")
                onCaption(reply)
                onSentence(reply)
                return reply
            }
            IRISLog.log("engine: local declined/failed → cloud")
        }

        // 2) Cloud, streaming. A web search adds a few silent seconds — acknowledge first.
        if wantsWeb { onSentence("Let me take a quick look.") }
        let reply: String
        if let key = settings.anthropicAPIKey, !key.isEmpty {
            reply = await streamAPI(transcript: transcript, screenshotPath: screenshotPath,
                                    apiKey: key, history: history, memory: memory,
                                    webSearch: wantsWeb,
                                    onSentence: onSentence, onCaption: onCaption)
        } else {
            reply = await streamCLI(transcript: transcript, screenshotPath: screenshotPath,
                                    history: history, memory: memory, webSearch: wantsWeb,
                                    onSentence: onSentence, onCaption: onCaption)
        }
        return reply
    }

    /// Why this question must go to the cloud, or nil when local is worth trying.
    private func escalationReason(transcript: String, history: [[String: String]]) -> String? {
        if history.count > Self.maxHistoryTurns { return "long history" }
        let saving = (costGovernor?.tier() ?? .premium) != .premium
        let cap = saving ? Self.maxWordsSaver : Self.maxWordsPremium
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        if words > cap { return "\(words) words > \(cap)" }
        let lower = transcript.lowercased()
        if let cue = Self.recencyCues.first(where: { lower.contains($0) }) {
            return "recency cue '\(cue)'"
        }
        return nil
    }

    // MARK: - System prefix (cached on the API path)

    /// Block 1: the frozen identity framing. Byte-stable across every request (the pointing
    /// hint is included unconditionally when pointing is on) so the cache prefix never moves.
    private var identityBlock: String {
        var block = Persona.spokenSystemPrompt
        if settings.pointerEnabled { block += "\n\n" + Persona.pointingHint }
        return block
    }

    // MARK: - Anthropic Messages API (SSE streaming + prompt caching)

    private func streamAPI(transcript: String, screenshotPath: String?, apiKey: String,
                           history: [[String: String]], memory: String,
                           webSearch: Bool = false,
                           onSentence: @escaping (String) -> Void,
                           onCaption: @escaping (String) -> Void) async -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return Self.genericError
        }

        // System prefix: two cacheable blocks. Block 1 (identity) never changes; block 2
        // (memory + skills catalog) only re-writes when the user teaches something new.
        var system: [[String: Any]] = [[
            "type": "text", "text": identityBlock,
            "cache_control": ["type": "ephemeral"],
        ]]
        if !memory.isEmpty {
            system.append([
                "type": "text", "text": memory,
                "cache_control": ["type": "ephemeral"],
            ])
        }

        // The volatile bits (timestamp) ride in the final user turn.
        var content: [[String: Any]] = []
        if let path = screenshotPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/png",
                           "data": data.base64EncodedString()],
            ])
        }
        var userText = Self.nowContext() + "\n\n" + transcript
        if webSearch { userText += "\n\n" + Self.webSearchHint }
        content.append(["type": "text", "text": userText])

        var messages: [[String: Any]] = history.map {
            ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""]
        }
        messages.append(["role": "user", "content": content])

        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": system,
            "messages": messages,
        ]
        if webSearch {
            // Anthropic's server-side web search tool: the API runs the searches itself and
            // streams the final text — no client-side tool loop needed.
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return Self.genericError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        var chunker = SentenceChunker()
        var full = ""
        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return Self.networkError }
            guard (200..<300).contains(http.statusCode) else {
                if webSearch {
                    // Web search may be unavailable on this org/model — degrade gracefully.
                    IRISLog.log("engine: web_search request failed (\(http.statusCode)) — retrying without")
                    return await streamAPI(transcript: transcript, screenshotPath: screenshotPath,
                                           apiKey: apiKey, history: history, memory: memory,
                                           webSearch: false,
                                           onSentence: onSentence, onCaption: onCaption)
                }
                return "The AI request failed with status \(http.statusCode)."
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: "),
                      let obj = try? JSONSerialization.jsonObject(
                        with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                switch type {
                case "message_start":
                    // Verify the cache is actually hitting (Sonnet needs a ≥2048-token prefix).
                    if let message = obj["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        let read = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
                        let write = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
                        let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
                        // A prefix under the model's cacheable minimum (~2048 tok on Sonnet) is a
                        // silent no-op — expected while memory/skills are small, not a bug.
                        let note = (read == 0 && write == 0 && input < 2048)
                            ? " (prefix below cache minimum — expected at this size)" : ""
                        IRISLog.log("engine: api usage in=\(input) cacheRead=\(read) cacheWrite=\(write)\(note)")
                        costGovernor?.recordAnthropic(model: settings.model, inputTokens: input,
                                                      cacheReadTokens: read, cacheWriteTokens: write,
                                                      outputTokens: 0)
                    }
                case "content_block_delta":
                    if let delta = obj["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        full += text
                        onCaption(full)
                        for sentence in chunker.append(text) { onSentence(sentence) }
                    }
                case "message_delta":
                    if let usage = obj["usage"] as? [String: Any] {
                        let out = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                        costGovernor?.recordAnthropic(model: settings.model, inputTokens: 0,
                                                      cacheReadTokens: 0, cacheWriteTokens: 0,
                                                      outputTokens: out)
                    }
                default:
                    break
                }
            }
        } catch is CancellationError {
            return full
        } catch {
            if full.isEmpty { return Self.networkError }
        }
        if let tail = chunker.flush() { onSentence(tail) }
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.emptyReply : trimmed
    }

    // MARK: - claude CLI (subscription, streaming via stream-json)

    private func streamCLI(transcript: String, screenshotPath: String?,
                           history: [[String: String]], memory: String,
                           webSearch: Bool = false,
                           onSentence: @escaping (String) -> Void,
                           onCaption: @escaping (String) -> Void) async -> String {
        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else {
            let msg = "I can't reach Claude right now — the claude command wasn't found and no API key is set."
            onSentence(msg)
            return msg
        }

        var prompt = identityBlock + "\n\n"
        if !memory.isEmpty { prompt += memory + "\n\n" }
        prompt += Self.nowContext() + "\n\n"
        if !history.isEmpty {
            prompt += "Conversation so far:\n"
            for turn in history {
                let who = (turn["role"] == "assistant") ? Persona.name : "User"
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
        if webSearch { prompt += "\n" + Self.webSearchHint + "\n" }

        var args = ["-p", "--model", settings.model,
                    "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages"]
        var allowedTools: [String] = []
        if screenshotPath != nil { allowedTools.append("Read") }
        if webSearch { allowedTools.append("WebSearch") }
        if !allowedTools.isEmpty {
            args += ["--allowedTools"] + allowedTools
        }

        // Streamed text assembly happens on the main actor; events arrive off it.
        final class StreamState {
            var chunker = SentenceChunker()
            var full = ""
            var sawDelta = false
        }
        let state = StreamState()

        let result = await ClaudeProcessRunner.stream(
            binary: binary, args: args, prompt: prompt
        ) { event in
            Task { @MainActor in
                switch event {
                case .textDelta(let text):
                    state.sawDelta = true
                    state.full += text
                    onCaption(state.full)
                    for s in state.chunker.append(text) { onSentence(s) }
                case .assistantText(let text):
                    // Older CLIs without partial messages deliver whole blocks; don't
                    // double-count when deltas already streamed this text.
                    guard !state.sawDelta else { return }
                    state.full += (state.full.isEmpty ? "" : " ") + text
                    onCaption(state.full)
                    for s in state.chunker.append(text + " ") { onSentence(s) }
                default:
                    break
                }
            }
        }

        // Hop back to the main actor to flush whatever the chunker still holds.
        let assembled: String = await MainActor.run {
            if let tail = state.chunker.flush() { onSentence(tail) }
            return state.full.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !assembled.isEmpty { return assembled }
        if result.ok, !result.text.isEmpty {
            onSentence(result.text)
            return result.text
        }
        let msg = result.text.isEmpty ? Self.cliError : result.text
        onSentence(msg)
        return msg
    }

    // MARK: - Side-calls (digests, memory extraction, vision JSON)

    /// One-shot cheap-model completion used by ContextDigest and long-result summaries.
    /// Returns nil on failure.
    func summarize(_ text: String, instruction: String) async -> String? {
        let user = instruction + "\n\n" + text
        let system = "You produce ONLY the requested summary text, nothing else. Plain prose."
        let raw: String
        if let key = settings.anthropicAPIKey, !key.isEmpty {
            raw = await rawAPICompletion(system: system, user: user, apiKey: key,
                                         model: Self.digestModel, maxTokens: 256)
        } else {
            raw = await rawCLICompletion(prompt: system + "\n\n" + user, model: Self.digestModel)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pull DURABLE user preferences / standing instructions / stable facts out of one exchange.
    /// Returns short third-person statements to store (or [] when nothing is worth keeping).
    public func extractMemories(userTurn: String, assistantTurn: String) async -> [String] {
        let task = """
        You maintain a long-term memory for a voice assistant. From the exchange below, extract \
        ONLY durable user preferences, standing instructions, or stable facts worth remembering \
        across sessions — NOT one-off requests, small talk, or anything time-bound. Return a JSON \
        array of short third-person strings, e.g. ["User prefers Chrome for web searches"]. If \
        nothing is worth keeping, return [].

        User: \(userTurn)
        \(Persona.name): \(assistantTurn)
        """
        let system = "You output ONLY a JSON array of strings, nothing else."
        let raw: String
        if let key = settings.anthropicAPIKey, !key.isEmpty {
            raw = await rawAPICompletion(system: system, user: task, apiKey: key,
                                         model: Self.digestModel, maxTokens: 256)
        } else {
            raw = await rawCLICompletion(prompt: system + "\n\n" + task, model: Self.digestModel)
        }
        return Self.parseJSONStringArray(raw)
    }

    /// One vision call that must return strict JSON (screen-rule matching). API path: true
    /// base64 vision; CLI path: PNG file path + the Read tool ($0). Returns the raw reply.
    func visionJSON(imagePath: String, instruction: String, maxTokens: Int) async -> String? {
        if let key = settings.anthropicAPIKey, !key.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
            guard costGovernor?.allowsPaidVision ?? true else { return nil }
            let raw = await rawAPICompletion(
                system: "You output ONLY strict JSON, nothing else.",
                user: instruction, apiKey: key, model: settings.model,
                maxTokens: maxTokens, imageData: data)
            return raw.isEmpty ? nil : raw
        }
        // Subscription path — free, so no budget gate.
        let prompt = """
        You output ONLY strict JSON, nothing else.

        A screenshot of the user's current screen has been saved to this PNG file. Read it first:
        \(imagePath)

        \(instruction)
        """
        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        let result = await ClaudeProcessRunner.run(
            binary: binary,
            args: ["-p", "--model", settings.model, "--allowedTools", "Read"],
            prompt: prompt)
        return result.ok && !result.output.isEmpty ? result.output : nil
    }

    /// Minimal non-streaming Messages API call (side-calls only).
    private func rawAPICompletion(system: String, user: String, apiKey: String,
                                  model: String, maxTokens: Int,
                                  imageData: Data? = nil) async -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return "" }
        var content: [[String: Any]] = []
        if let imageData {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/png",
                           "data": imageData.base64EncodedString()],
            ])
        }
        content.append(["type": "text", "text": user])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return "" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData
        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else { return "" }
        if let usage = obj["usage"] as? [String: Any] {
            costGovernor?.recordAnthropic(
                model: model,
                inputTokens: (usage["input_tokens"] as? NSNumber)?.intValue ?? 0,
                cacheReadTokens: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
                cacheWriteTokens: (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0,
                outputTokens: (usage["output_tokens"] as? NSNumber)?.intValue ?? 0)
        }
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    /// Minimal CLI completion (subscription path) for side-calls.
    private func rawCLICompletion(prompt: String, model: String) async -> String {
        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else { return "" }
        let result = await ClaudeProcessRunner.run(
            binary: binary, args: ["-p", "--model", model], prompt: prompt)
        return result.ok ? result.output : ""
    }

    /// Tolerantly parse a JSON array of strings out of a model reply (handles stray prose/fences).
    static func parseJSONStringArray(_ raw: String) -> [String] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              start < end else { return [] }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Canned replies

    static let genericError = "Sorry, something went wrong while I was thinking."
    static let networkError = "I couldn't reach the network to answer that."
    static let emptyReply = "I didn't get a response that time. Try again?"
    static let cliError = "I had trouble running the Claude command just now."
}

// MARK: - Sentence chunking (stream → Speaker queue)

/// Accumulates streamed text and emits complete sentences so TTS can start on the first one.
/// Boundary = sentence-ending punctuation followed by whitespace, after a minimum length
/// (docs/algorithms.md → Sentence chunking).
struct SentenceChunker {
    static let minChars = 40
    private var pending = ""

    /// Append a delta; returns any sentences completed by it.
    mutating func append(_ text: String) -> [String] {
        pending += text
        var out: [String] = []
        while let cut = nextBoundary() {
            let sentence = String(pending[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = String(pending[cut...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    /// The remaining tail (call once when the stream ends), or nil if empty.
    mutating func flush() -> String? {
        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return tail.isEmpty ? nil : tail
    }

    /// Index just past the first sentence boundary at/after `minChars`, or nil.
    private func nextBoundary() -> String.Index? {
        guard pending.count > Self.minChars else { return nil }
        var i = pending.index(pending.startIndex, offsetBy: Self.minChars)
        while i < pending.index(before: pending.endIndex) {
            let c = pending[i]
            let next = pending[pending.index(after: i)]
            if (c == "." || c == "!" || c == "?") && (next == " " || next == "\n") {
                return pending.index(after: i)
            }
            if c == "\n" { return pending.index(after: i) }
            i = pending.index(after: i)
        }
        return nil
    }
}
