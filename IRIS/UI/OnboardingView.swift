//
//  OnboardingView.swift
//  IRIS — guided permissions setup (Clicky-style)
//
//  One card per permission with a live ✅/⚠️ status, a plain-language "why", and a Grant
//  button that either fires the real prompt or deep-links the right System Settings pane.
//  Screen Recording additionally offers a relaunch (grants only apply to a new process).
//  Shown automatically on launch while anything required is missing; reachable any time
//  from the menu bar ("Setup & Permissions…").
//

import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up \(Persona.name)")
                .font(.title2).bold()
            Text("\(Persona.name) needs a few permissions to see, hear, and help. Grant each one below — the cards update live.")
                .font(.callout).foregroundColor(.secondary)

            card(granted: permissions.micGranted && permissions.speechGranted,
                 icon: "mic.fill", title: "Microphone & Speech Recognition",
                 why: "So \(Persona.name) can hear \"hey \(Persona.name.lowercased())\" and understand you. Recognition runs on-device.",
                 buttonTitle: "Grant") {
                permissions.requestMicAndSpeech()
            }

            card(granted: permissions.screenGranted,
                 icon: "rectangle.inset.filled.and.person.filled", title: "Screen Recording",
                 why: "So \(Persona.name) can look at your screen when you ask about it. Takes effect after a relaunch.",
                 buttonTitle: "Open Settings",
                 extraButton: permissions.screenGranted ? nil
                    : ("Relaunch \(Persona.name)", { permissions.relaunch() })) {
                permissions.requestScreenRecording()
            }

            card(granted: permissions.accessibilityGranted,
                 icon: "keyboard.fill", title: "Accessibility",
                 why: "For the hold-⌥Space push-to-talk hotkey anywhere, and to press keys for you when you've taught it to.",
                 buttonTitle: "Grant") {
                permissions.requestAccessibility()
            }

            card(granted: permissions.claudeFound,
                 icon: "terminal.fill", title: "Claude Code CLI",
                 why: permissions.claudeFound
                    ? "Found — background agent sessions and the free answering path are available."
                    : "Not found. Install Claude Code (https://claude.com/claude-code), or set an Anthropic API key in Settings instead.",
                 buttonTitle: nil) { }

            HStack {
                Text("Try it: hold ⌥Space and say hello, or say \"hey \(Persona.name.lowercased())\".")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.coreGranted)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    @ViewBuilder
    private func card(granted: Bool, icon: String, title: String, why: String,
                      buttonTitle: String?,
                      extraButton: (String, () -> Void)? = nil,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundColor(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(granted ? "✓" : "⚠️")
                        .font(.subheadline)
                        .foregroundColor(granted ? .green : .orange)
                }
                Text(why).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack {
                        if let buttonTitle {
                            Button(buttonTitle, action: action).controlSize(.small)
                        }
                        if let (extraTitle, extraAction) = extraButton {
                            Button(extraTitle, action: extraAction).controlSize(.small)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Reusable window hosting `OnboardingView`. Accessory app → activate before ordering front.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(permissions: PermissionsManager, onDone: @escaping () -> Void) {
        permissions.refresh()
        let view = OnboardingView(permissions: permissions) { [weak self] in
            onDone()
            self?.window?.close()
        }
        if window == nil {
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "Set up \(Persona.name)"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            window = win
        } else {
            window?.contentViewController = NSHostingController(rootView: view)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
