//
//  AppDelegate.swift
//  IRIS — Integration (Phase 2, solo)
//
//  Owns the app lifecycle and wires every Phase 1 lane together:
//    WakeWordDetector.onWakeWordDetected → ScreenCapture.capture → IRISBrain.ask → Speaker.speak,
//  driving the shared `AppState` (which the UI lane's orb/overlay observe) on the main actor.
//
//  Per plan.md Phase 2, this is the single integration file; the feature lanes are untouched.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Shared contract + config (Phase 0).
    private let appState = AppState()
    private let settings = Settings.load()

    // Components (Phase 1 lanes), retained for the app's lifetime.
    private var panel: FloatingPanel?
    private var statusBarItem: StatusBarItem?
    private var wakeWord: WakeWordDetector?
    private var speaker: Speaker?
    private let screenCapture = ScreenCapture()
    private var brain: IRISResponder?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory: no dock icon, doesn't take over the active app.
        NSApp.setActivationPolicy(.accessory)

        // The brain (hybrid CLI/API routing) implements the IRISResponder contract.
        brain = IRISBrain(settings: settings)

        // Floating orb overlay, shown near the cursor and tracking it.
        let panel = FloatingPanel(appState: appState)
        self.panel = panel
        panel.show()

        // Text-to-speech. When speech finishes, return to idle and resume listening.
        let speaker = Speaker(settings: settings, appState: appState)
        speaker.onFinished = { [weak self] in self?.appState.status = .idle }
        self.speaker = speaker

        // Menu-bar 👁: toggle the overlay / quit.
        let statusBarItem = StatusBarItem()
        statusBarItem.onToggle = { [weak panel] in panel?.toggle() }
        statusBarItem.onQuit = { NSApp.terminate(nil) }
        self.statusBarItem = statusBarItem

        // Wake-word listener → command handler.
        let wake = WakeWordDetector(settings: settings, appState: appState)
        wake.onWakeWordDetected = { [weak self] command in
            self?.handleCommand(command)
        }
        self.wakeWord = wake

        // Request Mic + Speech access, then start listening. (Screen Recording is granted
        // lazily on the first capture; it can't be requested programmatically.)
        WakeWordDetector.requestAuthorization { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSLog("[IRIS] mic + speech authorization granted: \(granted)")
                if granted {
                    self.wakeWord?.start()
                } else {
                    self.appState.responseText =
                        "I need Microphone and Speech Recognition access to listen. Enable them in System Settings → Privacy & Security."
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeWord?.stop()
        speaker?.stop()
        panel?.hide()
    }

    // Accessory app with no standard windows — never quit just because a window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Command pipeline

    /// capture → ask → speak, updating `AppState` at each step on the main actor.
    private func handleCommand(_ command: String) {
        appState.status = .thinking
        appState.responseText = ""

        Task { @MainActor in
            let screenshotPath = await screenCapture.capture()
            let reply = await brain?.ask(transcript: command, screenshotPath: screenshotPath)
                ?? IRISBrain.genericError
            appState.responseText = reply
            // Speaker sets status → .speaking and returns it to .idle when done.
            speaker?.speak(reply)
        }
    }
}
