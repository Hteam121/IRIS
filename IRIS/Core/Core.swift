//
//  Core.swift
//  IRIS — shared contract (Phase 0)
//
//  Everything the parallel Phase 1 lanes share lives here. Lanes DEPEND on these
//  types but MUST NOT edit this file after the Phase 0 barrier — it is frozen so
//  the UI / Voice / Vision lanes can develop in isolation without merge conflicts.
//

import Foundation
import Combine

/// The lifecycle state of an IRIS interaction. Drives the orb color/animation
/// (see docs/algorithms.md → Orb animation) and the mic-gating logic.
public enum IRISStatus: String, Sendable {
    case idle
    case listening
    case thinking
    case speaking
}

/// Shared, observable application state. Owned by `AppDelegate` (Phase 2) and read
/// by the UI lane. `@MainActor` because every mutation drives SwiftUI/AppKit views.
@MainActor
public final class AppState: ObservableObject {
    /// Current interaction phase; the orb observes this.
    @Published public var status: IRISStatus = .idle

    /// The latest assistant reply text (shown in the overlay, spoken by `Speaker`).
    @Published public var responseText: String = ""

    /// True while TTS is talking. The voice lane MUST NOT append audio buffers while
    /// this is true, so IRIS doesn't hear and transcribe its own speech (plan.md fix #5).
    @Published public var isSpeaking: Bool = false

    /// The text IRIS is currently speaking (empty when idle). Used by the wake detector's
    /// barge-in self-hearing filter to subtract IRIS's own voice from the recognizer.
    @Published public var spokenText: String = ""

    /// Live set of autonomous background agent tasks (run by the LangGraph sidecar).
    /// Rendered by the overlay/menu so multiple agents can be shown running in parallel.
    ///
    /// NOTE: additive Phase-0 exception — see docs/timeline/2026-06-24.md. Existing fields
    /// and their observers are untouched.
    @Published public var backgroundTasks: [AgentTask] = []

    /// Live caption of the realtime conversation (what IRIS is currently saying/heard).
    @Published public var transcript: String = ""

    public init() {}
}

/// The single entry point the rest of the app uses to get an answer from "the brain".
/// `IRISBrain` (Vision+AI lane) implements this with hybrid routing: Anthropic Messages
/// API when `ANTHROPIC_API_KEY` is set, otherwise `claude -p` via stdin. Transcripts
/// containing "iris agent" are routed to AgentMode inside the implementation.
///
/// - Parameters:
///   - transcript: the user's spoken command (wake phrase already stripped).
///   - screenshotPath: path to a temp PNG of the current screen, or nil if none.
/// - Returns: a concise, speakable reply.
public protocol IRISResponder: AnyObject, Sendable {
    func ask(transcript: String, screenshotPath: String?) async -> String
}
