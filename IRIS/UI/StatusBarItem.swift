//
//  StatusBarItem.swift
//  IRIS — UI lane (Phase 1)
//
//  The menu-bar presence: an 👁 icon with a menu to toggle the floating overlay and
//  quit. Owns no app logic — exposes callbacks that Phase 2 (AppDelegate) wires up.
//

import AppKit

@MainActor
final class StatusBarItem: NSObject {

    /// Invoked when the user picks "Toggle IRIS".
    var onToggle: (() -> Void)?

    /// Invoked when the user picks "Quit IRIS". Defaults to terminating the app.
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "👁"
            button.toolTip = "IRIS"
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: "Toggle IRIS",
            action: #selector(handleToggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit IRIS",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func handleToggle() {
        onToggle?()
    }

    @objc private func handleQuit() {
        if let onQuit {
            onQuit()
        } else {
            NSApp.terminate(nil)
        }
    }
}
