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

/// Unambiguous alias for the config struct. SwiftUI also defines a `Settings` scene type,
/// so UI files (which import SwiftUI) reference the config via this alias to avoid the clash.
public typealias IRISSettings = Settings

public struct Settings: Sendable {
    /// Absolute path to the resolved `claude` CLI binary (best-effort; may be empty
    /// if not found, in which case the API path must be used).
    public var claudeBinary: String

    /// Anthropic API key. When present, `IRISBrain` uses the Messages API with real
    /// base64 vision instead of `claude -p`.
    public var anthropicAPIKey: String?

    /// OpenAI API key. When present, `IntentRouter` uses OpenAI function-calling to
    /// classify each command into an action (open app / run agent / answer).
    public var openAIAPIKey: String?

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

    // MARK: - Background agents (LangGraph sidecar)

    /// Absolute path to the sidecar venv's Python (e.g. sidecar/.venv/bin/python). When set,
    /// IRIS spawns the sidecar itself; when nil it only tries to connect to an already-running one.
    public var sidecarPython: String?

    /// Localhost port the sidecar serves on (must match the sidecar's IRIS_SIDECAR_PORT).
    public var sidecarPort: Int

    /// Default working directory for terminal / agent tasks (tilde expanded).
    public var defaultAgentDirectory: String

    /// Max background agents allowed to run at once (passed to the sidecar).
    public var maxConcurrentAgents: Int

    /// Whether voice barge-in (interrupt while speaking) is enabled.
    public var bargeInEnabled: Bool

    /// Model the sidecar agents reason with. Nil → the sidecar's own default
    /// (foreground Q&A always uses `model`).
    public var agentModel: String?

    // MARK: - Neural voice (OpenAI TTS)

    /// Use OpenAI neural TTS for a natural voice (when an OpenAI key is set). Falls back to the
    /// built-in AVSpeechSynthesizer when false or on failure.
    public var openAITTSEnabled: Bool

    /// OpenAI TTS voice name (e.g. nova, alloy, shimmer, sage, coral, echo, onyx, fable, ash).
    public var ttsVoice: String

    /// OpenAI TTS model (gpt-4o-mini-tts supports the `instructions` tone steer).
    public var ttsModel: String

    /// Tone/style instructions for gpt-4o-mini-tts (how the voice should sound).
    public var ttsInstructions: String

    // MARK: - Realtime (Jarvis/Cluely speech-to-speech core)

    /// Use the OpenAI Realtime API speech-to-speech core (continuous conversation) instead of the
    /// classic wake-word → one-shot pipeline. Needs an OpenAI key.
    public var realtimeEnabled: Bool

    /// Realtime model id (e.g. gpt-realtime).
    public var realtimeModel: String

    /// Realtime voice (e.g. marin, cedar, alloy, ash, sage, verse).
    public var realtimeVoice: String

    /// Keep listening continuously (true) vs require a hotkey to talk (false).
    public var alwaysOn: Bool

    /// Pause the upstream after this many seconds of silence (cost control); resumes on sound.
    public var idlePauseSeconds: Int

    /// Allow IRIS to control the Mac (type/click) via Accessibility.
    public var computerUseEnabled: Bool

    /// Screen awareness: "onDemand" (model asks via a tool) or "proactive" (periodic capture).
    public var screenAwareness: String

    /// Try hardware echo cancellation (full-duplex barge-in). Flaky on some Macs (the engine can
    /// fail to deliver input), so default OFF → reliable half-duplex (mic muted while IRIS speaks).
    public var echoCancellation: Bool

    // MARK: - Self-learning memory ("the brain")

    /// Persist + recall a self-learning memory at `~/.iris/memory.json` (+ readable `IRIS.md`).
    /// When off, IRIS neither injects nor writes learned facts/rules. Env `IRIS_MEMORY`.
    public var memoryEnabled: Bool

    /// Pass `--dangerously-skip-permissions` when starting a Claude Code session. Default true
    /// (today's behavior — the trust-folder prompt is skipped). Set false so the prompt appears
    /// and IRIS can learn to handle it via a uiRule. Env `IRIS_CLAUDE_SKIP_PERMS`.
    public var claudeSkipPermissions: Bool

    // MARK: - Cost control (CostGovernor)

    /// Hard monthly OpenAI spend cap in USD. The CostGovernor meters realtime + TTS spend and,
    /// as this budget burns down, degrades the experience: realtime → classic `claude -p` →
    /// on-device TTS. `0` means unlimited (no governing). Env `IRIS_MONTHLY_BUDGET`.
    public var monthlyBudgetUSD: Double

    // MARK: - Defaults

