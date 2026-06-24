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
}
