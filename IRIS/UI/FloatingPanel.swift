//
//  FloatingPanel.swift
//  IRIS — UI lane
//
//  A borderless, non-activating, always-on-top panel. Two modes (settings.uiMode):
//   • "buddy" (default) — a compact cursor-following surface to the lower-right of the
//     pointer (Clicky-style), spring-smoothed, hopping to whichever screen holds the cursor.
//   • "notch" — the island anchored to the top center of the screen (over the camera).
//  Transparent and click-through in both modes so it never steals focus or blocks clicks.
//

import AppKit
import SwiftUI

@MainActor
final class FloatingPanel: NSPanel {

    /// Generous transparent canvas; the black island sizes itself within and is centered
    /// on the notch. Click-through means the empty area never blocks anything.
    static let panelSize = NSSize(width: 720, height: 320)

    /// Buddy-mode canvas: compact, content top-leading near the cursor.
    static let buddySize = NSSize(width: 400, height: 300)

    // Buddy follow constants (docs/algorithms.md → Cursor buddy).
    static let buddyOffset = CGPoint(x: 20, y: 60)   // right of cursor, below it
    static let followHz: TimeInterval = 1.0 / 30.0
    static let followSmoothing: CGFloat = 0.25        // fraction of remaining distance per tick

    private let appState: AppState
    private let buddyMode: Bool
    private var hostingView: NSView?
    private var followTimer: Timer?

    init(appState: AppState, buddyMode: Bool = true) {
        self.appState = appState
        self.buddyMode = buddyMode
        let size = buddyMode ? FloatingPanel.buddySize : FloatingPanel.panelSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
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

        if buddyMode {
            let host = NSHostingView(rootView: BuddyView(appState: appState))
            host.frame = NSRect(origin: .zero, size: FloatingPanel.buddySize)
            host.autoresizingMask = [.width, .height]
            contentView = host
            hostingView = host
        } else {
            let host = NSHostingView(rootView: makeRootView())
            host.frame = NSRect(origin: .zero, size: FloatingPanel.panelSize)
            host.autoresizingMask = [.width, .height]
            contentView = host
            hostingView = host
            anchorToNotch()
        }

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
        guard !buddyMode, let screen = targetScreen else { return }

        let size = FloatingPanel.panelSize
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height   // top-aligned
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        (hostingView as? NSHostingView<OverlayView>)?.rootView = makeRootView(for: screen)
    }

    // MARK: - Cursor following (buddy mode)

    /// Move toward a point offset to the lower-right of the cursor, spring-smoothed, on
    /// whichever screen currently holds the cursor (multi-monitor). 30 Hz; skips work when
    /// already settled so an idle cursor costs nothing.
    private func startFollowingCursor() {
        stopFollowingCursor()
        followTimer = Timer.scheduledTimer(withTimeInterval: Self.followHz, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.followTick() }
        }
        // Snap to the cursor on show (no long glide across the screen).
        if let target = buddyTarget() { setFrameOrigin(target) }
    }

    private func stopFollowingCursor() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func followTick() {
        guard let target = buddyTarget() else { return }
        let current = frame.origin
        let dx = target.x - current.x, dy = target.y - current.y
        if abs(dx) < 0.5, abs(dy) < 0.5 { return }   // settled
        setFrameOrigin(NSPoint(x: current.x + dx * Self.followSmoothing,
                               y: current.y + dy * Self.followSmoothing))
    }

    /// The desired panel origin: content top-left sits `buddyOffset` below-right of the
    /// cursor, clamped inside the visible frame of the screen containing the cursor.
    private func buddyTarget() -> NSPoint? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return nil }
        let size = Self.buddySize
        var x = mouse.x + Self.buddyOffset.x
        // Panel TOP edge sits buddyOffset.y below the cursor (AppKit origin is bottom-left).
        var y = mouse.y - Self.buddyOffset.y - size.height
        // Flip to the left of the cursor when the bubble would run off the right edge.
        let visible = screen.visibleFrame
        if x + size.width > visible.maxX { x = mouse.x - Self.buddyOffset.x - size.width }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        return NSPoint(x: x, y: y)
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
        if buddyMode {
            startFollowingCursor()
        } else {
            anchorToNotch()
        }
        orderFrontRegardless()
    }

    func hide() {
        stopFollowingCursor()
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
