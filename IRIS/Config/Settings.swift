//
//  Settings.swift
//  IRIS — configuration (Phase 0)
//
//  Loads runtime config from (in increasing priority): process environment,
//  a `.env` file, then `~/.iris/config.json`. Also resolves the `claude` binary,
//  which is NOT on a GUI-launched app's PATH (plan.md fix #1).
//
//  Frozen at the Phase 0 barrier — Phase 1 lanes read `Settings` but don't edit it.
//

import Foundation

public struct Settings: Sendable {
    /// Absolute path to the resolved `claude` CLI binary (best-effort; may be empty
    /// if not found, in which case the API path must be used).
    public var claudeBinary: String

    /// Anthropic API key. When present, `IRISBrain` uses the Messages API with real
    /// base64 vision instead of `claude -p`.
    public var anthropicAPIKey: String?

    /// Model id. Default `claude-sonnet-4-6`; `claude-haiku-4-5-20251001` for speed.
    public var model: String

    /// TTS voice language (BCP-47), e.g. `en-US`.
    public var voice: String

    /// Optional explicit AVSpeechSynthesisVoice identifier (e.g. a downloaded premium/Siri
    /// voice). When set it overrides the language-based auto-selection. Env `IRIS_VOICE_ID`.
    public var voiceIdentifier: String?

    /// AVSpeechSynthesizer rate (see docs/algorithms.md → TTS).
    public var ttsRate: Float

    /// Case-insensitive wake phrase, lowercased (see docs/algorithms.md → wake word).
    public var wakePhrase: String

    // MARK: - Defaults

    public static let defaultModel = "claude-sonnet-4-6"
    public static let defaultVoice = "en-US"
    public static let defaultTTSRate: Float = 0.52
    public static let defaultWakePhrase = "hey iris"

    public init(
        claudeBinary: String,
        anthropicAPIKey: String?,
        model: String,
        voice: String,
        voiceIdentifier: String?,
        ttsRate: Float,
        wakePhrase: String
    ) {
        self.claudeBinary = claudeBinary
        self.anthropicAPIKey = anthropicAPIKey
        self.model = model
        self.voice = voice
        self.voiceIdentifier = voiceIdentifier
        self.ttsRate = ttsRate
        self.wakePhrase = wakePhrase
    }

    // MARK: - Loading

    /// Build a `Settings` by merging process environment, `.env`, and `~/.iris/config.json`.
    public static func load() -> Settings {
        let env = mergedEnvironment()
        let json = loadConfigJSON()

        func value(_ jsonKey: String, _ envKey: String) -> String? {
            if let v = json[jsonKey]?.stringValue, !v.isEmpty { return v }
            if let v = env[envKey], !v.isEmpty { return v }
            return nil
        }

        let apiKey = value("anthropicAPIKey", "ANTHROPIC_API_KEY")

        let model = value("model", "IRIS_MODEL") ?? defaultModel
        let voice = value("voice", "IRIS_VOICE") ?? defaultVoice
        // Optional explicit AVSpeechSynthesisVoice identifier (e.g. a downloaded Siri voice).
        let voiceIdentifier = value("voiceIdentifier", "IRIS_VOICE_ID")
        let wakePhrase = (value("wakePhrase", "IRIS_WAKE_PHRASE") ?? defaultWakePhrase)
            .lowercased()

        let ttsRate: Float = {
            if let s = value("ttsRate", "IRIS_TTS_RATE"), let f = Float(s) { return f }
            return defaultTTSRate
        }()

        // Allow an explicit override, else probe the filesystem for `claude`.
        let claudeBinary = value("claudeBinary", "IRIS_CLAUDE_BINARY")
            ?? resolveClaudeBinary()

        return Settings(
            claudeBinary: claudeBinary,
            anthropicAPIKey: apiKey,
            model: model,
            voice: voice,
            voiceIdentifier: voiceIdentifier,
            ttsRate: ttsRate,
            wakePhrase: wakePhrase
        )
    }

    // MARK: - claude binary resolution (plan.md fix #1)

    private static let claudeCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedClaudeBinary: String?

    /// Resolve the `claude` CLI path. A Finder/Xcode-launched app has a minimal PATH,
    /// so bare `claude` won't be found. Probe known install dirs, then fall back to a
    /// login shell. Result is cached for the process lifetime.
    public static func resolveClaudeBinary() -> String {
        claudeCacheLock.lock()
        defer { claudeCacheLock.unlock() }
        if let cached = cachedClaudeBinary { return cached }

        let resolved = probeClaudeBinary()
        cachedClaudeBinary = resolved
        return resolved
    }

    private static func probeClaudeBinary() -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }

        // Last resort: ask a login shell where `claude` lives (picks up the user's PATH).
        if let viaShell = whichViaLoginShell("claude") {
            return viaShell
        }
        return ""
    }

    /// Run `/bin/zsh -lic 'which <tool>'` and return the trimmed first line, or nil.
    private static func whichViaLoginShell(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "which \(tool)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = out.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let path = firstLine, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: - Source merging

    /// Process environment overlaid with `.env` values (real env wins; `.env` fills gaps).
    private static func mergedEnvironment() -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in loadDotEnv() where merged[k] == nil {
            merged[k] = v
        }
        return merged
    }

    /// Parse the first `.env` found among candidate locations into key/value pairs.
    /// Supports `KEY=value`, `export KEY=value`, `#` comments, and quoted values.
    private static func loadDotEnv() -> [String: String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(fm.currentDirectoryPath)/.env",
            "\(home)/.iris/.env",
        ]
        guard let path = candidates.first(where: { fm.fileExists(atPath: $0) }),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [:] }

        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2)
                || (val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = val }
        }
        return result
    }

    /// Load `~/.iris/config.json` as a flat dictionary of JSON values.
    private static func loadConfigJSON() -> [String: JSONValue] {
        let fm = FileManager.default
        let path = "\(fm.homeDirectoryForCurrentUser.path)/.iris/config.json"
        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj.mapValues(JSONValue.init(any:))
    }
}

/// Minimal wrapper so config.json values (string OR number) read back as strings.
private enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case other

    init(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        default: self = .other
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            // Render integers without a trailing ".0".
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .other: return nil
        }
    }
}
