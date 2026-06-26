//
//  Memory.swift
//  IRIS — the persistent "brain"
//
//  A self-learning memory IRIS reads at the start of every exchange and writes to when it learns
//  something — analogous to how Claude Code uses `CLAUDE.md`. Two faces on disk:
//   - `~/.iris/memory.json` is the structured source of truth (reliable recall + rule triggering).
//   - `~/.iris/IRIS.md` is a human-readable mirror, regenerated on every save, that you can open
//     and edit like CLAUDE.md.
//
//  Memories come in three kinds: `preference` / `fact` (recalled into prompts) and `uiRule`
//  (a recognized on-screen situation → an action, applied reactively by ScreenRuleEngine).
//

import Foundation
import Combine

/// What a memory represents. `preference`/`fact` steer the model via the prompt; `uiRule` drives
/// reactive on-screen automation (e.g. "Claude Code trust-folder prompt → press Enter").
public enum MemoryKind: String, Codable, Sendable {
    case preference
    case fact
    case uiRule
}

/// How a memory was learned — `explicit` (the user taught it) or `inferred` (IRIS noticed it).
public enum MemorySource: String, Codable, Sendable {
    case explicit
    case inferred
}

/// A concrete action for a `uiRule`. Keystrokes are preferred (robust); a click falls back to
/// coordinates resolved at apply-time by the vision pass.
public struct MemoryAction: Codable, Sendable {
    public var kind: String          // "pressKey" | "type" | "click"
    public var key: String?          // pressKey: e.g. "enter", "1", "escape"
    public var modifiers: [String]?  // pressKey: e.g. ["command"]
    public var text: String?         // type: literal text to type
    public var x: Double?            // click: fixed coordinate (optional; usually resolved live)
    public var y: Double?

    public init(kind: String, key: String? = nil, modifiers: [String]? = nil,
                text: String? = nil, x: Double? = nil, y: Double? = nil) {
        self.kind = kind; self.key = key; self.modifiers = modifiers
        self.text = text; self.x = x; self.y = y
    }

    /// A short spoken-friendly description ("press Enter", "type 'yes'", "click").
    public var spokenDescription: String {
        switch kind {
        case "pressKey":
            let mods = (modifiers ?? []).joined(separator: "+")
            let k = key ?? "a key"
            return mods.isEmpty ? "press \(k)" : "press \(mods)+\(k)"
        case "type": return "type \"\(text ?? "")\""
        case "click": return "click the target"
        default: return kind
        }
    }
}

/// One unit of learned knowledge. `text` is always human-readable; `trigger`/`action` are set only
/// for `uiRule`s.
public struct MemoryItem: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: MemoryKind
    public var text: String
    public var trigger: String?
    public var action: MemoryAction?
    public var source: MemorySource
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(id: String = UUID().uuidString, kind: MemoryKind, text: String,
                trigger: String? = nil, action: MemoryAction? = nil,
                source: MemorySource, createdAt: Date = Date(),
                lastUsedAt: Date? = nil, useCount: Int = 0) {
        self.id = id; self.kind = kind; self.text = text
        self.trigger = trigger; self.action = action; self.source = source
        self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.useCount = useCount
    }
}

/// The single owner of the persisted brain. `@MainActor` because it's read/written from the
/// realtime tool dispatcher and AppDelegate, both on the main actor, and `@Published` so the
/// menu/overlay can surface it.
@MainActor
public final class MemoryStore: ObservableObject {
    @Published public private(set) var items: [MemoryItem] = []

    /// Hard cap so the prompt block / files never grow without bound (oldest, least-used pruned).
    private static let maxItems = 200

    private let fileURL: URL
    private let markdownURL: URL

