//
//  Skills.swift
//  IRIS — capabilities as files (ported from OpenJarvis)
//
//  A skill is a markdown file in `~/.iris/skills/` with a minimal frontmatter header and a
//  step-by-step body. Skills are discovered at launch, advertised to the model as a compact
//  catalog (injected into the realtime instructions / classic prompt), and run through the
//  generic `run_skill` tool — inline skills hand their steps back to the model to execute
//  with its existing tools; agent skills become background sidecar tasks.
//
//  Frontmatter grammar (deliberately tiny — no YAML dependency; docs/algorithms.md → Skills):
//
//    ---
//    name: morning-briefing
//    description: Summarize the time and what's on today.
//    mode: inline            # inline (default) | agent
//    tools:                  # optional, informational
//      - get_datetime
//    ---
//    1. Step one...
//
//  Flat `key: value` lines plus `key:` followed by `- item` string lists. Anything after the
//  closing `---` is the skill body. Malformed files are skipped with a log line.
//

import Foundation

struct SkillManifest {
    enum Mode: String { case inline, agent }

    /// Identifier from the frontmatter (kebab-case or plain words).
    let name: String
    let description: String
    let mode: Mode
    /// Tools the steps reference — informational for now (shown in the catalog when present).
    let requiredTools: [String]
    /// The markdown body: the steps to follow / the agent task prompt.
    let steps: String

    /// The name as spoken ("morning-briefing" → "morning briefing"), lowercased.
    var spokenName: String {
        name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }
}

@MainActor
final class SkillManager {
    /// Catalog caps: keep the per-turn instruction overhead bounded
    /// (docs/algorithms.md → Skills).
    static let catalogMaxSkills = 20
    static let catalogMaxChars = 1500

    private(set) var skills: [SkillManifest] = []

    /// `~/.iris/skills`
    static var skillsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iris/skills", isDirectory: true)
    }

    /// Discover skills: seed bundled examples on first launch (directory missing), then scan
    /// `~/.iris/skills/*.md`.
    func load() {
        seedBundledSkillsIfNeeded()
        skills = Self.scan(directory: Self.skillsDirectory)
        IRISLog.log("skills: loaded \(skills.count) from \(Self.skillsDirectory.path)")
    }

    /// Case/punctuation-insensitive lookup ("Morning briefing", "morning-briefing", …).
    func skill(named raw: String) -> SkillManifest? {
        let wanted = Self.normalize(raw)
        guard !wanted.isEmpty else { return nil }
        return skills.first { Self.normalize($0.name) == wanted }
            ?? skills.first { Self.normalize($0.name).contains(wanted)
                || wanted.contains(Self.normalize($0.name)) }
    }

    /// Spoken skill names for deterministic intent matching.
    var spokenNames: [String] { skills.map(\.spokenName) }

    /// One-line-per-skill catalog for the system prompt; empty when there are no skills.
    func catalogBlock() -> String {
        guard !skills.isEmpty else { return "" }
        var lines = ["Skills you can run with the run_skill tool (pass the skill name):"]
        var count = 0
        for skill in skills.prefix(Self.catalogMaxSkills) {
            let line = "- \(skill.name): \(skill.description)"
            let projected = lines.joined(separator: "\n").count + line.count + 1
            if projected > Self.catalogMaxChars { break }
            lines.append(line)
            count += 1
        }
        let dropped = skills.count - count
        if dropped > 0 { lines.append("…and \(dropped) more.") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Discovery

    static func scan(directory: URL) -> [SkillManifest] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> SkillManifest? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                guard let manifest = parse(text) else {
                    IRISLog.log("skills: skipping \(url.lastPathComponent) — bad frontmatter")
                    return nil
                }
                return manifest
            }
    }

    /// First launch: copy the bundled example skills into `~/.iris/skills/` (only when the
    /// directory doesn't exist yet, so user deletions stick).
    private func seedBundledSkillsIfNeeded() {
        let fm = FileManager.default
        let dir = Self.skillsDirectory
        guard !fm.fileExists(atPath: dir.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Skills", isDirectory: true),
              let items = try? fm.contentsOfDirectory(at: bundled,
                                                      includingPropertiesForKeys: nil) else {
            return
        }
        for url in items where url.pathExtension.lowercased() == "md" {
            try? fm.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
        }
        IRISLog.log("skills: seeded bundled examples into \(dir.path)")
    }

    // MARK: - Frontmatter parsing

    /// Parse one skill file. Returns nil unless the file has a `---` frontmatter block with
    /// at least `name` and `description`, and a non-empty body.
    static func parse(_ text: String) -> SkillManifest? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var currentListKey: String?

        for raw in lines[1..<closing] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- "), let key = currentListKey {
                lists[key, default: []].append(String(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                currentListKey = key            // `key:` opens a `- item` list
            } else {
                currentListKey = nil
                fields[key] = value
            }
        }

        guard let name = fields["name"], !name.isEmpty,
              let description = fields["description"], !description.isEmpty else { return nil }
        let body = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        return SkillManifest(
            name: name,
            description: description,
            mode: fields["mode"].flatMap(SkillManifest.Mode.init(rawValue:)) ?? .inline,
            requiredTools: lists["tools"] ?? [],
            steps: body)
    }

    /// Lowercase, collapse separators, drop punctuation — for name matching.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }
}
