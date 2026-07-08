//
//  PointerOverlay.swift
//  IRIS — UI lane
//
//  A full-screen, click-through overlay window that shows an animated pointer flying to a
//  screen location with an optional label bubble — "show, don't do" (ported from clicky).
//  Constants (swoop curve, timings) live in docs/algorithms.md → Screen pointing.
//
//  Window recipe: borderless, .screenSaver level, joins all Spaces + full-screen apps,
//  ignores mouse events (clicks pass through), never becomes key/main.
//

import AppKit
import QuartzCore

/// Borderless overlay window that can never steal focus.
private final class PointerWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PointerOverlay {
    // Tuned constants — see docs/algorithms.md → Screen pointing.
    private let swoopDuration: TimeInterval = 0.6
    private let bubbleFadeDuration: TimeInterval = 0.2
    private let autoDismissAfter: TimeInterval = 4.0
    private let controlOffsetFactor: CGFloat = 0.25   // Bézier control ⊥ offset = 0.25 × distance
    private let controlOffsetRange: ClosedRange<CGFloat> = 60...220

    private var window: PointerWindow?
    private var pointerLayer: CAShapeLayer?
    private var bubbleLayer: CALayer?
    private var dismissTimer: Timer?

    /// Fly the pointer to `target` (AppKit global coordinates, bottom-left origin) on the
    /// display whose global frame is `screenFrame`, showing `label` in a bubble beside it.
    func point(at target: CGPoint, label: String?, screenFrame: CGRect) {
        let window = ensureWindow(frame: screenFrame)
        guard let contentView = window.contentView, let root = contentView.layer else { return }

        // Window-local (bottom-left origin) coordinates.
        let local = CGPoint(x: target.x - screenFrame.minX, y: target.y - screenFrame.minY)

        bubbleLayer?.removeFromSuperlayer()
        bubbleLayer = nil

        let pointer = pointerLayer ?? Self.makePointerLayer()
        if pointer.superlayer == nil { root.addSublayer(pointer) }
        pointerLayer = pointer

        // Swoop along a quadratic Bézier from the current (or an off-screen) position.
        let from = (pointer.presentation() ?? pointer).position == .zero
            ? CGPoint(x: screenFrame.width / 2, y: -60)   // first show: rise from bottom edge
            : (pointer.presentation() ?? pointer).position
        pointer.removeAllAnimations()
        pointer.opacity = 1
        pointer.position = local

        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: local, control: Self.controlPoint(
            from: from, to: local, factor: controlOffsetFactor, range: controlOffsetRange))
        let swoop = CAKeyframeAnimation(keyPath: "position")
        swoop.path = path
        swoop.duration = swoopDuration
        swoop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pointer.add(swoop, forKey: "swoop")

        if let label, !label.isEmpty {
            let bubble = Self.makeBubbleLayer(text: label)
            Self.place(bubble: bubble, nearTip: local, within: contentView.bounds)
            bubble.opacity = 0
            root.addSublayer(bubble)
            bubbleLayer = bubble
            // Fade the bubble in once the pointer has arrived.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = CACurrentMediaTime() + swoopDuration
            fade.duration = bubbleFadeDuration
            fade.fillMode = .backwards
            bubble.opacity = 1
            bubble.add(fade, forKey: "fadeIn")
        }

        window.orderFrontRegardless()
        scheduleDismiss()
    }

    /// Fade out and hide the overlay.
    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        guard let window else { return }
        pointerLayer?.opacity = 0
        pointerLayer?.position = .zero    // next show starts fresh from off-screen
        bubbleLayer?.removeFromSuperlayer()
        bubbleLayer = nil
        window.orderOut(nil)
    }

    // MARK: - Window

    private func ensureWindow(frame: CGRect) -> PointerWindow {
        if let window {
            window.setFrame(frame, display: false)
            return window
        }
        let win = PointerWindow(contentRect: frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        win.contentView = view
        window = win
        return win
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissAfter, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    // MARK: - Layers

    /// Cursor-style arrow whose TIP is the layer's `position` (anchor at the top-left tip;
    /// the layer's coordinate space is y-up, so the tip is at the layer's top).
    private static func makePointerLayer() -> CAShapeLayer {
        let size: CGFloat = 36
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.anchorPoint = CGPoint(x: 0, y: 1)   // tip = (0, size) in y-up bounds

        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: size))                 // tip
        p.addLine(to: CGPoint(x: size * 0.30, y: size * 0.08))
        p.addLine(to: CGPoint(x: size * 0.46, y: size * 0.40))
        p.addLine(to: CGPoint(x: size * 0.78, y: size * 0.30))
        p.closeSubpath()
        layer.path = p
        layer.fillColor = NSColor.systemBlue.cgColor
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = 2
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -2)
        return layer
    }

    /// Rounded label bubble containing `text`.
    private static func makeBubbleLayer(text: String) -> CALayer {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let padding = CGSize(width: 12, height: 7)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubble = CALayer()
        bubble.bounds = CGRect(x: 0, y: 0,
                               width: ceil(textSize.width) + padding.width * 2,
                               height: ceil(textSize.height) + padding.height * 2)
        bubble.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
        bubble.cornerRadius = bubble.bounds.height / 2

        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.frame = bubble.bounds.insetBy(dx: padding.width, dy: padding.height)
        bubble.addSublayer(textLayer)
        return bubble
    }

    /// Position the bubble down-right of the pointer tip, flipping to stay on screen.
    private static func place(bubble: CALayer, nearTip tip: CGPoint, within bounds: CGRect) {
        let gap: CGFloat = 14
        let size = bubble.bounds.size
        var origin = CGPoint(x: tip.x + gap, y: tip.y - gap - size.height)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = tip.x - gap - size.width }
        if origin.y < bounds.minY + 8 { origin.y = tip.y + gap }
        origin.x = max(bounds.minX + 8, origin.x)
        origin.y = min(bounds.maxY - 8 - size.height, origin.y)
        bubble.frame = CGRect(origin: origin, size: size)
    }

    /// Quadratic-Bézier control point: midpoint pushed perpendicular by
    /// clamp(factor × distance, range) — gives the swoop its arc.
    private static func controlPoint(from: CGPoint, to: CGPoint,
                                     factor: CGFloat, range: ClosedRange<CGFloat>) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = max(sqrt(dx * dx + dy * dy), 1)
        let offset = min(max(distance * factor, range.lowerBound), range.upperBound)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        // Unit perpendicular (rotate the direction vector 90°).
        let ux = -dy / distance, uy = dx / distance
        return CGPoint(x: mid.x + ux * offset, y: mid.y + uy * offset)
    }
}
