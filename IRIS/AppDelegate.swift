//
//  AppDelegate.swift
//  IRIS — bootstrap
//
//  Thin lifecycle shell: creates the shared AppState, the CompanionManager (which owns
//  the entire voice/AI pipeline — see Core/CompanionManager.swift), and the UI chrome
//  (floating panel, menu-bar item, settings window), then forwards lifecycle events.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let appState = AppState()
    private var companion: CompanionManager!

    private var panel: FloatingPanel?
    private var statusBarItem: StatusBarItem?
    private let settingsWindowController = SettingsWindowController()
    private let onboardingWindowController = OnboardingWindowController()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory: no dock icon, doesn't take over the active app.
        NSApp.setActivationPolicy(.accessory)

        companion = CompanionManager(appState: appState)

        // Floating overlay: cursor-following buddy (default) or the notch island.
        let panel = FloatingPanel(appState: appState,
                                  buddyMode: companion.settings.uiMode != "notch")
        self.panel = panel
        panel.show()

        // Menu-bar 👁: toggle the overlay / interrupt / settings / quit.
        let statusBarItem = StatusBarItem()
        statusBarItem.onToggle = { [weak panel] in panel?.toggle() }
        statusBarItem.onSettings = { [weak self] in self?.showSettings() }
        statusBarItem.onSetup = { [weak self] in self?.showOnboarding() }
        statusBarItem.onInterrupt = { [weak self] in self?.companion.handleInterruptRequest() }
        statusBarItem.onCancelAgent = { [weak self] id in self?.companion.cancelSession(id) }
        statusBarItem.onQuit = { NSApp.terminate(nil) }
        self.statusBarItem = statusBarItem

        // Keep the menu-bar "Active agents" section in sync with the live task set.
        appState.$backgroundTasks
            .receive(on: DispatchQueue.main)
            .sink { [weak statusBarItem] tasks in statusBarItem?.refresh(tasks: tasks) }
            .store(in: &cancellables)

        companion.start()

        // First launch (or a required permission missing) → guided setup window.
        if companion.permissions.needsOnboarding {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        onboardingWindowController.show(permissions: companion.permissions) { [weak self] in
            guard let self else { return }
            self.companion.permissions.markOnboarded()
            self.companion.retryStartListening()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companion?.shutdown()
        panel?.hide()
    }

    // Accessory app with no standard windows — never quit just because a window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Settings window

    private func showSettings() {
        settingsWindowController.show(settings: companion.settings) { [weak self] form in
            guard let self else { return }
            let new = self.companion.settings.applying(form)
            do {
                try new.save()
            } catch {
                NSLog("[IRIS] failed to save settings: \(error.localizedDescription)")
            }
            self.companion.applySettings(new)
        }
    }
}
