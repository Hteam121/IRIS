//
//  AppLauncher.swift
//  IRIS — Actions lane
//
//  Direct macOS app launching via NSWorkspace. Used for simple "open <app>" commands so
//  IRIS can act instantly without spawning an agent. The IntentRouter routes open-app
//  intents here; complex multi-step tasks still go through AgentMode (the claude agent).
//

import AppKit

@MainActor
enum AppLauncher {

    /// Common spoken names → bundle identifiers. Speech recognition tends to produce these
    /// lowercased forms; extend freely. Unknown names fall back to an on-disk lookup.
    static let aliases: [String: String] = [
        "safari": "com.apple.Safari",
        "chrome": "com.google.Chrome",
        "google chrome": "com.google.Chrome",
        "firefox": "org.mozilla.firefox",
        "spotify": "com.spotify.client",
        "vs code": "com.microsoft.VSCode",
        "vscode": "com.microsoft.VSCode",
        "visual studio code": "com.microsoft.VSCode",
        "code": "com.microsoft.VSCode",
        "terminal": "com.apple.Terminal",
        "iterm": "com.googlecode.iterm2",
        "notes": "com.apple.Notes",
        "messages": "com.apple.MobileSMS",
        "mail": "com.apple.mail",
        "calendar": "com.apple.iCal",
        "finder": "com.apple.finder",
        "music": "com.apple.Music",
        "photos": "com.apple.Photos",
        "system settings": "com.apple.systempreferences",
        "system preferences": "com.apple.systempreferences",
        "slack": "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.Discord",
        "zoom": "us.zoom.xos",
        "notion": "notion.id",
        "preview": "com.apple.Preview",
        "reminders": "com.apple.reminders",
        "maps": "com.apple.Maps",
    ]

    /// Open/activate the named app. Returns a short, speakable confirmation or error.
    static func open(appName raw: String) async -> String {
        let name = raw.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: " ,.!?").union(.whitespacesAndNewlines))
        guard !name.isEmpty else { return "Which app should I open?" }

        let ws = NSWorkspace.shared

        // 1) Alias → bundle id (also try the space-stripped form, e.g. "vscode").
        if let bid = aliases[name] ?? aliases[name.replacingOccurrences(of: " ", with: "")],
           let url = ws.urlForApplication(withBundleIdentifier: bid) {
            return await launch(url, display: displayName(raw))
        }

        // 2) Fuzzy: look for "<Name>.app" in the standard application directories.
        if let url = locateByDisplayName(name) {
            return await launch(url, display: displayName(raw))
        }

        return "I couldn't find an app called \(displayName(raw))."
    }

    // MARK: - Helpers

    private static func displayName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?").union(.whitespacesAndNewlines))
    }

    private static func locateByDisplayName(_ name: String) -> URL? {
        let fm = FileManager.default
        let dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        // Try the spoken form and a Title-Cased variant ("vs code" → "Vs Code").
        let titleCased = name.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        let candidates = Set([name, name.capitalized, titleCased])
        for dir in dirs {
            for c in candidates {
                let path = "\(dir)/\(c).app"
                if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    private static func launch(_ url: URL, display: String) async -> String {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return "Opening \(display)."
        } catch {
            return "I couldn't open \(display)."
        }
    }
}
