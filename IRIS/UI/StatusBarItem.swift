//
//  StatusBarItem.swift
//  IRIS — UI lane (Phase 1)
//
//  The menu-bar presence: an 👁 icon with a menu to toggle the floating overlay, interrupt,
//  open settings, quit, and cancel running background agents. Owns no app logic — exposes
//  callbacks that Phase 2 (AppDelegate) wires up. AppDelegate calls `refresh(tasks:)` when
//  the set of background tasks changes so the "Active agents" section stays current.
//

import AppKit

@MainActor
final class StatusBarItem: NSObject {

    /// Invoked when the user picks "Toggle IRIS".
    var onToggle: (() -> Void)?

    /// Invoked when the user picks "Settings…".
    var onSettings: (() -> Void)?

    /// Invoked when the user picks "Interrupt IRIS" (stop thinking/speaking now).
    var onInterrupt: (() -> Void)?

    /// Invoked when the user picks "Quit IRIS". Defaults to terminating the app.
    var onQuit: (() -> Void)?

    /// Invoked with a background task id when the user picks "Cancel" under Active agents.
    var onCancelAgent: ((String) -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "👁"
            button.toolTip = "IRIS"
        }

        statusItem.menu = menu
        rebuild(tasks: [])
    }

    /// Rebuild the menu so the Active-agents section reflects the current tasks.
    func refresh(tasks: [AgentTask]) {
        rebuild(tasks: tasks)
    }

    private func rebuild(tasks: [AgentTask]) {
        menu.removeAllItems()

        addItem("Toggle IRIS", #selector(handleToggle))
        addItem("Interrupt IRIS", #selector(handleInterrupt), key: ".")

        // Active background agents, each cancellable.
        let active = tasks.filter { !$0.state.isFinished }
        if !active.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Active agents", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for task in active {
                let item = NSMenuItem(
                    title: "  ⏹  \(task.title)",
                    action: #selector(handleCancelAgent(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = task.id
                item.toolTip = "Cancel this agent"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addItem("Settings…", #selector(handleSettings), key: ",")
        menu.addItem(.separator())
        addItem("Quit IRIS", #selector(handleQuit), key: "q")
    }

    private func addItem(_ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func handleToggle() { onToggle?() }
    @objc private func handleInterrupt() { onInterrupt?() }
    @objc private func handleSettings() { onSettings?() }

    @objc private func handleCancelAgent(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onCancelAgent?(id) }
    }

    @objc private func handleQuit() {
        if let onQuit {
            onQuit()
        } else {
            NSApp.terminate(nil)
        }
    }
}