    public static let defaultModel = "claude-sonnet-4-6"
    public static let defaultVoice = "en-US"
    public static let defaultTTSRate: Float = 0.52
    public static let defaultWakePhrase = "hey iris"
    public static let defaultSidecarPort = 8765
    public static let defaultMaxConcurrentAgents = 4
    public static let defaultTTSVoice = "sage"
    public static let defaultTTSModel = "gpt-4o-mini-tts"
    public static let defaultTTSInstructions =
        "Speak in a warm, natural, conversational tone, like a friendly person chatting — "
        + "relaxed pacing, not robotic or overly formal."
    // Cost-optimized realtime model: gpt-realtime-mini is ~3.2× cheaper on audio than full
    // gpt-realtime ($10/$20 vs $32/$64 per 1M audio tokens). Override with IRIS_REALTIME_MODEL.
    public static let defaultRealtimeModel = "gpt-realtime-mini"
    public static let defaultRealtimeVoice = "marin"
    public static let defaultIdlePauseSeconds = 15
    public static let defaultMonthlyBudgetUSD = 20.0

    public init(
        claudeBinary: String,
        anthropicAPIKey: String?,
        openAIAPIKey: String?,
        model: String,
        voice: String,
        voiceIdentifier: String?,
        ttsRate: Float,
        wakePhrase: String,
        sidecarPython: String? = nil,
        sidecarPort: Int = Settings.defaultSidecarPort,
        defaultAgentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        maxConcurrentAgents: Int = Settings.defaultMaxConcurrentAgents,
        bargeInEnabled: Bool = false,
        agentModel: String? = nil,
        openAITTSEnabled: Bool = true,
        ttsVoice: String = Settings.defaultTTSVoice,
        ttsModel: String = Settings.defaultTTSModel,
        ttsInstructions: String = Settings.defaultTTSInstructions,
        realtimeEnabled: Bool = true,
        realtimeModel: String = Settings.defaultRealtimeModel,
        realtimeVoice: String = Settings.defaultRealtimeVoice,
        alwaysOn: Bool = true,
        idlePauseSeconds: Int = Settings.defaultIdlePauseSeconds,
        computerUseEnabled: Bool = true,
        screenAwareness: String = "onDemand",
        echoCancellation: Bool = false,
        memoryEnabled: Bool = true,
        claudeSkipPermissions: Bool = true,
        monthlyBudgetUSD: Double = Settings.defaultMonthlyBudgetUSD
    ) {
        self.claudeBinary = claudeBinary
        self.anthropicAPIKey = anthropicAPIKey
        self.openAIAPIKey = openAIAPIKey
        self.model = model
        self.voice = voice
        self.voiceIdentifier = voiceIdentifier
        self.ttsRate = ttsRate
        self.wakePhrase = wakePhrase
        self.sidecarPython = sidecarPython
        self.sidecarPort = sidecarPort
        self.defaultAgentDirectory = defaultAgentDirectory
        self.maxConcurrentAgents = maxConcurrentAgents
        self.bargeInEnabled = bargeInEnabled
        self.agentModel = agentModel
        self.openAITTSEnabled = openAITTSEnabled
        self.ttsVoice = ttsVoice
        self.ttsModel = ttsModel
        self.ttsInstructions = ttsInstructions
        self.realtimeEnabled = realtimeEnabled
        self.realtimeModel = realtimeModel
        self.realtimeVoice = realtimeVoice
        self.alwaysOn = alwaysOn
        self.idlePauseSeconds = idlePauseSeconds
        self.computerUseEnabled = computerUseEnabled
        self.screenAwareness = screenAwareness
        self.echoCancellation = echoCancellation
        self.memoryEnabled = memoryEnabled
        self.claudeSkipPermissions = claudeSkipPermissions
        self.monthlyBudgetUSD = monthlyBudgetUSD
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
        let openAIKey = value("openAIAPIKey", "OPENAI_API_KEY")

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

        // Background-agent sidecar config.
        let sidecarPython = value("sidecarPython", "IRIS_SIDECAR_PYTHON")
        let sidecarPort = value("sidecarPort", "IRIS_SIDECAR_PORT").flatMap(Int.init)
            ?? defaultSidecarPort
        let defaultAgentDir = (value("defaultAgentDirectory", "IRIS_AGENT_DIR")
            .map { ($0 as NSString).expandingTildeInPath })
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let maxAgents = value("maxConcurrentAgents", "IRIS_MAX_AGENTS").flatMap(Int.init)
            ?? defaultMaxConcurrentAgents
        // Default OFF: keeping the mic live during TTS (for voice barge-in) causes a self-hearing
        // feedback loop without hardware echo cancellation. ⌥⎋ interrupts during speech instead;
        // seamless voice barge-in arrives with the Realtime speech-to-speech step. Power users can
        // re-enable with IRIS_BARGE_IN=1 / "bargeInEnabled": true.
        let bargeIn = parseBool(value("bargeInEnabled", "IRIS_BARGE_IN")) ?? false
        let agentModel = value("agentModel", "IRIS_AGENT_MODEL")

        // Neural voice (OpenAI TTS).
        let openAITTS = parseBool(value("openAITTSEnabled", "IRIS_OPENAI_TTS")) ?? true
        let ttsVoice = value("ttsVoice", "IRIS_TTS_VOICE") ?? defaultTTSVoice
        let ttsModel = value("ttsModel", "IRIS_TTS_MODEL") ?? defaultTTSModel
        let ttsInstructions = value("ttsInstructions", "IRIS_TTS_INSTRUCTIONS")
            ?? defaultTTSInstructions

        // Realtime core.
        let realtimeEnabled = parseBool(value("realtimeEnabled", "IRIS_REALTIME")) ?? true
        let realtimeModel = value("realtimeModel", "IRIS_REALTIME_MODEL") ?? defaultRealtimeModel
        let realtimeVoice = value("realtimeVoice", "IRIS_REALTIME_VOICE") ?? defaultRealtimeVoice
        let alwaysOn = parseBool(value("alwaysOn", "IRIS_ALWAYS_ON")) ?? true
        let idlePause = value("idlePauseSeconds", "IRIS_IDLE_PAUSE").flatMap(Int.init)
            ?? defaultIdlePauseSeconds
        let computerUse = parseBool(value("computerUseEnabled", "IRIS_COMPUTER_USE")) ?? true
        let screenAwareness = value("screenAwareness", "IRIS_SCREEN_AWARENESS") ?? "onDemand"
        let echoCancellation = parseBool(value("echoCancellation", "IRIS_ECHO_CANCEL")) ?? false
        let memoryEnabled = parseBool(value("memoryEnabled", "IRIS_MEMORY")) ?? true
        let claudeSkipPermissions = parseBool(value("claudeSkipPermissions", "IRIS_CLAUDE_SKIP_PERMS")) ?? true

        // Monthly OpenAI spend cap (USD). 0 = unlimited.
        let monthlyBudget = value("monthlyBudgetUSD", "IRIS_MONTHLY_BUDGET").flatMap(Double.init)
            ?? defaultMonthlyBudgetUSD

        return Settings(
            claudeBinary: claudeBinary,
            anthropicAPIKey: apiKey,
            openAIAPIKey: openAIKey,
            model: model,
            voice: voice,
            voiceIdentifier: voiceIdentifier,
            ttsRate: ttsRate,
            wakePhrase: wakePhrase,
            sidecarPython: sidecarPython,
            sidecarPort: sidecarPort,
            defaultAgentDirectory: defaultAgentDir,
            maxConcurrentAgents: maxAgents,
            bargeInEnabled: bargeIn,
            agentModel: agentModel,
            openAITTSEnabled: openAITTS,
            ttsVoice: ttsVoice,
            ttsModel: ttsModel,
            ttsInstructions: ttsInstructions,
            realtimeEnabled: realtimeEnabled,
            realtimeModel: realtimeModel,
            realtimeVoice: realtimeVoice,
            alwaysOn: alwaysOn,
            idlePauseSeconds: idlePause,
            computerUseEnabled: computerUse,
            screenAwareness: screenAwareness,
            echoCancellation: echoCancellation,
            memoryEnabled: memoryEnabled,
            claudeSkipPermissions: claudeSkipPermissions,
            monthlyBudgetUSD: monthlyBudget
        )
    }