    public init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iris", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("memory.json")
        self.markdownURL = dir.appendingPathComponent("IRIS.md")
    }

    // MARK: - Load / save

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Load `memory.json` if present (best-effort; a missing/corrupt file just starts empty).
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? Self.makeDecoder().decode([MemoryItem].self, from: data) {
            items = decoded
            IRISLog.log("memory: loaded \(items.count) item(s) from \(fileURL.path)")
        } else {
            IRISLog.log("memory: could not decode \(fileURL.path) — starting empty")
        }
    }

    /// Persist `memory.json` (source of truth) and regenerate the readable `IRIS.md` mirror.
    public func save() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Self.makeEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        try? renderMarkdown().data(using: .utf8)?.write(to: markdownURL, options: .atomic)
    }

    // MARK: - Mutations

    /// Add a memory, deduping against near-identical existing ones (bumps the existing item's use
    /// count instead). Returns true if a NEW item was stored. Persists on any change.
    @discardableResult
    public func add(text: String, kind: MemoryKind, source: MemorySource,
                    trigger: String? = nil, action: MemoryAction? = nil) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        // Dedup: same normalized text, or (for uiRules) same normalized trigger.
        let key = Self.normalize(clean)
        let trigKey = trigger.map(Self.normalize)
        if let idx = items.firstIndex(where: {
            Self.normalize($0.text) == key
                || (trigKey != nil && $0.trigger.map(Self.normalize) == trigKey)
        }) {
            items[idx].useCount += 1
            items[idx].lastUsedAt = Date()
            save()
            IRISLog.log("memory: deduped \"\(clean)\" (now \(items[idx].useCount) hits)")
            return false
        }

        items.append(MemoryItem(kind: kind, text: clean, trigger: trigger,
                                action: action, source: source))
        prune()
        save()
        IRISLog.log("memory: added [\(kind.rawValue)/\(source.rawValue)] \"\(clean)\"")
        return true
    }

    /// Remove the single best match for a free-text query ("forget that I like Chrome").
    /// Returns the removed item's text, or nil if nothing matched.
    @discardableResult
    public func remove(matching query: String) -> String? {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return nil }
        let qWords = Set(q.split(separator: " ").map(String.init))

        // Score each item and remove the single best CLEAR match. Exact text or a stored item that
        // CONTAINS the query is the strong signal; otherwise we require real word overlap (Jaccard).
        // We deliberately do NOT match merely because the stored text is a substring of the query —
        // that would delete unrelated short memories (e.g. "coffee" on "forget my 3pm coffee chat").
        func score(_ item: MemoryItem) -> Double {
            let t = Self.normalize(item.text)
            if t == q { return 1.0 }
            if t.contains(q) { return 0.8 }
            let tWords = Set(t.split(separator: " ").map(String.init))
            let union = qWords.union(tWords)
            guard !union.isEmpty else { return 0 }
            return Double(qWords.intersection(tWords).count) / Double(union.count)
        }

        if let best = items.indices.max(by: { score(items[$0]) < score(items[$1]) }),
           score(items[best]) >= 0.4 {
            let removed = items.remove(at: best)
            save()
            IRISLog.log("memory: forgot \"\(removed.text)\"")
            return removed.text
        }
        // Generic "forget that / this / it" with no describable target → drop the most recent.
        if ["that", "this", "the last one", "it"].contains(q), let last = items.indices.last {
            let removed = items.remove(at: last)
            save()
            IRISLog.log("memory: forgot \"\(removed.text)\"")
            return removed.text
        }
        return nil
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        items.removeAll()
        save()
    }

    /// Mark a memory as just-applied (bumps recency + use count). Used by ScreenRuleEngine.
    public func touch(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].useCount += 1
        items[idx].lastUsedAt = Date()
        save()
    }

    // MARK: - Recall

    /// The `uiRule`s the reactive engine matches against, most-used first.
    public var uiRules: [MemoryItem] {
        items.filter { $0.kind == .uiRule }
            .sorted { $0.useCount > $1.useCount }
    }

    /// A compact text block injected into the model's instructions so it applies what it has
    /// learned without being asked. Empty when there's nothing to recall.
    public func promptBlock(limit: Int = 40) -> String {
        guard !items.isEmpty else { return "" }
        // Most-used / most-recent first, then cap.
        let ranked = items.sorted {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }.prefix(limit)

        var lines: [String] = []
        for item in ranked {
            if item.kind == .uiRule, let trigger = item.trigger, let action = item.action {
                lines.append("- When you see: \(trigger) → \(action.spokenDescription).")
            } else {
                lines.append("- \(item.text)")
            }
        }
        return """
        What you've learned about this user — apply it proactively, without being asked:
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!,?"))
    }

    /// Drop the lowest-value items once over the cap (least used, then oldest).
    private func prune() {
        guard items.count > Self.maxItems else { return }
        items.sort {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
        items = Array(items.prefix(Self.maxItems))
    }

    private func renderMarkdown() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        func section(_ title: String, _ kinds: Set<MemoryKind>) -> String? {
            let group = items.filter { kinds.contains($0.kind) }
            guard !group.isEmpty else { return nil }
            var out = "## \(title)\n\n"
            for item in group {
                if item.kind == .uiRule, let trigger = item.trigger, let action = item.action {
                    out += "- **When:** \(trigger) → **Do:** \(action.spokenDescription)"
                } else {
                    out += "- \(item.text)"
                }
                out += "  _(\(item.source.rawValue), used \(item.useCount)×, \(f.string(from: item.createdAt)))_\n"
            }
            return out
        }
        let header = """
        # IRIS — Learned Memory

        This file is auto-generated from `~/.iris/memory.json` (the source of truth). Edits here are
        overwritten on the next save — change `memory.json` to make lasting edits, or just tell IRIS.

        """
        let sections = [
            section("Preferences", [.preference]),
            section("Facts", [.fact]),
            section("Screen rules", [.uiRule]),
        ].compactMap { $0 }
        if sections.isEmpty { return header + "\n_(nothing learned yet)_\n" }
        return header + "\n" + sections.joined(separator: "\n")
    }
}
