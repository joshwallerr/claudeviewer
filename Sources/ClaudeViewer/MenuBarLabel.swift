import SwiftUI

struct DotView: View {
    let status: SessionStatus
    let size: CGFloat
    let phase: Double
    var isStale: Bool = false

    var body: some View {
        // Working: full-size circle that breathes between near-transparent and solid.
        let workingOpacity = 0.15 + 0.85 * phase

        ZStack {
            switch status {
            case .working:
                Circle()
                    .fill(Color(red: 1.0, green: 0.58, blue: 0.20))
                    .opacity(workingOpacity)
            case .idle:
                Circle()
                    .fill(Color.white)
                    .opacity(isStale ? 0.25 : 1.0)
            }
        }
        .frame(width: size, height: size)
    }

    static func phase(at date: Date) -> Double {
        // ~1.4 Hz sine — same vibe as the CLI's pulsing star.
        let t = date.timeIntervalSinceReferenceDate
        return (sin(t * 2 * .pi * 1.4) + 1) / 2
    }
}

struct AnimatedDot: View {
    let status: SessionStatus
    let size: CGFloat
    var isStale: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: status != .working)) { ctx in
            DotView(status: status, size: size, phase: DotView.phase(at: ctx.date), isStale: isStale)
        }
    }
}

struct MenuBarLabel: View {
    let sessions: [Session]
    let phase: Double

    static let dotSize: CGFloat = 11
    static let dotSpacing: CGFloat = 5
    static let horizontalPadding: CGFloat = 5
    static let height: CGFloat = 22

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            if sessions.isEmpty {
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    .frame(width: Self.dotSize, height: Self.dotSize)
            } else {
                // Reverse so menu bar reads left→right as Inactive → Waiting → Working
                // (popover stays top→bottom Working → Waiting → Inactive).
                ForEach(Array(sessions.reversed())) { session in
                    DotView(
                        status: session.status,
                        size: Self.dotSize,
                        phase: phase,
                        isStale: session.isStaleIdle
                    )
                }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(height: Self.height)
    }

    static func width(for count: Int) -> CGFloat {
        let visible = max(count, 1)
        let dots = CGFloat(visible) * dotSize
        let gaps = CGFloat(max(visible - 1, 0)) * dotSpacing
        return dots + gaps + 2 * horizontalPadding
    }
}
