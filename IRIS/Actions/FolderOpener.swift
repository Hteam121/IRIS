//
//  FolderOpener.swift
//  IRIS — Actions lane
//
//  Opens a folder in Finder (e.g. "open my files on the desktop"). Native NSWorkspace, instant.
//  Distinct from TerminalLauncher (which starts a `claude` session) — opening files should NOT
//  spin up a terminal.
//

import AppKit

@MainActor
enum FolderOpener {
    /// Open `path` (a directory) in Finder. Returns a short, speakable confirmation/error.
    static func open(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            return "I couldn't find that folder."
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        let name = (expanded as NSString).lastPathComponent
        return "I opened \(name) in Finder."
    }

    /// Create a NEW folder named `name` inside `parent` (a directory) and reveal it in Finder.
    /// Speakable confirmation/error. If it already exists, just reveals it.
    static func create(name: String, in parent: String) -> String {
        let expandedParent = (parent as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedParent, isDirectory: &isDir),
              isDir.boolValue else {
            return "I couldn't find where to put that folder."
        }
        // A spoken name can't contain path separators; keep it to a single folder.
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return "What should I name the folder?" }

        let target = (expandedParent as NSString).appendingPathComponent(safe)
        let whereName = (expandedParent as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: target) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
            return "There's already a folder called \(safe) on your \(whereName), so I opened it."
        }
        do {
            try FileManager.default.createDirectory(
                atPath: target, withIntermediateDirectories: true)
        } catch {
            return "I couldn't create the folder \(safe)."
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
        return "I created a folder called \(safe) on your \(whereName)."
    }
}
