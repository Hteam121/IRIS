//
//  PermissionsManager.swift
//  IRIS — permission status + onboarding gate
//
//  Live TCC permission statuses for the onboarding window (Clicky-style guided setup):
//  each permission has a check, a way to request it (real prompt where macOS allows,
//  else a deep link into System Settings), and a 1s poll while the window is visible so
//  cards flip to ✅ the moment the user grants access. Screen Recording only takes
//  effect after a relaunch — the card offers one.
//

import AppKit
import AVFoundation
import Speech
import Combine

@MainActor
final class PermissionsManager: ObservableObject {

    @Published var micGranted = false
    @Published var speechGranted = false
    @Published var screenGranted = false
    @Published var accessibilityGranted = false
    @Published var claudeFound = false

    private var pollTimer: Timer?

    /// The flag file marking that the user completed onboarding once.
    private static var onboardedFlag: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iris/onboarded")
    }

    init() { refresh() }

    /// Everything the voice pipeline needs to work at all.
    var coreGranted: Bool { micGranted && speechGranted }

    /// Show onboarding when the user never finished it or a required permission is missing.
    var needsOnboarding: Bool {
        !FileManager.default.fileExists(atPath: Self.onboardedFlag.path)
            || !coreGranted || !screenGranted
    }

    func markOnboarded() {
        try? Data().write(to: Self.onboardedFlag)
    }

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        claudeFound = !Settings.resolveClaudeBinary().isEmpty
    }

    /// Poll while the onboarding window is visible so statuses flip live.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Requests / deep links

    func requestMicAndSpeech() {
        SFSpeechRecognizer.requestAuthorization { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    func requestScreenRecording() {
        // Adds the app to the Screen Recording list and prompts; the user may still need
        // to toggle it manually. Deep-link there as well so the pane is one click away.
        DispatchQueue.global(qos: .utility).async { _ = CGRequestScreenCaptureAccess() }
        openPane("Privacy_ScreenCapture")
    }

    func requestAccessibility() {
        _ = ComputerControl.ensureAccessibility(prompt: true)
        openPane("Privacy_Accessibility")
    }

    private func openPane(_ pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunch the app (Screen Recording grants only apply to a fresh process).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
