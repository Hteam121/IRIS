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

    /// Show the island only when there's something to say, IRIS is active, or background
    /// agents are running; otherwise the real notch is left untouched.
    private var isVisible: Bool {
        appState.status != .idle || !displayText.isEmpty
            || !appState.backgroundTasks.isEmpty
    }

    /// In realtime mode IRIS streams a live caption into `transcript`; the classic path uses
    /// `responseText`. Show whichever is present.
    private var displayText: String {
        appState.responseText.isEmpty ? appState.transcript : appState.responseText
    }

    private var hasText: Bool { !displayText.isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if appState.status != .idle || hasText {
                island
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !appState.backgroundTasks.isEmpty {
                agentList
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isVisible)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: appState.responseText)
        .animation(.easeInOut(duration: 0.25), value: appState.status)
        .animation(.spring(response: 0.40, dampingFraction: 0.85), value: appState.backgroundTasks)
    }

    /// Stacked pills showing each background agent task (capped, with a "+N more" row).
    private var agentList: some View {
        let tasks = appState.backgroundTasks
        let shown = Array(tasks.prefix(4))
        let extra = tasks.count - shown.count
        return VStack(spacing: 5) {
            ForEach(shown) { task in
                AgentPillRow(task: task)
            }
            if extra > 0 {
                Text("+\(extra) more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        // When the island is hidden (idle, no text), nudge the pills below the notch.
        .padding(.top, (appState.status == .idle && !hasText) ? topInset + 6 : 0)
        .frame(maxWidth: 360)
    }

    private var island: some View {
        HStack(alignment: .center, spacing: 10) {
            OrbView(status: appState.status)

            if hasText {
                Text(displayText)
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

/// One background-agent task as a compact pill: a status dot + title + state/summary.
struct AgentPillRow: View {
    let task: AgentTask

    private var color: Color {
        switch task.state {
        case .queued:         return .gray
        case .running:        return .purple
        case .waitingForUser: return .orange
        case .succeeded:      return .green
        case .failed:         return .red
        case .cancelled:      return .gray
        }
    }

    private var stateLabel: String {
        switch task.state {
        case .queued:         return "Queued…"
        case .running:        return "Working…"
        case .waitingForUser: return "Waiting on you…"
        case .succeeded:      return "Done"
        case .failed:         return "Failed"
        case .cancelled:      return "Cancelled"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            AgentStatusDot(color: color, pulsing: task.state == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let summary = task.resultSummary, task.state.isFinished, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(stateLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
    }
}

/// A small pulsing status dot for an agent pill (mirrors OrbView's pulse, scaled down).
struct AgentStatusDot: View {
    let color: Color
    let pulsing: Bool

    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.7), radius: pulsing ? 5 : 2)
            .scaleEffect(pulsing && animate ? 1.35 : 1.0)
            .animation(
                pulsing
                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.3),
                value: animate
            )
            .onAppear { animate = true }
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
