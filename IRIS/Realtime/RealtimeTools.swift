//
//  RealtimeTools.swift
//  IRIS — Realtime lane
//
//  Tool definitions for the Realtime model + a dispatcher that maps each tool call to IRIS's
//  existing native actions (AppLauncher, FolderOpener, WebSearch, TerminalLauncher), background
//  agents (AgentManager + sidecar), screen vision (ScreenCapture), local info (LocalAnswers), and
//  Mac control (ComputerControl). This is where the model's reasoning turns into real actions.
//

import Foundation

@MainActor
enum RealtimeTools {

    /// Realtime tool schemas (flat {type, name, description, parameters} form the Realtime API uses).
    static func schemas(computerUse: Bool, memoryEnabled: Bool) -> [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "name": name, "description": desc,
             "parameters": ["type": "object", "properties": props, "required": required]]
        }
        let str = ["type": "string"]
        var tools: [[String: Any]] = [
            tool("open_app", "Open or activate a macOS application by name.",
                 ["app_name": str], ["app_name"]),
            tool("open_folder", "Open an EXISTING folder / the user's files in Finder.",
                 ["folder": ["type": "string", "description": "Folder path or spoken name (desktop, documents, a folder)."]], []),
            tool("create_folder", "Create a NEW folder and reveal it in Finder. Use this (NOT open_folder) whenever the user asks to make/create a new folder.",
                 ["name": ["type": "string", "description": "Name for the new folder."],
                  "location": ["type": "string", "description": "Where to create it: desktop, documents, downloads, or a path. Optional; defaults to the Desktop."]], ["name"]),
            tool("web_search", "Open a web search in the browser for a query.",
                 ["query": str, "browser": ["type": "string", "description": "chrome/safari/firefox; optional"]], ["query"]),
            tool("open_terminal", "Open a Terminal, optionally starting a Claude Code session.",
                 ["directory": ["type": "string", "description": "Folder path/name; optional"],
                  "start_claude": ["type": "boolean", "description": "Start a claude session?"]], []),
            tool("run_background_task", "Run a long-running autonomous task in the background (web research, multi-step work) while you keep talking.",
                 ["task": str], ["task"]),
            tool("get_datetime", "Get the current local time and/or date.", [:], []),
            tool("look_at_screen", "Look at what's currently on the user's screen and answer a question about it.",
                 ["question": ["type": "string", "description": "What to look for / answer about the screen."]], []),
            tool("answer_task", "Answer a question a background task asked the user. Call with the user's reply when a task is paused waiting on them.",
                 ["answer": ["type": "string", "description": "The user's answer to the task's question."]], ["answer"]),
            tool("redirect_task", "Redirect the currently running background task with a new instruction (e.g. 'look on Amazon instead', 'avoid cars.com').",
                 ["instruction": ["type": "string", "description": "The user's new instruction for the running task."]], ["instruction"]),
        ]
        if computerUse {
            tools += [
                tool("type_text", "Type text wherever the cursor currently is.", ["text": str], ["text"]),
                tool("press_key", "Press a key, optionally with modifiers (e.g. key 'enter', or 's' + ['command']).",
                     ["key": str, "modifiers": ["type": "array", "items": str]], ["key"]),
                tool("click", "Click at a screen coordinate (points, top-left origin).",
                     ["x": ["type": "number"], "y": ["type": "number"]], ["x", "y"]),
            ]
        }
        if memoryEnabled {
            tools += [
                tool("remember",
                     "Save something to your long-term memory so you recall it in future sessions: a user preference, a standing instruction, or a stable fact. For a recurring on-screen step (e.g. a confirmation dialog) also pass `trigger` (what's on screen) and `action` (what to do, e.g. \"press enter\").",
                     ["memory": ["type": "string", "description": "Short third-person statement to remember, e.g. 'User prefers Chrome for searches'."],
                      "trigger": ["type": "string", "description": "Optional: the on-screen situation to recognize later."],
                      "action": ["type": "string", "description": "Optional: what to do when the trigger appears, e.g. 'press enter', 'press 1', 'click yes'."]],
                     ["memory"]),
                tool("forget",
                     "Remove something from your long-term memory that the user no longer wants you to remember.",
                     ["query": ["type": "string", "description": "Describe what to forget."]], ["query"]),
            ]
        }
        return tools
    }

    /// Execute a tool call and return a short result string for the model.
    static func run(name: String, args: [String: Any],
                    settings: Settings, agentManager: AgentManager?,
                    screenCapture: ScreenCapture, memory: MemoryStore?,
                    costGovernor: CostGovernor?) async -> String {
        func s(_ k: String) -> String? {
            (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let router = IntentRouter(settings: settings, urlSession: .shared)

        switch name {
        case "open_app":
            return await AppLauncher.open(appName: s("app_name") ?? "")

        case "open_folder":
            if let folder = s("folder"), !folder.isEmpty {
                if let dir = router.resolveFolderArgument(folder) { return FolderOpener.open(dir) }
                return "I couldn't find a folder called \(folder) anywhere on your Mac."
            }
            return FolderOpener.open(FileManager.default.homeDirectoryForCurrentUser.path)

        case "create_folder":
            guard let folderName = s("name"), !folderName.isEmpty else {
                return "What should I name the folder?"
            }
            let parent: String
            if let loc = s("location"), !loc.isEmpty, let resolved = router.resolveFolderArgument(loc) {
                parent = resolved
            } else {
                parent = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                    .appendingPathComponent("Desktop")
            }
            return FolderOpener.create(name: folderName, in: parent)

        case "web_search":
            return WebSearch.open(query: s("query") ?? "", browser: s("browser"))

        case "open_terminal":
            let startClaude = (args["start_claude"] as? Bool) ?? false
            var dir = settings.defaultAgentDirectory
            if let arg = s("directory"), !arg.isEmpty {
                if let resolved = router.resolveFolderArgument(arg) {
                    dir = resolved
                } else {
                    return "I couldn't find a folder called \(arg), so I didn't open the terminal."
                }
            }
            // Open the terminal and, when a Claude session was started, apply any learned screen
            // rule (e.g. press Enter on the "trust this folder?" prompt) and fold in its note.
            return await ScreenRuleEngine.openTerminalApplyingRules(
                in: dir, startClaude: startClaude, settings: settings,
                memory: memory, screenCapture: screenCapture, costGovernor: costGovernor)

        case "run_background_task":
            guard let task = s("task"), !task.isEmpty else { return "What should I work on?" }
            agentManager?.launch(kind: .agent, detail: task)
            return "On it — I'll work on that in the background and tell you when it's done."

        case "get_datetime":
            return LocalAnswers.answer(for: "what time and date is it") ?? "I'm not sure of the time."

        case "look_at_screen":
            return await describeScreen(question: s("question") ?? "What's on the screen?",
                                        settings: settings, screenCapture: screenCapture,
                                        costGovernor: costGovernor)

        case "type_text":
            return ComputerControl.typeText(s("text") ?? "")

        case "press_key":
            let mods = (args["modifiers"] as? [String]) ?? []
            return ComputerControl.pressKey(s("key") ?? "", modifiers: mods)

        case "click":
            let x = (args["x"] as? Double) ?? (args["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (args["y"] as? Double) ?? (args["y"] as? NSNumber)?.doubleValue ?? 0
            return ComputerControl.click(x: x, y: y)

        case "remember":
            guard let memory else { return "My memory is turned off right now." }
            guard let text = s("memory"), !text.isEmpty else { return "What should I remember?" }
            let trigger = s("trigger")
            let action = parseAction(s("action"))
            // A trigger + recognizable action makes this a reactive screen rule; otherwise it's a
            // plain preference/fact recalled into my instructions.
            if let trigger, !trigger.isEmpty, let action {
                memory.add(text: text, kind: .uiRule, source: .explicit,
                           trigger: trigger, action: action)
            } else {
                memory.add(text: text, kind: .preference, source: .explicit)
            }
            return "Got it — I'll remember that."

        case "forget":
            guard let memory else { return "My memory is turned off right now." }
            if let removed = memory.remove(matching: s("query") ?? "") {
                return "Okay, I forgot that — \(removed)."
            }
            return "I couldn't find anything like that to forget."

        case "answer_task":
            guard let answer = s("answer"), !answer.isEmpty else { return "What's the answer?" }
            return agentManager?.answerWaiting(answer) ?? "There's no task waiting on an answer."

        case "redirect_task":
            guard let instruction = s("instruction"), !instruction.isEmpty else {
                return "What should I change about it?"
            }
            return agentManager?.redirect(instruction) ?? "There's no running task to redirect."

        default:
            return "I don't have a way to do that yet."
        }
    }

    /// Turn a loose spoken action ("press enter", "click yes", "type 1") into a concrete
    /// `MemoryAction`. Confirmation words map to Enter (the default button), refusals to Escape —
    /// so "click yes / I trust it" reliably becomes a keypress that works in dialogs and TUIs.
    static func parseAction(_ raw: String?) -> MemoryAction? {
        guard let s = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        // Explicit "type X" → type the literal remainder.
        if let r = s.range(of: "type ") {
            let text = String(s[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " '\"“”"))
            if !text.isEmpty { return MemoryAction(kind: "type", text: text) }
        }
        // Refusal / negation FIRST, before any named-key or confirm match, so a negated phrase
        // ("don't confirm", "do not accept", "no, cancel") maps to Escape rather than matching the
        // confirm word inside it and pressing Enter — the opposite of what the user wanted.
        let negationMarkers = ["don't", "dont", "do not", "never", "without", "instead of", "rather not"]
        let isNegated = negationMarkers.contains { s.contains($0) }

        // Whole-word matching for the short intent words so "no" doesn't fire inside "now"/"know"
        // and "ok" doesn't fire inside unrelated words.
        let words = Set(s.split(whereSeparator: { !$0.isLetter }).map(String.init))
        func hasWord(_ w: String) -> Bool { words.contains(w) }

        let refuseWords = ["no", "nope", "decline", "deny", "cancel", "reject", "dismiss", "refuse"]
        if isNegated || refuseWords.contains(where: hasWord) {
            return MemoryAction(kind: "pressKey", key: "escape")
        }

        // Named keys.
        let keyNames = ["enter", "return", "escape", "esc", "tab", "space", "up", "down", "left", "right"]
        for k in keyNames where s.contains(k) {
            return MemoryAction(kind: "pressKey", key: (k == "return") ? "enter" : k)
        }
        // A single digit ("press 1", "option 2").
        if let digit = s.first(where: { $0.isNumber }) {
            return MemoryAction(kind: "pressKey", key: String(digit))
        }
        // Confirmation intent → the dialog's default key (Enter).
        let confirmWords = ["yes", "yeah", "yep", "trust", "accept", "confirm", "ok", "okay", "allow", "approve", "agree", "continue", "proceed"]
        if confirmWords.contains(where: hasWord) { return MemoryAction(kind: "pressKey", key: "enter") }
        return nil
    }

    // MARK: - Screen vision

    /// Look at the screen and answer. Prefers `claude -p` (free via the Claude Code subscription —
    /// the screenshot is read with the Read tool); falls back to OpenAI gpt-4o only when the claude
    /// binary is unavailable. This keeps routine screen-vision off the paid OpenAI bill.
    private static func describeScreen(question: String, settings: Settings,
                                       screenCapture: ScreenCapture,
                                       costGovernor: CostGovernor?) async -> String {
        guard let path = await screenCapture.capture() else {
            return "I couldn't capture the screen — Screen Recording permission may be off."
        }
        let binary = settings.claudeBinary
        if !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) {
            let prompt = """
            A screenshot of the user's current screen is saved at this PNG path. Read that file, \
            then answer concisely in one or two spoken sentences (no markdown, lists, or URLs): \
            \(question)
            \(path)
            """
            let result = await ClaudeProcessRunner.run(
                binary: binary, args: ["-p", "--model", settings.model, "--allowedTools", "Read"],
                prompt: prompt)
            // Accept the claude answer only if it actually looked at the image. If the Read tool
            // wasn't auto-approved (or it couldn't open the PNG) the CLI still returns a confident
            // "I can't see the image" — speaking that would be worse than the paid fallback, so we
            // fall through to OpenAI vision in that case.
            if result.ok, !result.output.isEmpty, !looksLikeVisionFailure(result.output) {
                return result.output
            }
            // fall through to OpenAI if the CLI failed/refused and a key exists
        }
        return await describeScreenOpenAI(question: question, path: path, settings: settings,
                                          costGovernor: costGovernor)
    }

    /// Heuristic: does a `claude -p` reply read like it never actually saw the screenshot? Used to
    /// decide whether to fall through to the OpenAI vision path instead of speaking a non-answer.
    private static func looksLikeVisionFailure(_ s: String) -> Bool {
        let l = s.lowercased()
        let markers = ["can't see", "cannot see", "can't view", "cannot view", "unable to see",
                       "unable to view", "couldn't read", "could not read", "can't read",
                       "cannot read", "don't have access", "do not have access", "not able to",
                       "unable to access", "can't access", "i don't see", "no image", "couldn't open",
                       "could not open", "unable to open", "permission to read"]
        return markers.contains { l.contains($0) }
    }

    /// OpenAI gpt-4o screen vision — the paid fallback used only when `claude -p` is unavailable.
    private static func describeScreenOpenAI(question: String, path: String, settings: Settings,
                                             costGovernor: CostGovernor?) async -> String {
        guard let imgData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "I couldn't read the captured screen."
        }
        // Budget gate: don't reach for the paid OpenAI vision API once the budget is spent (.free).
        guard costGovernor?.allowsPaidVision ?? true else {
            return "I can't look at the screen right now — we've hit the monthly budget, so paid vision is paused."
        }
        guard let key = settings.openAIAPIKey, !key.isEmpty else {
            return "I can't analyze the screen — the claude command wasn't found and no OpenAI key is set."
        }
        let instruction = "Looking at this screenshot, answer concisely in one or two spoken sentences: \(question)"
        guard let reply = await OpenAIVision.complete(
            imageData: imgData, instruction: instruction, apiKey: key, maxTokens: 300) else {
            return "I had trouble reading the screen."
        }
        // Meter this paid vision call against the monthly budget.
        costGovernor?.recordVision(usage: reply.usage)
        guard let text = reply.content else { return "I had trouble reading the screen." }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
