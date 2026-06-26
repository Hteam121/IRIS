//
//  IntentRouter.swift
//  IRIS — Vision + AI lane
//
//  Decides what to do with a spoken command. The router is consulted by AppDelegate
//  (Phase 2) so it can split FOREGROUND replies (which replace each other) from
//  BACKGROUND agent tasks (which run in parallel and never cancel one another):
//
//    • answer            → normal Q&A (Anthropic API / claude -p, with screen vision)   [foreground]
//    • openApp(name)     → AppLauncher (direct NSWorkspace launch)                        [foreground]
//    • backgroundAgent   → a long-running autonomous task (web deals, generic agent)      [background]
//    • calendar          → schedule something (Google Calendar via the sidecar's MCP)     [background]
//    • terminalClaude    → open Terminal + start a `claude` Code session                  [native]
//
//  When an OpenAI key is set, classification uses function-calling; otherwise (or on any
//  failure) it falls back to a deterministic keyword heuristic. The explicit "iris agent"
//  phrase is always a fast path to a background task.
//

import Foundation

enum Intent: Equatable {
    case openApp(String)
    case openFolder(String?)                       // open a folder in Finder; nil → default
    case webSearch(query: String, browser: String?) // open a browser to web results
    case answer
    case backgroundAgent(String)
    case calendar(String)
    case terminal(directory: String?, startClaude: Bool)  // open Terminal; optionally start claude
}

struct IntentRouter {
    let settings: Settings
    let urlSession: URLSession
    /// Meters/gates the paid OpenAI classifier. When set and the budget allows paid calls
    /// (`allowsPaidVision`), the fast gpt-4o classifier is preferred and its spend is recorded;
    /// once the budget is spent it's skipped so `.free` truly makes zero OpenAI calls. Defaults to
    /// nil so non-routing callers (folder resolution) are unaffected and never pay.
    var costGovernor: CostGovernor? = nil

    /// Classify `transcript` into an Intent.
    func route(_ transcript: String) async -> Intent {
        let lower = transcript.lowercased()

        // Fast path: the explicit agent phrase always wins (deterministic, no network).
        if lower.contains(AgentMode.trigger) {
            return .backgroundAgent(AgentMode.extractTask(from: transcript))
        }

        // High-confidence deterministic routing FIRST, so common commands are predictable and
        // the LLM classifier can't misroute them (e.g. "open my desktop files" → a terminal).
        if let intent = strongHeuristic(transcript) {
            return intent
        }

        // Only ambiguous commands reach the LLM classifier. When the budget allows paid calls and
        // an OpenAI key is set, prefer the FAST gpt-4o classifier (subscription `claude -p` adds a
        // multi-second subprocess + sonnet latency on the hot path); otherwise use the free
        // `claude -p` classifier. Fall back across both, then the deterministic keyword heuristic.
        let key = (settings.openAIAPIKey?.isEmpty == false) ? settings.openAIAPIKey : nil
        let paidOK = (await costGovernor?.allowsPaidVision) ?? true
        if paidOK, let key, let intent = await classifyWithOpenAI(transcript, key: key) {
            return intent
        }
        if let intent = await classifyWithClaude(transcript) {
            return intent
        }
        return heuristic(transcript)
    }

    // MARK: - Heuristics

    /// Deterministic routing for clear, common commands. Returns nil when the command is
    /// ambiguous (→ LLM classifier / answer).
    func strongHeuristic(_ transcript: String) -> Intent? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Terminal — optionally starting a Claude Code session. Plain "open a terminal" does
        // NOT start claude; only an explicit claude/claude-code mention does.
        let mentionsTerminal = lower.contains("terminal") || lower.contains("command line")
            || lower.contains("shell")
        let mentionsClaude = lower.contains("claude")
        if lower.contains("claude code") || (mentionsClaude && (mentionsTerminal || lower.contains("session") || lower.contains("start"))) {
            return .terminal(directory: parseDirectory(from: trimmed), startClaude: true)
        }
        if mentionsTerminal {
            return .terminal(directory: parseDirectory(from: trimmed), startClaude: false)
        }

