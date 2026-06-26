//
//  TerminalLauncher.swift
//  IRIS — Actions lane
//
//  Opens the macOS Terminal and starts a `claude` Code session in a directory, via
//  AppleScript (`osascript`). Native (not delegated to the sidecar) so the Automation
//  TCC prompt is attributed to IRIS. The directory is shell-quoted to prevent injection
//  from a misheard path.
//
//  First use triggers a one-time "IRIS wants to control Terminal" prompt (System Settings
//  → Privacy & Security → Automation). It can't be granted programmatically.
//

import Foundation

@MainActor
enum TerminalLauncher {

    /// Open Terminal in `directory`, optionally starting a `claude` session. Speakable result.
    /// When `skipPermissions` is true, claude starts with `--dangerously-skip-permissions` (the
    /// "trust this folder?" prompt is skipped); set it false so that prompt appears and IRIS can
    /// learn to handle it reactively (ScreenRuleEngine).
    static func open(in directory: String, claudeBinary: String,
                     startClaude: Bool, skipPermissions: Bool = true) async -> String {
        let expanded = (directory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        let targetDir = (exists && isDir.boolValue)
            ? expanded
            : FileManager.default.homeDirectoryForCurrentUser.path

        let claude = claudeBinary.isEmpty ? "claude" : claudeBinary
        let claudeCmd = skipPermissions
            ? "\(shQuote(claude)) --dangerously-skip-permissions"
            : shQuote(claude)
        let shellCmd = startClaude
            ? "cd \(shQuote(targetDir)) && \(claudeCmd)"
            : "cd \(shQuote(targetDir))"
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(shellCmd))"
        end tell
        """
        return await run(appleScript: appleScript, dirName: targetDir, startedClaude: startClaude)
    }

    // MARK: - Helpers

    /// POSIX single-quote a string so the shell treats it literally.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for embedding inside an AppleScript double-quoted string literal.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(appleScript: String, dirName: String, startedClaude: Bool) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", appleScript]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                } catch {
                    cont.resume(returning: "I couldn't open Terminal.")
                    return
                }
                let short = (dirName as NSString).lastPathComponent
                if p.terminationStatus == 0 {
                    cont.resume(returning: startedClaude
                        ? "I opened a terminal and started Claude in \(short)."
                        : "I opened a terminal in \(short).")
                } else {
                    cont.resume(returning:
                        "I couldn't open Terminal — check Automation permissions in System Settings.")
                }
            }
        }
    }
}
