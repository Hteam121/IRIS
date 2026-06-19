//
//  OverlayView.swift
//  IRIS — UI lane
//
//  The content of the floating panel, rendered as a notch "island": a black pill that
//  hugs the MacBook camera housing and expands downward to show IRIS's reply. Purely
//  driven by the shared `AppState` contract; owns no logic.
//
//  Orb constants (diameter, pulse timing, state→color) come from docs/algorithms.md.
//

import SwiftUI

/// Root view hosted inside `FloatingPanel`. Anchors a notch-style island to the top center
/// (over the camera), showing the status orb and — when present — IRIS's response text.
struct OverlayView: View {
    @ObservedObject var appState: AppState

    /// Vertical inset that clears the camera / menu-bar so content sits *below* the notch.
    var topInset: CGFloat = 38
    /// Physical notch width (0 on non-notched displays); the idle island hugs this.
    var notchWidth: CGFloat = 0

    /// Show the island only when there's something to say or IRIS is active; otherwise the
    /// real notch is left untouched.
    private var isVisible: Bool {
        appState.status != .idle || !appState.responseText.isEmpty
    }

    private var hasText: Bool { !appState.responseText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                island
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isVisible)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: appState.responseText)
        .animation(.easeInOut(duration: 0.25), value: appState.status)
    }

    private var island: some View {
        HStack(alignment: .center, spacing: 10) {
            OrbView(status: appState.status)

            if hasText {
                Text(appState.responseText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 13)
        // Clear the camera/menu-bar so the orb + text sit just below the notch.
        .padding(.top, topInset + 6)
        .frame(minWidth: max(notchWidth + 36, 150))
        .background(
            NotchIslandShape(topRadius: 7, bottomRadius: 22)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        )
    }
}

/// The status indicator: a 16pt circle whose color reflects `IRISStatus` and which pulses
/// (1.0 ⇄ 1.3) while IRIS is active. See docs/algorithms.md → Orb animation.
struct OrbView: View {
    let status: IRISStatus

    @State private var pulsing = false

    private var color: Color {
        switch status {
        case .idle:      return .gray
        case .listening: return .blue
        case .thinking:  return .purple
        case .speaking:  return .green
        }
    }

    /// Idle is a calm, steady dot; any active state pulses to feel alive.
    private var isActive: Bool { status != .idle }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .shadow(color: color.opacity(0.7), radius: isActive ? 6 : 2)
            .scaleEffect(pulsing && isActive ? 1.3 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.3),
                value: pulsing
            )
            .animation(.easeInOut(duration: 0.3), value: status)
            .onAppear { pulsing = true }
    }
}

/// A rounded rectangle with gently rounded top corners and larger bottom corners, so it
/// visually "grows" out of the physical notch (Dynamic-Island style).
struct NotchIslandShape: Shape {
    var topRadius: CGFloat = 7
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = min(topRadius, rect.width / 2)
        let br = min(bottomRadius, rect.width / 2)

        p.move(to: CGPoint(x: rect.minX, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - br),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