        // Web search in a browser ("search for X", "google X", "open chrome and look up X").
        let mentionsBrowser = ["chrome", "safari", "firefox", "browser", "edge", "brave", "arc"]
            .contains { lower.contains($0) }
        let wantsSearch = lower.hasPrefix("search ") || lower.hasPrefix("google ")
            || lower.hasPrefix("look up ") || lower.contains("search for")
            || lower.contains("search the web") || lower.contains("in search of")
            || (mentionsBrowser && (lower.contains("search") || lower.contains("look up")))
        if wantsSearch {
            let q = extractSearchQuery(trimmed)
            if !q.isEmpty {
                return .webSearch(query: q, browser: mentionsBrowser ? namedBrowser(lower) : nil)
            }
        }

        // Open a folder / files in Finder (NOT a terminal). "open my files on the desktop",
        // "show me my documents", "open up the downloads folder".
        let opensVerb = ["open ", "show ", "show me ", "pull up ", "bring up ", "go to "]
            .contains { lower.hasPrefix($0) } || lower.contains("open up")
        let folderish = lower.contains("folder") || lower.contains("my files")
            || lower.contains("finder") || lower.contains("desktop")
            || lower.contains("documents") || lower.contains("downloads")
        if opensVerb && folderish {
            return .openFolder(parseDirectory(from: trimmed))
        }

        // Calendar scheduling.
        for kw in ["schedule", "appointment", "add to my calendar", "on my calendar",
                   "set up a meeting", "book a", "book an", "create an event", "create a meeting"] {
            if lower.contains(kw) { return .calendar(trimmed) }
        }

        // Web / background research the user wants done while continuing to talk.
        for kw in ["find deals", "deals on", "best price", "search the web", "browse the web",
                   "look online", "shop for", "in the background", "go find"] {
            if lower.contains(kw) { return .backgroundAgent(trimmed) }
        }

