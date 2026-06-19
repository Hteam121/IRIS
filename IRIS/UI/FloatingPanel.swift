//
//  FloatingPanel.swift
//  IRIS — UI lane
//
//  A borderless, non-activating, always-on-top panel that anchors a notch "island" to the
//  top center of the screen (over the camera). Transparent and click-through so it never
//  steals focus or blocks the menu bar. Re-anchors when the screen layout changes.
//

import AppKit
import SwiftUI

@MainActor
final class FloatingPanel: NSPanel {

    /// Generous transparent canvas; the black island sizes itself within and is centered
    /// on the notch. Click-through means the empty area never blocks anything.
    static let panelSize = NSSize(width: 720, height: 320)

    private let appState: AppState
    private var hostingView: NSHostingView<OverlayView>?

    init(appState: AppState) {
        self.appState = appState
        super.init(
            contentRect: NSRect(origin: .zero, size: FloatingPanel.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating above the menu bar (so the island can merge with the notch), all-spaces,
        // transparent, and non-disruptive.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // Passive indicator: let clicks pass through to the menu bar / windows underneath.
        ignoresMouseEvents = true

        let host = NSHostingView(rootView: makeRootView())
        host.frame = NSRect(origin: .zero, size: FloatingPanel.panelSize)
        host.autoresizingMask = [.width, .height]
        contentView = host
        hostingView = host

        anchorToNotch()

        // Re-anchor when displays change (resolution, plugging in an external monitor, etc.).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // A non-activating panel must never become key/main, or it would steal focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Notch anchoring

    /// The screen IRIS draws on: the built-in notched display if present, else the main screen.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main
    }

    /// Position the panel centered on the notch with its top flush to the screen top, and
    /// rebuild the island with that screen's notch metrics.
    func anchorToNotch() {
        guard let screen = targetScreen else { return }

        let size = FloatingPanel.panelSize
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height   // top-aligned
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        hostingView?.rootView = makeRootView(for: screen)
    }

    private func makeRootView(for screen: NSScreen? = nil) -> OverlayView {
        let s = screen ?? targetScreen
        return OverlayView(
            appState: appState,
            topInset: s?.islandTopInset ?? 38,
            notchWidth: s?.notchWidth ?? 0
        )
    }

    @objc private func screenParametersChanged() {
        anchorToNotch()
    }

    // MARK: - Visibility

    func show() {
        anchorToNotch()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    @discardableResult
    func toggle() -> Bool {
        if isVisible {
            hide()
            return false
        } else {
            show()
            return true
        }
    }
}

// MARK: - Notch geometry

extension NSScreen {
    /// True when this display has a camera notch.
    var hasNotch: Bool {
        if #available(macOS 12.0, *) { return safeAreaInsets.top > 0 }
        return false
    }

    /// Physical notch width in points (0 if there's no notch). Derived from the usable
    /// areas on either side of the notch.
    var notchWidth: CGFloat {
        if #available(macOS 12.0, *),
           let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return frame.width - left.width - right.width
        }
        return 0
    }

    /// Vertical inset that clears the notch / menu bar so island content sits below it.
    var islandTopInset: CGFloat {
        let safe: CGFloat
        if #available(macOS 12.0, *) { safe = safeAreaInsets.top } else { safe = 0 }
        // On non-notched displays fall back to a sensible menu-bar clearance.
        return max(safe, 24)
    }
}
