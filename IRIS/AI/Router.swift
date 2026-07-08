//
//  Router.swift
//  IRIS — the one routing brain (replaces IntentRouter + its LLM classifiers)
//
//  Decides what to do with a spoken command — entirely deterministically, with zero
//  network and zero token spend. The old gpt-4o / claude -p classifiers are gone:
//  anything the heuristics don't catch falls through to `.answer`, where the streaming
//  ClaudeEngine handles it conversationally (exactly Clicky's UX). This "route before
//  the LLM" layer is also why the answer call carries no tool schemas — keeping the
//  prompt-cache prefix byte-stable.
//
//    • answer            → streaming Q&A (ClaudeEngine, with screen vision)      [foreground]
//    • openApp/openFolder/webSearch/terminal → native actions                    [foreground]
//    • backgroundAgent/calendar/skill        → agent work                        [background]
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
    case skill(String)                             // run an installed skill by (spoken) name
    case resumeSession(String)                     // continue the latest Claude session
}

struct Router {
    /// Spoken names of installed skills (from SkillManager), lowercased. When a command
    /// mentions one, it deterministically routes to `.skill` before anything else.
    var skillNames: [String] = []

    /// Trigger phrases that route a transcript to agent mode ("dory agent …").
    static let agentTriggers = [Persona.agentTrigger, Persona.legacyAgentTrigger]

    /// Phrases that resume the most recent Claude session with a new instruction.
    static let resumeCues = ["continue that task", "continue the task", "resume the session",
                             "resume that session", "continue the session", "keep going on that",
                             "keep working on that", "continue where you left off"]

    /// Classify `transcript` into an Intent. Deterministic and instant.
    func route(_ transcript: String) -> Intent {
        let lower = transcript.lowercased()

        // Fast path: the explicit agent phrase always wins.
        if Self.containsAgentTrigger(lower) {
            return .backgroundAgent(Self.extractAgentTask(from: transcript))
        }
        // Session continuity ("continue that task, and also fix the typo").
        if Self.resumeCues.contains(where: { lower.contains($0) }) {
            return .resumeSession(transcript)
        }
        if let intent = strongHeuristic(transcript) {
            return intent
        }

        // A bare open/launch verb → app launch; everything else is conversation.
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in ["open ", "launch ", "start "] where lower.hasPrefix(verb) {
            let rest = String(trimmed.dropFirst(verb.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return .openApp(stripAppNoun(rest)) }
        }
        return .answer
    }

    // MARK: - Agent trigger

    /// Whether the transcript contains any accepted agent trigger phrase.
    static func containsAgentTrigger(_ lowercasedTranscript: String) -> Bool {
        agentTriggers.contains { lowercasedTranscript.contains($0) }
    }

    /// Strip everything up to and including the trigger phrase, returning the task text.
    /// e.g. "Hey Dory, dory agent create a hello.txt file" → "create a hello.txt file".
    static func extractAgentTask(from transcript: String) -> String {
        let lower = transcript.lowercased()
        guard let range = agentTriggers.compactMap({ lower.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Map the lowercased upper-bound back onto the original string to preserve case.
        let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
        let start = transcript.index(transcript.startIndex, offsetBy: offset)
        var task = String(transcript[start...])
        // Drop a leading separator left over from "...agent, create..." / "agent: ...".
        task = task.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-"))
        return task.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Heuristics

    /// Deterministic routing for clear, common commands. Returns nil when the command is
    /// ambiguous (→ conversational answer).
    func strongHeuristic(_ transcript: String) -> Intent? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Installed skills by name ("run my morning briefing", "start focus mode") —
        // deterministic, checked first so a skill name can't be misrouted.
        for name in skillNames where !name.isEmpty && lower.contains(name) {
            return .skill(name)
        }

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

        // Real-world action requests ("create a file on my desktop", "delete the old notes
        // folder") → a Claude session that ACTUALLY does it. Without this they fall into
        // `.answer`, where the chat model can only claim it did something. Requires both an
        // action verb and a file-ish object so plain conversation ("make me laugh") stays chat.
        let actionVerbs = ["create ", "make ", "write ", "generate ", "add ", "delete ",
                           "remove ", "rename ", "move ", "copy ", "organize ", "organise ",
                           "clean up ", "install ", "download ", "save ", "build ", "edit ",
                           "update ", "put "]
        let actsOnFiles = ["file", "folder", "document", "doc", "note", "script", "text",
                           "readme", "spreadsheet", "csv", "json", "desktop", "downloads",
                           "documents", "project", "repo", "directory"]
        if actionVerbs.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0)") }),
           actsOnFiles.contains(where: { lower.contains($0) }) {
            return .backgroundAgent(trimmed)
        }

        // Web / background research the user wants done while continuing to talk.
        for kw in ["find deals", "deals on", "best price", "search the web", "browse the web",
                   "look online", "shop for", "in the background", "go find"] {
            if lower.contains(kw) { return .backgroundAgent(trimmed) }
        }

        return nil
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

    // MARK: - Folder resolution

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

    /// Resolve a folder argument — a real path, an "in X" phrase, or a bare name — to an
    /// existing directory, or nil. Checks the path as-is first, then phrase parsing, then a
    /// disk + Spotlight search by name (so "rerun" is found wherever it lives).
    func resolveFolderArgument(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return expanded   // a real path
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

    // MARK: - Search query extraction

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
}
