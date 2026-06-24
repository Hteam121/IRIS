//
//  SettingsView.swift
//  IRIS — UI lane
//
//  The menu-bar "Settings…" window: secure entry for the Anthropic and OpenAI API keys
//  plus the model id. On Save it hands the new values back to AppDelegate, which writes
//  them to ~/.iris/config.json (outside the repo) and live-applies them without a restart.
//

import AppKit
import SwiftUI

// This file imports SwiftUI, which defines its own `Settings` scene type that would clash
// with our config struct of the same name. We therefore refer to the config exclusively by
// its unambiguous alias `IRISSettings` (declared in Settings.swift) throughout this file.

struct SettingsView: View {
    @State private var anthropicKey: String
    @State private var openAIKey: String
    @State private var model: String
    @State private var savedNote = false

    /// Invoked with the entered (anthropic, openAI, model) values when the user taps Save.
    let onSave: (_ anthropic: String, _ openAI: String, _ model: String) -> Void

    init(settings: IRISSettings,
         onSave: @escaping (String, String, String) -> Void) {
        _anthropicKey = State(initialValue: settings.anthropicAPIKey ?? "")
        _openAIKey = State(initialValue: settings.openAIAPIKey ?? "")
        _model = State(initialValue: settings.model)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("IRIS Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic API Key")
                    .font(.subheadline).foregroundColor(.secondary)
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used for screen-vision answers via the Messages API. Leave blank to use the claude CLI.")
                    .font(.caption).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI API Key")
                    .font(.subheadline).foregroundColor(.secondary)
                SecureField("sk-…", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used to decide what to do with each command (open an app, run an agent, or answer). Optional.")
                    .font(.caption).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.subheadline).foregroundColor(.secondary)
                TextField(IRISSettings.defaultModel, text: $model)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if savedNote {
                    Text("Saved.")
                        .font(.caption).foregroundColor(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button("Save") {
                    onSave(anthropicKey, openAIKey, model)
                    withAnimation { savedNote = true }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Lazily-built, reusable window that hosts `SettingsView`. The app is an `.accessory`
/// (no dock icon), so we activate the app before ordering the window front or it would
/// open behind whatever app is in focus.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: IRISSettings,
              onSave: @escaping (String, String, String) -> Void) {
        if window == nil {
            let view = SettingsView(settings: settings, onSave: onSave)
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "IRIS Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            window = win
        } else {
            // Re-seed the view with the latest settings on each open.
            let view = SettingsView(settings: settings, onSave: onSave)
            window?.contentViewController = NSHostingController(rootView: view)
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
