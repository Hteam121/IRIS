//
//  WebSearch.swift
//  IRIS — Actions lane
//
//  Opens a web search in the browser (e.g. "search for XM5 deals", "open Chrome and look up X").
//  Native NSWorkspace — opens the default browser, or a named one (Chrome/Safari/Firefox), at the
//  Google results page for the query.
//

import AppKit

@MainActor
enum WebSearch {
    /// Browser spoken-name → bundle id for the few common browsers.
    private static let browserBundleIDs: [String: String] = [
        "chrome": "com.google.Chrome",
        "google chrome": "com.google.Chrome",
        "safari": "com.apple.Safari",
        "firefox": "org.mozilla.firefox",
        "edge": "com.microsoft.edgemac",
        "arc": "company.thebrowser.Browser",
        "brave": "com.brave.Browser",
    ]

    /// Open the search results for `query`, in `browser` if named (else the default browser).
    static func open(query: String, browser: String?) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What should I search for?" }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            return "I couldn't build that search."
        }

        let ws = NSWorkspace.shared
        if let browser,
           let bid = browserBundleIDs[browser.lowercased()],
           let appURL = ws.urlForApplication(withBundleIdentifier: bid) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            ws.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            ws.open(url)
        }
        return "Searching the web for \(trimmed)."
    }
}
