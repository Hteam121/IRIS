//
//  ScreenRuleEngine.swift
//  IRIS — Vision + AI lane
//
//  Reactive application of learned `uiRule` memories. Right AFTER IRIS performs an action that
//  commonly surfaces a known dialog (e.g. it just opened a Claude Code session), it glances at the
//  screen, asks the vision model whether any learned situation is showing, and — if so — performs
//  the remembered action via ComputerControl. This is what turns "I told it once" into "it just
//  does it" for things like the "Do you trust the files in this folder?" prompt.
//
//  No always-on watching: this only runs when a caller invokes it after its own action.
//

import Foundation

@MainActor
enum ScreenRuleEngine {

    /// Minimum vision confidence before we synthesize input for a learned rule (docs/algorithms.md
    /// → Screen rule engine). High on purpose: a false-positive keypress/click is worse than a miss.
    static let matchConfidenceFloor = 0.8

    /// Look at the screen and apply the first matching learned `uiRule`. Returns a short spoken
    /// note when it acted, or nil (no rules, no match, or can't act).
    static func applyLearnedRules(memory: MemoryStore, screenCapture: ScreenCapture,
                                  settings: Settings, costGovernor: CostGovernor?,
                                  renderDelay: TimeInterval = 1.2) async -> String? {
        guard settings.memoryEnabled, settings.computerUseEnabled else { return nil }
        let rules = memory.uiRules
        guard !rules.isEmpty else { return nil }
        guard let key = settings.openAIAPIKey, !key.isEmpty else { return nil }
        // Budget gate: the paid gpt-4o vision match must not run once the budget is spent (.free),
        // which would otherwise break that tier's "zero OpenAI spend" guarantee.
        guard let costGovernor, costGovernor.allowsPaidVision else { return nil }

        // Let the just-launched UI render before we look.
        if renderDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(renderDelay * 1_000_000_000))
        }

        guard let path = await screenCapture.capture(),
              let imgData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        guard let match = await matchRule(rules: rules, imageData: imgData, apiKey: key,
                                          costGovernor: costGovernor),
              rules.indices.contains(match.index) else { return nil }

        let rule = rules[match.index]
        guard let action = rule.action else { return nil }

        let result = perform(action, fallbackX: match.x, fallbackY: match.y)
        memory.touch(id: rule.id)
        IRISLog.log("memory: applied uiRule \"\(rule.trigger ?? rule.text)\" → \(action.spokenDescription) [\(result)]")

        if action.kind == "pressKey", (action.key == "enter" || action.key == "return") {
            return "I took care of that prompt for you."
        }
        return "I handled that for you."
    }

    /// Open a Terminal (optionally starting a Claude Code session), then apply any learned screen
    /// rule and fold its spoken note into the reply. The "launch → apply rules → fold note" sequence
    /// is shared by the classic (AppDelegate `.terminal`) and realtime (RealtimeTools `open_terminal`)
    /// paths so it lives in one place. `applyLearnedRules` is only consulted when a Claude session
    /// was started and memory is available; it self-gates on memory/computer-use/budget.
    static func openTerminalApplyingRules(
        in directory: String, startClaude: Bool, settings: Settings,
        memory: MemoryStore?, screenCapture: ScreenCapture, costGovernor: CostGovernor?
    ) async -> String {
        let reply = await TerminalLauncher.open(
            in: directory, claudeBinary: settings.claudeBinary, startClaude: startClaude,
            skipPermissions: settings.claudeSkipPermissions)
        // Don't spend a paid vision call if the surrounding task was interrupted right after launch.
        if Task.isCancelled { return reply }
        guard startClaude, let memory,
              let note = await applyLearnedRules(
                  memory: memory, screenCapture: screenCapture, settings: settings,
                  costGovernor: costGovernor) else {
            return reply
        }
        return reply + " " + note
    }

    // MARK: - Action execution

    private static func perform(_ action: MemoryAction, fallbackX: Double?, fallbackY: Double?) -> String {
        switch action.kind {
        case "pressKey":
            return ComputerControl.pressKey(action.key ?? "enter", modifiers: action.modifiers ?? [])
        case "type":
            return ComputerControl.typeText(action.text ?? "")
        case "click":
            guard let x = action.x ?? fallbackX, let y = action.y ?? fallbackY else {
                return "no coordinates to click"
            }
            return ComputerControl.click(x: x, y: y)
        default:
            return "unknown action"
        }
    }

    // MARK: - Vision match (OpenAI gpt-4o, strict JSON)

    private struct Match { let index: Int; let x: Double?; let y: Double? }

    /// Ask gpt-4o whether the screenshot shows one of the learned situations. Returns the matched
    /// rule index (0-based) plus optional click coordinates, or nil for no match.
    private static func matchRule(rules: [MemoryItem], imageData: Data, apiKey: String,
                                  costGovernor: CostGovernor?) async -> Match? {
        let list = rules.enumerated()
            .map { "\($0.offset + 1). \($0.element.trigger ?? $0.element.text)" }
            .joined(separator: "\n")
        let instruction = """
        You watch the user's screen for known recurring situations IRIS has learned to handle:
        \(list)

        Look at the screenshot. If the screen currently shows EXACTLY one of these situations, \
        return its number; otherwise return 0. Only claim a match when you are CERTAIN the exact \
        situation is visible right now — when unsure, return 0. Respond with ONLY strict JSON in \
        this shape: {"match": <number>, "confidence": <0..1>, "x": <number or null>, \
        "y": <number or null>}. `confidence` is how sure you are the situation is on screen. \
        Include x and y (screen points, top-left origin) ONLY when a mouse click is required to act \
        on the matched situation; otherwise use null.
        """

        guard let reply = await OpenAIVision.complete(
            imageData: imageData, instruction: instruction, apiKey: apiKey,
            maxTokens: 100, jsonMode: true) else { return nil }
        // Meter this paid call against the monthly budget (cost is incurred whether or not it matched).
        costGovernor?.recordVision(usage: reply.usage)
        guard let content = reply.content,
              let parsed = try? JSONSerialization.jsonObject(
                with: Data(content.utf8)) as? [String: Any] else { return nil }

        let matchNum = (parsed["match"] as? NSNumber)?.intValue ?? 0
        guard matchNum >= 1 else { return nil }
        // Confidence gate: synthesizing a real keypress/click into the focused window on a vision
        // false-positive is the worst failure here, so require the model to be sure. A missing
        // confidence (older/strict-mode responses) is treated as certain since match>=1 already.
        let confidence = (parsed["confidence"] as? NSNumber)?.doubleValue ?? 1.0
        guard confidence >= Self.matchConfidenceFloor else {
            IRISLog.log("memory: screen-rule match \(matchNum) below confidence floor (\(confidence)) — skipping")
            return nil
        }
        let x = (parsed["x"] as? NSNumber)?.doubleValue
        let y = (parsed["y"] as? NSNumber)?.doubleValue
        return Match(index: matchNum - 1, x: x, y: y)
    }
}