        return nil
    }

    /// Fallback when the LLM classifier is unavailable/failed: open an app, else just answer.
    func heuristic(_ transcript: String) -> Intent {
        if let intent = strongHeuristic(transcript) { return intent }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for verb in ["open ", "launch ", "start "] where lower.hasPrefix(verb) {
            let rest = String(trimmed.dropFirst(verb.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return .openApp(stripAppNoun(rest)) }
        }
        return .answer
    }

    /// Drop a trailing " app"/" application" so "open the safari app" → "safari".
    private func stripAppNoun(_ s: String) -> String {
        var name = s
        for article in ["the ", "my "] where name.lowercased().hasPrefix(article) {
            name = String(name.dropFirst(article.count))
        }
        for suffix in [" app", " application"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort directory extraction from a spoken command for terminal/agent tasks.
    /// Returns nil when nothing is recognized (caller falls back to its default dir).
    func parseDirectory(from transcript: String) -> String? {
        // An explicit path token wins ("in ~/code", "/Users/...").
        for token in transcript.split(separator: " ") {
            let t = String(token)
            if t.hasPrefix("~") || t.hasPrefix("/") {
                return (t as NSString).expandingTildeInPath
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lower = transcript.lowercased()

        // A named folder the user mentioned ("in my projects folder", "in the iris repo") —
        // search common locations on disk so we open the RIGHT directory, not just home.
        if let name = folderNameMention(lower), let path = findFolderOnDisk(named: name) {
            return path
        }

        // Common shortcuts.
        if lower.contains("iris") { return home + "/Desktop/IRIS" }
        if lower.contains("desktop") { return home + "/Desktop" }
        if lower.contains("documents") { return home + "/Documents" }
        if lower.contains("downloads") { return home + "/Downloads" }
        if lower.contains("projects") { return home + "/Projects" }
        return nil
    }

    /// Pull the folder name the user mentioned after "in"/"into"/"inside", stripping articles
    /// and trailing filler ("folder", "directory", "and then…").
    private func folderNameMention(_ lower: String) -> String? {
        let markers = [" inside the ", " in the ", " into the ", " in my ", " inside ", " into ", " in "]
        var rest: String?
        for m in markers {
            if let r = lower.range(of: m, options: .backwards) {
                rest = String(lower[r.upperBound...]); break
            }
        }
        guard var s = rest else { return nil }
        for stop in [" folder", " directory", " repo", " and ", " then ", " please", ".", ","] {
            if let r = s.range(of: stop) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for a in ["the ", "my ", "a "] where s.hasPrefix(a) { s = String(s.dropFirst(a.count)) }
        return s.isEmpty ? nil : s
    }

    /// Find a directory named ~`name` under common parent folders (case-insensitive, then fuzzy).
    private func findFolderOnDisk(named name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let parents = [home, "\(home)/Desktop", "\(home)/Documents", "\(home)/Projects",
                       "\(home)/Developer", "\(home)/Downloads", "\(home)/Code"]
        let target = name.lowercased()

        func dirPath(_ parent: String, _ item: String) -> String? {
            var isDir: ObjCBool = false
            let p = "\(parent)/\(item)"
            return (fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue) ? p : nil
        }
        for parent in parents {
            guard let items = try? fm.contentsOfDirectory(atPath: parent) else { continue }
            if let exact = items.first(where: { $0.lowercased() == target }),
               let p = dirPath(parent, exact) { return p }
            if let partial = items.first(where: {
                let l = $0.lowercased()
                return l.contains(target) || target.contains(l)
            }), let p = dirPath(parent, partial) { return p }
        }
        // Not in the common parents — search the whole Mac via Spotlight (finds nested folders).
        return spotlightFolder(named: name)
    }

    /// Find a folder by name anywhere on the Mac using Spotlight (mdfind). Prefers matches under
    /// the home folder and shallower paths; skips system/Library/caches noise.
    private func spotlightFolder(named name: String) -> String? {
        let escaped = name.replacingOccurrences(of: "'", with: "")
        // Exact name first, then a contains-wildcard fallback.
        let queries = [
            "kMDItemContentTypeTree == 'public.folder' && kMDItemFSName == '\(escaped)'c",
            "kMDItemContentTypeTree == 'public.folder' && kMDItemFSName == '*\(escaped)*'c",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for query in queries {
            let results = runMdfind(query)
            let dirs = results.filter { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
                let l = path.lowercased()
                return !(l.contains("/library/") || l.hasPrefix("/system") || l.hasPrefix("/private/")
                    || l.contains("/node_modules/") || l.contains("/.trash/") || l.contains("/.git/")
                    || l.contains("/caches/"))
            }
            let best = dirs.sorted { a, b in
                let ah = a.hasPrefix(home), bh = b.hasPrefix(home)
                if ah != bh { return ah }
                return a.components(separatedBy: "/").count < b.components(separatedBy: "/").count
            }.first
            if let best { return best }
        }
        return nil
    }

    private func runMdfind(_ query: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = [query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").map(String.init)
    }

    /// Resolve a folder argument from the model — a real path, an "in X" phrase, or a bare name —
    /// to an existing directory, or nil. Checks the path as-is first, then phrase parsing, then a
    /// disk + Spotlight search by name (so "rerun" is found wherever it lives).
    func resolveFolderArgument(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return expanded   // a real path the model gave us
        }
        if let viaPhrase = parseDirectory(from: trimmed) { return viaPhrase }
        return findFolderOnDisk(named: trimmed)   // bare name → disk + Spotlight
    }

    /// The folder name the user spoke (for messaging when we can't resolve it), or nil.
    func spokenDirectoryName(_ transcript: String) -> String? {
        let lower = transcript.lowercased()
        if let n = folderNameMention(lower) { return n }
        for k in ["desktop", "documents", "downloads", "projects"] where lower.contains(k) { return k }
        return nil
    }

    /// Pull the search query out of a "search for X" / "google X" / "open chrome and search X" command.
    private func extractSearchQuery(_ transcript: String) -> String {
        var s = transcript
        let lower = s.lowercased()
        let markers = ["search the web for ", "search for ", "in search of ", "look up ",
                       "google ", "search "]
        for m in markers {
            if let r = lower.range(of: m) {
                let start = s.index(s.startIndex,
                                    offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))
                s = String(s[start...])
                break
            }
        }
        var q = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lq = q.lowercased()
        for tail in [" in chrome", " on chrome", " in safari", " on safari", " in my browser",
                     " in the browser", " please"] {
            if let r = lq.range(of: tail) {
                let cut = q.index(q.startIndex, offsetBy: lq.distance(from: lq.startIndex, to: r.lowerBound))
                q = String(q[..<cut])
                break
            }
        }
        return q.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?").union(.whitespacesAndNewlines))
    }

    /// The browser the user named, normalized ("google chrome" → "chrome"), or nil.
    private func namedBrowser(_ lower: String) -> String? {
        for b in ["google chrome", "chrome", "safari", "firefox", "edge", "brave", "arc"]
        where lower.contains(b) {
            return b == "google chrome" ? "chrome" : b
        }
        return nil
    }

    // MARK: - claude -p classifier (free, preferred)

    /// Classify an ambiguous command with `claude -p` (free via the Claude Code subscription).
    /// Returns nil (→ OpenAI/heuristic fallback) when claude is unavailable or the output can't be
    /// parsed. Most commands never reach here — `strongHeuristic` catches the common ones first.
    private func classifyWithClaude(_ transcript: String) async -> Intent? {
        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else { return nil }

        let prompt = """
        You route a Mac voice assistant's spoken commands. Reply with ONLY a compact one-line JSON \
        object — no prose, no code fence. Choose exactly one action:
        {"action":"open_app","arg":"<application name>"}
        {"action":"open_folder","arg":"<folder name, or empty for home>"}
        {"action":"web_search","arg":"<search query>","browser":"<chrome|safari|firefox or empty>"}
        {"action":"open_terminal","arg":"<folder or empty>","claude":<true|false>}
        {"action":"background_task","arg":"<the task>"}
        {"action":"calendar","arg":"<event details>"}
        {"action":"answer"}
        Use "answer" for questions or conversation. Use "open_terminal" with claude=true only if the \
        user explicitly wants a Claude / Claude Code session.
        Command: \(transcript)
        """
        let result = await ClaudeProcessRunner.run(
            binary: binary, args: ["-p", "--model", settings.model], prompt: prompt)
        guard result.ok else { return nil }
        return parseClaudeIntent(result.output, originalTranscript: transcript)
    }

    /// Extract the JSON object from claude's output (tolerant of surrounding prose) and map it.
    private func parseClaudeIntent(_ output: String, originalTranscript: String) -> Intent? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"), start < end else { return nil }
        let json = String(output[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = (obj["action"] as? String)?.lowercased() else { return nil }

        func str(_ k: String) -> String? {
            (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch action {
        case "open_app":
            if let app = str("arg"), !app.isEmpty { return .openApp(app) }
            return .answer
        case "open_folder":
            let folder = str("arg")
            return .openFolder((folder?.isEmpty == false)
                ? (parseDirectory(from: folder!) ?? folder) : parseDirectory(from: originalTranscript))
        case "web_search":
            let q = str("arg") ?? ""
            let browser = str("browser").flatMap { $0.isEmpty ? nil : $0 }
            return q.isEmpty ? .answer : .webSearch(query: q, browser: browser)
        case "open_terminal":
            let dir = str("arg")
            let resolved = (dir?.isEmpty == false)
                ? (parseDirectory(from: dir!) ?? dir) : parseDirectory(from: originalTranscript)
            let startClaude = (obj["claude"] as? Bool)
                ?? originalTranscript.lowercased().contains("claude")
            return .terminal(directory: resolved, startClaude: startClaude)
        case "background_task":
            let t = str("arg")
            return .backgroundAgent((t?.isEmpty == false) ? t! : originalTranscript)
        case "calendar":
            let d = str("arg")
            return .calendar((d?.isEmpty == false) ? d! : originalTranscript)
        case "answer":
            return .answer
        default:
            return nil
        }
    }

    // MARK: - OpenAI function-calling classifier

    private func classifyWithOpenAI(_ transcript: String, key: String) async -> Intent? {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            return nil
        }

        func fn(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "function": [
                "name": name, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": required],
            ]]
        }

        let tools: [[String: Any]] = [
            fn("open_app", "Open or activate a macOS application by name (e.g. Safari, Spotify).",
               ["app_name": ["type": "string", "description": "The application name, e.g. Safari."]],
               ["app_name"]),
            fn("open_folder",
               "Open a folder / the user's files in Finder (e.g. 'open my desktop files', 'show my documents'). Use this for opening files or folders — do NOT use the terminal for that.",
               ["folder": ["type": "string", "description": "Folder path or spoken name (desktop, documents, downloads, a folder name); omit for home."]],
               []),
            fn("background_task",
               "Run a long-running autonomous task in the background while the user keeps talking — e.g. browse the web for deals/prices, research something, or a multi-step task.",
               ["task": ["type": "string", "description": "The task to perform."]],
               ["task"]),
            fn("schedule_event",
               "Schedule an appointment or event on the user's Google calendar.",
               ["description": ["type": "string", "description": "Natural-language event details (what, when)."]],
               ["description"]),
            fn("web_search",
               "Open a web search in the browser (e.g. 'search for X', 'open Chrome and look up X'). Use this to actually perform a search, not just open the browser app.",
               ["query": ["type": "string", "description": "What to search for."],
                "browser": ["type": "string", "description": "Browser name if specified (chrome, safari, firefox); omit for default."]],
               ["query"]),
            fn("open_terminal",
               "Open a Terminal window. Set start_claude=true ONLY if the user explicitly wants to start a Claude / Claude Code session; false for a plain terminal. Never for opening files.",
               ["directory": ["type": "string", "description": "Directory path or spoken folder name; omit for default."],
                "start_claude": ["type": "boolean", "description": "Whether to start a claude session."]],
               []),
            fn("answer",
               "Answer a question or have a conversation, optionally using what's on the user's screen.",
               [:], []),
        ]

        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0,
            "messages": [
                ["role": "system",
                 "content": "You route a Mac voice assistant's spoken commands. Call exactly one function. Use open_folder to open files/folders in Finder (desktop, documents, a folder). Use web_search to actually search the web in a browser ('open chrome and search X', 'google X'). Use open_app to just launch an application. Use open_terminal for a terminal (start_claude=true only if they explicitly want a claude session) — never for opening files. Use background_task for background research/multi-step tasks. Use schedule_event for calendar appointments. Otherwise use answer."],
                ["role": "user", "content": transcript],
            ],
            "tools": tools,
            "tool_choice": "required",
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 12

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            // Meter this paid classifier call against the monthly budget.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await costGovernor?.recordVision(usage: obj["usage"] as? [String: Any])
            }
            return parseToolCall(data, originalTranscript: transcript)
        } catch {
            return nil
        }
    }

    /// Pull the first tool call out of an OpenAI chat-completions response and map it.
    private func parseToolCall(_ data: Data, originalTranscript: String) -> Intent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              let function = toolCalls.first?["function"] as? [String: Any],
              let name = function["name"] as? String else {
            return nil
        }

        // arguments is a JSON-encoded string.
        let argsString = function["arguments"] as? String ?? "{}"
        let args = (argsString.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        func str(_ key: String) -> String? {
            (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch name {
        case "open_app":
            if let app = str("app_name"), !app.isEmpty { return .openApp(app) }
            return .answer
        case "open_folder":
            let folder = str("folder")
            return .openFolder((folder?.isEmpty == false) ? parseDirectory(from: folder!) ?? folder : parseDirectory(from: originalTranscript))
        case "background_task":
            let task = str("task")
            return .backgroundAgent((task?.isEmpty == false) ? task! : originalTranscript)
        case "schedule_event":
            let desc = str("description")
            return .calendar((desc?.isEmpty == false) ? desc! : originalTranscript)
        case "web_search":
            let query = str("query") ?? extractSearchQuery(originalTranscript)
            let browser = str("browser") ?? namedBrowser(originalTranscript.lowercased())
            return query.isEmpty ? .answer : .webSearch(query: query, browser: browser)
        case "open_terminal":
            let dir = str("directory")
            let resolved = (dir?.isEmpty == false) ? (parseDirectory(from: dir!) ?? dir) : parseDirectory(from: originalTranscript)
            let startClaude = (args["start_claude"] as? Bool) ?? originalTranscript.lowercased().contains("claude")
            return .terminal(directory: resolved, startClaude: startClaude)
        default:
            return .answer
        }
    }
}
