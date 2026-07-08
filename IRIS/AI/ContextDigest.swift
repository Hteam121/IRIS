//
//  ContextDigest.swift
//  IRIS — conversation memory with digest compaction
//
//  Keeps the prompt small on long conversations ("no context rot", ported from
//  isair/jarvis's digest passes): instead of resending every turn, history is one
//  short digest paragraph plus the last few verbatim turns. When the tail outgrows
//  the caps a fire-and-forget summarize pass (cheap model) folds older turns into
//  the digest. Also used to shrink long agent results before they're spoken/stored.
//

import Foundation

@MainActor
final class ConversationStore {
    // Tuned constants — see docs/algorithms.md → Context digest.
    static let verbatimTurns = 4            // turns resent verbatim after the digest
    static let digestAfterTurns = 8         // compact when more than this many turns are held
    static let digestAfterChars = 2_500     // …or when the held turns exceed this many chars
    static let staleAfterSeconds: TimeInterval = 120

    /// Rolling summary of everything older than the verbatim tail. Empty until first digest.
    private(set) var digest = ""
    /// Recent (role, content) turns, oldest first.
    private(set) var turns: [[String: String]] = []
    private var lastTurnAt = Date.distantPast
    private var digesting = false

    /// History to send with the next request: the digest (as a first user-note turn)
    /// plus the verbatim tail. Clears itself when the conversation has gone stale.
    func history() -> [[String: String]] {
        resetIfStale()
        var result: [[String: String]] = []
        if !digest.isEmpty {
            result.append(["role": "user",
                           "content": "(Summary of the conversation so far: \(digest))"])
        }
        result += turns.suffix(Self.verbatimTurns * 2)   // *2: a turn = user + assistant entry
        return result
    }

    func record(user: String, assistant: String) {
        resetIfStale()
        turns.append(["role": "user", "content": user])
        turns.append(["role": "assistant", "content": assistant])
        lastTurnAt = Date()
    }

    /// Compact older turns into the digest when the held history is too big. Fire-and-forget:
    /// the summarize call runs on a cheap model and the next request simply benefits.
    func digestIfNeeded(using engine: ClaudeEngine) {
        guard !digesting else { return }
        let totalChars = turns.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        guard turns.count > Self.digestAfterTurns * 2 || totalChars > Self.digestAfterChars else {
            return
        }
        // Everything except the verbatim tail gets folded into the digest.
        let tailCount = Self.verbatimTurns * 2
        let toFold = Array(turns.dropLast(tailCount))
        guard !toFold.isEmpty else { return }

        var text = digest.isEmpty ? "" : "Earlier summary: \(digest)\n\n"
        for turn in toFold {
            let who = (turn["role"] == "assistant") ? Persona.name : "User"
            text += "\(who): \(turn["content"] ?? "")\n"
        }
        digesting = true
        Task { @MainActor [weak self] in
            defer { self?.digesting = false }
            guard let summary = await engine.summarize(
                text, instruction: "Summarize this conversation in at most 3 sentences, keeping "
                    + "the user's goals, decisions made, and any open threads."),
                  let self else { return }
            self.digest = summary
            // Drop exactly what we folded (new turns may have arrived meanwhile).
            self.turns.removeFirst(min(toFold.count, self.turns.count))
            IRISLog.log("contextDigest: folded \(toFold.count / 2) turns into digest (\(summary.count) chars)")
        }
    }

    func clear() {
        digest = ""
        turns.removeAll()
    }

    private func resetIfStale() {
        if Date().timeIntervalSince(lastTurnAt) > Self.staleAfterSeconds { clear() }
    }
}
