//
//  AgentMode.swift
//  IRIS — Vision + AI lane (Phase 1)
//
//  Handles "iris agent <task>" commands by spawning the `claude` CLI to actually
//  perform the task on the user's Mac, then returns a one-sentence spoken summary.
//
//  Security note: this runs claude with tool access enabled so it can complete real
//  tasks (create files, run commands). It is intentionally gated behind explicit
//  voice intent ("iris agent ...") and the app already runs unsandboxed (plan.md
//  fix #3) to spawn subprocesses. The prompt is fed via stdin (plan.md fix #2).
//

import Foundation

public final class AgentMode: Sendable {
    private let settings: Settings

    /// Trigger phrase that routes a transcript here; also stripped to form the task.
    static let trigger = "iris agent"

    static let agentSystemPrompt = """
    You are IRIS in agent mode, operating on the user's Mac. Carry out the task below \
    using the tools available to you. When finished, reply with a single concise sentence \
    summarizing what you did — it will be spoken aloud, so use plain prose with no markdown, \
    lists, or code fences.
    """

    public init(settings: Settings) {
        self.settings = settings
    }

    /// Run the agentic task contained in `transcript` and return a speakable summary. `memory` is a
    /// precomputed block of learned facts/preferences (from `MemoryStore`) so the agent applies
    /// what IRIS has learned; empty when memory is off or there's nothing to recall.
    public func run(transcript: String, memory: String = "") async -> String {
        let task = Self.extractTask(from: transcript)
        guard !task.isEmpty else {
            return "What would you like the agent to do?"
        }

        let binary = settings.claudeBinary
        guard !binary.isEmpty, FileManager.default.isExecutableFile(atPath: binary) else {
            return "Agent mode needs the Claude command, which I couldn't find."
        }

        let prompt = """
        \(Self.agentSystemPrompt)\(memory.isEmpty ? "" : "\n\n" + memory)

        Task: \(task)
        """

        // Print mode, with permissions bypassed so the agent can run unattended; this
        // is the agentic path the user explicitly asked for by saying "iris agent".
        let args = ["-p", "--model", settings.model, "--dangerously-skip-permissions"]

        let result = await ClaudeProcessRunner.run(binary: binary, args: args, prompt: prompt)
        if result.ok, !result.output.isEmpty {
            return result.output
        }
        if !result.output.isEmpty {
            return result.output
        }
        return "I tried to run that task but didn't get a result back."
    }

    // MARK: - Task extraction

    /// Strip everything up to and including the trigger phrase, returning the task text.
    /// e.g. "Hey IRIS, iris agent create a hello.txt file" → "create a hello.txt file".
    static func extractTask(from transcript: String) -> String {
        let lower = transcript.lowercased()
        guard let range = lower.range(of: trigger) else {
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
}