    /// Parse a loosely-typed truthy/falsy config string. Returns nil when unset/unrecognized.
    private static func parseBool(_ s: String?) -> Bool? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else {
            return nil
        }
        if ["1", "true", "yes", "on"].contains(s) { return true }
        if ["0", "false", "no", "off"].contains(s) { return false }
        return nil
    }

    // MARK: - Persistence (menu-bar Settings write-back)

    /// Return a copy with updated API keys / model / monthly budget — used by the Settings window
    /// before saving and re-applying. Empty strings are normalized to `nil` (key cleared); a blank
    /// or unparseable budget keeps the current value.
    public func withUpdatedKeys(anthropic: String, openAI: String, model: String,
                                budget: String) -> Settings {
        func nilIfEmpty(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var copy = self
        copy.anthropicAPIKey = nilIfEmpty(anthropic)
        copy.openAIAPIKey = nilIfEmpty(openAI)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = trimmedModel.isEmpty ? Settings.defaultModel : trimmedModel
        let trimmedBudget = budget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let b = Double(trimmedBudget), b >= 0 { copy.monthlyBudgetUSD = b }
        return copy
    }

    /// Persist the user-editable fields to `~/.iris/config.json`, merging with whatever is
    /// already there so keys we don't manage survive. The secrets live OUTSIDE the repo, so
    /// they can never be committed (see scripts/pre-commit for the staging guard).
    public func save() throws {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".iris", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")

        // Start from the existing file so unknown keys aren't clobbered.
        var obj: [String: Any] = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        func put(_ key: String, _ v: String?) {
            if let v, !v.isEmpty { obj[key] = v } else { obj.removeValue(forKey: key) }
        }
        put("anthropicAPIKey", anthropicAPIKey)
        put("openAIAPIKey", openAIAPIKey)
        put("voiceIdentifier", voiceIdentifier)
        obj["model"] = model
        obj["voice"] = voice
        obj["wakePhrase"] = wakePhrase
        obj["ttsRate"] = ttsRate
        obj["monthlyBudgetUSD"] = monthlyBudgetUSD
        // claudeBinary is deliberately NOT written — preserve the auto-probe on next launch.

        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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
