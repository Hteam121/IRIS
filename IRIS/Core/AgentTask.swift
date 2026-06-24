//
//  AgentTask.swift
//  IRIS — Core (Phase 0 additive)
//
//  The model for a single autonomous background agent task, mirrored from the Python
//  sidecar's TaskEvent (sidecar/iris_agents/models.py). `AppState.backgroundTasks`
//  (Core.swift) holds the live set; the overlay/menu render it. `id` is the sidecar's
//  task id (a 32-char hex string), so it is a String — not a UUID — to map directly.
//
//  NB: named `AgentTask` (not `BackgroundTask`) to avoid a clash with SwiftUI's own
//  `BackgroundTask` type in files that `import SwiftUI`.
//

import Foundation

/// Lifecycle of one background task. Matches the sidecar's `TaskState`.
public enum AgentTaskState: String, Sendable, Codable {
    case queued, running, succeeded, failed, cancelled

    /// True once the task has reached a terminal state.
    public var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }
}

/// What the agent is doing. Matches the sidecar's `TaskKind`.
public enum AgentTaskKind: String, Sendable, Codable {
    case calendar, web, agent, terminal
}

/// A single background agent task surfaced in the UI.
public struct AgentTask: Identifiable, Sendable, Equatable {
    /// The sidecar task id (hex string).
    public let id: String
    public var kind: AgentTaskKind
    public var title: String
    public var detail: String
    public var state: AgentTaskState
    public let startedAt: Date
    public var finishedAt: Date?
    /// Spoken one-liner produced when the task finishes.
    public var resultSummary: String?

    public init(
        id: String,
        kind: AgentTaskKind,
        title: String,
        detail: String,
        state: AgentTaskState,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        resultSummary: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resultSummary = resultSummary
    }
}
