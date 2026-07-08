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

    /// Anthropic API key. When present, `ClaudeEngine` uses the Messages API (streaming,
    /// prompt caching, real base64 vision) instead of `claude -p`.
    public var anthropicAPIKey: String?

    /// OpenAI API key. Used only for neural TTS (gpt-4o-mini-tts).
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

    /// Also wake on the bare assistant name ANYWHERE in a sentence ("…, Dory?").
    /// Env `IRIS_WAKE_NAME_ONLY`.
    public var wakeNameOnly: Bool

    /// Push-to-talk chord: hold this key (virtual keycode; 49 = Space)…
    public var pttKeyCode: UInt16
    /// …with these modifier flags (NSEvent.ModifierFlags raw value; default ⌥).
    public var pttModifiers: UInt

    /// Main surface: "buddy" (cursor-following orb + caption, Clicky-style) or "notch"
    /// (island anchored over the camera). Env `IRIS_UI_MODE`.
    public var uiMode: String

    // MARK: - Background agents (Claude Code sessions)

    /// Default working directory for terminal / agent tasks (tilde expanded).
    public var defaultAgentDirectory: String

    /// Max background agent sessions allowed to run at once.
    public var maxConcurrentAgents: Int

    /// Whether voice barge-in (interrupt while speaking) is enabled.
    public var bargeInEnabled: Bool

    /// Model background agent sessions reason with. Nil → `model`.
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

    /// OpenAI TTS speed multiplier (0.25–4.0; 1.0 = normal). Env `IRIS_TTS_SPEED`.
    public var ttsSpeed: Double

    // MARK: - Mac control

    /// Allow IRIS to control the Mac (type/click) via Accessibility.
    public var computerUseEnabled: Bool

    // MARK: - Self-learning memory ("the brain")

    /// Persist + recall a self-learning memory at `~/.iris/memory.json` (+ readable `IRIS.md`).
    /// When off, IRIS neither injects nor writes learned facts/rules. Env `IRIS_MEMORY`.
    public var memoryEnabled: Bool

    /// Pass `--dangerously-skip-permissions` when starting a Claude Code session. Default true
    /// (today's behavior — the trust-folder prompt is skipped). Set false so the prompt appears
    /// and IRIS can learn to handle it via a uiRule. Env `IRIS_CLAUDE_SKIP_PERMS`.
    public var claudeSkipPermissions: Bool

    // MARK: - Cost control (CostGovernor)

    /// Hard monthly OpenAI spend cap in USD. The CostGovernor meters TTS + vision spend and,
    /// as this budget burns down, degrades the experience toward the free `claude -p` pipeline
    /// and on-device TTS. `0` means unlimited (no governing). Env `IRIS_MONTHLY_BUDGET`.
    public var monthlyBudgetUSD: Double

    // MARK: - Screen pointing (PointerOverlay)

    /// Show the animated on-screen pointer when the model wants to point at a UI element.
    /// Env `IRIS_POINTER`.
    public var pointerEnabled: Bool

    // MARK: - Skills (~/.iris/skills/*.md)

    /// Discover markdown skills at `~/.iris/skills/` and expose them via the `run_skill`
    /// tool + prompt catalog. Env `IRIS_SKILLS`.
    public var skillsEnabled: Bool

    // MARK: - Local-first routing (Ollama / Apple Foundation Models)

    /// Try a free local model for simple foreground questions before paying for the cloud.
    /// Env `IRIS_LOCAL_LLM`.
    public var localLLMEnabled: Bool

    /// Ollama model name used for local answers. Env `IRIS_LOCAL_MODEL`.
    public var localModel: String

    /// Base URL of the Ollama server. Env `IRIS_OLLAMA_URL`.
    public var ollamaURL: String

    // MARK: - Defaults

    public static let defaultModel = "claude-sonnet-4-6"
    public static let defaultVoice = "en-US"
    public static let defaultTTSRate: Float = 0.52
    public static let defaultWakePhrase = "hey dory"
    /// The pre-rename default. A persisted config.json equal to this is treated as "never
    /// customized" and migrated to the new default at load (see `load()`).
    public static let legacyDefaultWakePhrase = "hey iris"
    public static let defaultMaxConcurrentAgents = 4
    /// Space (49) held with ⌥ (option = 1 << 19 in NSEvent.ModifierFlags).
    public static let defaultPTTKeyCode: UInt16 = 49
    public static let defaultPTTModifiers: UInt = 1 << 19
    public static let defaultTTSVoice = "nova"
    public static let defaultTTSModel = "gpt-4o-mini-tts"
    public static let defaultTTSInstructions =
        "Speak as a warm, friendly female voice with a QUICK, energetic pace — snappy and "
        + "efficient like a sharp assistant, never slow or drawn out, but still natural."
    /// Playback speed multiplier for OpenAI TTS (1.0 = normal). Env `IRIS_TTS_SPEED`.
    public static let defaultTTSSpeed = 1.15
    public static let defaultMonthlyBudgetUSD = 20.0
    public static let defaultLocalModel = "llama3.2"
    public static let defaultOllamaURL = "http://localhost:11434"

    public init(
        claudeBinary: String,
        anthropicAPIKey: String?,
        openAIAPIKey: String?,
        model: String,
        voice: String,
        voiceIdentifier: String?,
        ttsRate: Float,
        wakePhrase: String,
        wakeNameOnly: Bool = true,
        pttKeyCode: UInt16 = Settings.defaultPTTKeyCode,
        pttModifiers: UInt = Settings.defaultPTTModifiers,
        uiMode: String = "buddy",
        defaultAgentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        maxConcurrentAgents: Int = Settings.defaultMaxConcurrentAgents,
        bargeInEnabled: Bool = false,
        agentModel: String? = nil,
        openAITTSEnabled: Bool = true,
        ttsVoice: String = Settings.defaultTTSVoice,
        ttsModel: String = Settings.defaultTTSModel,
        ttsInstructions: String = Settings.defaultTTSInstructions,
        ttsSpeed: Double = Settings.defaultTTSSpeed,
        computerUseEnabled: Bool = true,
        memoryEnabled: Bool = true,
        claudeSkipPermissions: Bool = true,
        monthlyBudgetUSD: Double = Settings.defaultMonthlyBudgetUSD,
        pointerEnabled: Bool = true,
        skillsEnabled: Bool = true,
        localLLMEnabled: Bool = true,
        localModel: String = Settings.defaultLocalModel,
        ollamaURL: String = Settings.defaultOllamaURL
    ) {
        self.claudeBinary = claudeBinary
        self.anthropicAPIKey = anthropicAPIKey
        self.openAIAPIKey = openAIAPIKey
        self.model = model
        self.voice = voice
        self.voiceIdentifier = voiceIdentifier
        self.ttsRate = ttsRate
        self.wakePhrase = wakePhrase
        self.wakeNameOnly = wakeNameOnly
        self.pttKeyCode = pttKeyCode
        self.pttModifiers = pttModifiers
        self.uiMode = uiMode
        self.defaultAgentDirectory = defaultAgentDirectory
        self.maxConcurrentAgents = maxConcurrentAgents
        self.bargeInEnabled = bargeInEnabled
        self.agentModel = agentModel
        self.openAITTSEnabled = openAITTSEnabled
        self.ttsVoice = ttsVoice
        self.ttsModel = ttsModel
        self.ttsInstructions = ttsInstructions
        self.ttsSpeed = ttsSpeed
        self.computerUseEnabled = computerUseEnabled
        self.memoryEnabled = memoryEnabled
        self.claudeSkipPermissions = claudeSkipPermissions
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.pointerEnabled = pointerEnabled
        self.skillsEnabled = skillsEnabled
        self.localLLMEnabled = localLLMEnabled
        self.localModel = localModel
        self.ollamaURL = ollamaURL
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
        var wakePhrase = (value("wakePhrase", "IRIS_WAKE_PHRASE") ?? defaultWakePhrase)
            .lowercased()
        // Migration: the Settings window used to persist the old default ("hey iris") to
        // config.json, which would silently pin the pre-rename phrase forever. Treat the old
        // default as "never customized"; any other custom phrase is respected verbatim.
        if wakePhrase == legacyDefaultWakePhrase { wakePhrase = defaultWakePhrase }

        let ttsRate: Float = {
            if let s = value("ttsRate", "IRIS_TTS_RATE"), let f = Float(s) { return f }
            return defaultTTSRate
        }()

        // Allow an explicit override, else probe the filesystem for `claude`.
        let claudeBinary = value("claudeBinary", "IRIS_CLAUDE_BINARY")
            ?? resolveClaudeBinary()

        // Triggers.
        let wakeNameOnly = parseBool(value("wakeNameOnly", "IRIS_WAKE_NAME_ONLY")) ?? true
        let pttKeyCode = value("pttKeyCode", "IRIS_PTT_KEYCODE").flatMap(UInt16.init)
            ?? defaultPTTKeyCode
        let pttModifiers = value("pttModifiers", "IRIS_PTT_MODIFIERS").flatMap(UInt.init)
            ?? defaultPTTModifiers
        let uiMode = value("uiMode", "IRIS_UI_MODE") ?? "buddy"

        // Background-agent config.
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
        let ttsSpeed = value("ttsSpeed", "IRIS_TTS_SPEED").flatMap(Double.init)
            ?? defaultTTSSpeed

        // Stale realtime keys in an existing config.json / .env are deliberately ignored.
        let computerUse = parseBool(value("computerUseEnabled", "IRIS_COMPUTER_USE")) ?? true
        let memoryEnabled = parseBool(value("memoryEnabled", "IRIS_MEMORY")) ?? true
        let claudeSkipPermissions = parseBool(value("claudeSkipPermissions", "IRIS_CLAUDE_SKIP_PERMS")) ?? true

        // Monthly OpenAI spend cap (USD). 0 = unlimited.
        let monthlyBudget = value("monthlyBudgetUSD", "IRIS_MONTHLY_BUDGET").flatMap(Double.init)
            ?? defaultMonthlyBudgetUSD

        // Screen pointing, skills, local-first routing.
        let pointerEnabled = parseBool(value("pointerEnabled", "IRIS_POINTER")) ?? true
        let skillsEnabled = parseBool(value("skillsEnabled", "IRIS_SKILLS")) ?? true
        let localLLMEnabled = parseBool(value("localLLMEnabled", "IRIS_LOCAL_LLM")) ?? true
        let localModel = value("localModel", "IRIS_LOCAL_MODEL") ?? defaultLocalModel
        let ollamaURL = value("ollamaURL", "IRIS_OLLAMA_URL") ?? defaultOllamaURL

        return Settings(
            claudeBinary: claudeBinary,
            anthropicAPIKey: apiKey,
            openAIAPIKey: openAIKey,
            model: model,
            voice: voice,
            voiceIdentifier: voiceIdentifier,
            ttsRate: ttsRate,
            wakePhrase: wakePhrase,
            wakeNameOnly: wakeNameOnly,
            pttKeyCode: pttKeyCode,
            pttModifiers: pttModifiers,
            uiMode: uiMode,
            defaultAgentDirectory: defaultAgentDir,
            maxConcurrentAgents: maxAgents,
            bargeInEnabled: bargeIn,
            agentModel: agentModel,
            openAITTSEnabled: openAITTS,
            ttsVoice: ttsVoice,
            ttsModel: ttsModel,
            ttsInstructions: ttsInstructions,
            ttsSpeed: ttsSpeed,
            computerUseEnabled: computerUse,
            memoryEnabled: memoryEnabled,
            claudeSkipPermissions: claudeSkipPermissions,
            monthlyBudgetUSD: monthlyBudget,
            pointerEnabled: pointerEnabled,
            skillsEnabled: skillsEnabled,
            localLLMEnabled: localLLMEnabled,
            localModel: localModel,
            ollamaURL: ollamaURL
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

    /// The user-editable fields the Settings window round-trips.
    public struct Form {
        public var anthropicKey: String
        public var openAIKey: String
        public var model: String
        public var budget: String
        public var wakePhrase: String
        public var ttsVoice: String
        public var localLLMEnabled: Bool
    }

    /// Return a copy with the form's values applied — used by the Settings window before
    /// saving and re-applying. Empty strings are normalized to `nil` (key cleared) or the
    /// default; a blank or unparseable budget keeps the current value.
    public func applying(_ form: Form) -> Settings {
        func nilIfEmpty(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var copy = self
        copy.anthropicAPIKey = nilIfEmpty(form.anthropicKey)
        copy.openAIAPIKey = nilIfEmpty(form.openAIKey)
        copy.model = nilIfEmpty(form.model) ?? Settings.defaultModel
        if let b = Double(form.budget.trimmingCharacters(in: .whitespacesAndNewlines)), b >= 0 {
            copy.monthlyBudgetUSD = b
        }
        copy.wakePhrase = (nilIfEmpty(form.wakePhrase) ?? Settings.defaultWakePhrase).lowercased()
        copy.ttsVoice = nilIfEmpty(form.ttsVoice) ?? Settings.defaultTTSVoice
        copy.localLLMEnabled = form.localLLMEnabled
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
        obj["ttsVoice"] = ttsVoice
        obj["localLLMEnabled"] = localLLMEnabled
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
