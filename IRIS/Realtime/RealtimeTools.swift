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
    static func schemas(computerUse: Bool) -> [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "name": name, "description": desc,
             "parameters": ["type": "object", "properties": props, "required": required]]
        }
        let str = ["type": "string"]
        var tools: [[String: Any]] = [
            tool("open_app", "Open or activate a macOS application by name.",
                 ["app_name": str], ["app_name"]),
            tool("open_folder", "Open a folder / the user's files in Finder.",
                 ["folder": ["type": "string", "description": "Folder path or spoken name (desktop, documents, a folder)."]], []),
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
        return tools
    }

    /// Execute a tool call and return a short result string for the model.
    static func run(name: String, args: [String: Any],
                    settings: Settings, agentManager: AgentManager?,
                    screenCapture: ScreenCapture) async -> String {
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
            return await TerminalLauncher.open(in: dir, claudeBinary: settings.claudeBinary,
                                               startClaude: startClaude)

        case "run_background_task":
            guard let task = s("task"), !task.isEmpty else { return "What should I work on?" }
            agentManager?.launch(kind: .agent, detail: task)
            return "On it — I'll work on that in the background and tell you when it's done."

        case "get_datetime":
            return LocalAnswers.answer(for: "what time and date is it") ?? "I'm not sure of the time."

        case "look_at_screen":
            return await describeScreen(question: s("question") ?? "What's on the screen?",
                                        settings: settings, screenCapture: screenCapture)

        case "type_text":
            return ComputerControl.typeText(s("text") ?? "")

        case "press_key":
            let mods = (args["modifiers"] as? [String]) ?? []
            return ComputerControl.pressKey(s("key") ?? "", modifiers: mods)

        case "click":
            let x = (args["x"] as? Double) ?? (args["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (args["y"] as? Double) ?? (args["y"] as? NSNumber)?.doubleValue ?? 0
            return ComputerControl.click(x: x, y: y)

        default:
            return "I don't have a way to do that yet."
        }
    }

    // MARK: - Screen vision (OpenAI gpt-4o)

    private static func describeScreen(question: String, settings: Settings,
                                       screenCapture: ScreenCapture) async -> String {
        guard let path = await screenCapture.capture(),
              let imgData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "I couldn't capture the screen — Screen Recording permission may be off."
        }
        guard let key = settings.openAIAPIKey, !key.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            return "I can't analyze the screen without an OpenAI key."
        }
        let b64 = imgData.base64EncodedString()
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 300,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "Looking at this screenshot, answer concisely in one or two spoken sentences: \(question)"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]],
                ],
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return "I couldn't analyze the screen."
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 30
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String else {
                return "I had trouble reading the screen."
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "I couldn't reach the network to read the screen."
        }
    }
}
