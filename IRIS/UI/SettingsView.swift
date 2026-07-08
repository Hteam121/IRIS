//
//  SettingsView.swift
//  IRIS — UI lane
//
//  The menu-bar "Settings…" window: API keys, model, budget, wake phrase, voice, and the
//  local-model toggle. On Save it hands an `IRISSettings.Form` back to AppDelegate, which
//  writes it to ~/.iris/config.json (outside the repo) and live-applies without a restart.
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
    @State private var budget: String
    @State private var wakePhrase: String
    @State private var ttsVoice: String
    @State private var localLLMEnabled: Bool
    @State private var savedNote = false

    /// Invoked with the edited form values when the user taps Save.
    let onSave: (IRISSettings.Form) -> Void

    init(settings: IRISSettings, onSave: @escaping (IRISSettings.Form) -> Void) {
        _anthropicKey = State(initialValue: settings.anthropicAPIKey ?? "")
        _openAIKey = State(initialValue: settings.openAIAPIKey ?? "")
        _model = State(initialValue: settings.model)
        // Render an integer budget without a trailing ".0".
        let b = settings.monthlyBudgetUSD
        _budget = State(initialValue: b == b.rounded() ? String(Int(b)) : String(b))
        _wakePhrase = State(initialValue: settings.wakePhrase)
        _ttsVoice = State(initialValue: settings.ttsVoice)
        _localLLMEnabled = State(initialValue: settings.localLLMEnabled)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(Persona.name) Settings")
                .font(.headline)

            field("Anthropic API Key",
                  caption: "Streaming answers + vision via the Messages API (with prompt caching). Leave blank to use the claude CLI (free with a subscription).") {
                SecureField("sk-ant-…", text: $anthropicKey).textFieldStyle(.roundedBorder)
            }

            field("OpenAI API Key",
                  caption: "Only used for the natural neural voice (gpt-4o-mini-tts). Optional — without it \(Persona.name) uses the built-in macOS voice.") {
                SecureField("sk-…", text: $openAIKey).textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 12) {
                field("Model", caption: nil) {
                    TextField(IRISSettings.defaultModel, text: $model)
                        .textFieldStyle(.roundedBorder)
                }
                field("Monthly budget (USD)", caption: nil) {
                    TextField("20", text: $budget).textFieldStyle(.roundedBorder)
                }
            }
            Text("\(Persona.name) meters voice + API spend against the budget and falls back to the free claude pipeline and on-device voice as it runs low. 0 = unlimited.")
                .font(.caption).foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 12) {
                field("Wake phrase", caption: nil) {
                    TextField(IRISSettings.defaultWakePhrase, text: $wakePhrase)
                        .textFieldStyle(.roundedBorder)
                }
                field("Voice", caption: nil) {
                    TextField(IRISSettings.defaultTTSVoice, text: $ttsVoice)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("Voice is an OpenAI TTS voice: alloy, ash, coral, echo, fable, nova, onyx, sage, or shimmer. Push-to-talk is hold ⌥Space.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Answer simple questions with a free local model first (Ollama / Apple Intelligence)",
                   isOn: $localLLMEnabled)
                .font(.subheadline)

            HStack {
                if savedNote {
                    Text("Saved.")
                        .font(.caption).foregroundColor(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button("Save") {
                    onSave(IRISSettings.Form(
                        anthropicKey: anthropicKey, openAIKey: openAIKey, model: model,
                        budget: budget, wakePhrase: wakePhrase, ttsVoice: ttsVoice,
                        localLLMEnabled: localLLMEnabled))
                    withAnimation { savedNote = true }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func field(_ title: String, caption: String?,
                       @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            content()
            if let caption {
                Text(caption).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lazily-built, reusable window that hosts `SettingsView`. The app is an `.accessory`
/// (no dock icon), so we activate the app before ordering the window front or it would
/// open behind whatever app is in focus.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: IRISSettings, onSave: @escaping (IRISSettings.Form) -> Void) {
        let view = SettingsView(settings: settings, onSave: onSave)
        if window == nil {
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "\(Persona.name) Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            window = win
        } else {
            // Re-seed the view with the latest settings on each open.
            window?.contentViewController = NSHostingController(rootView: view)
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
