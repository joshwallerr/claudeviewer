import SwiftUI

struct PopoverView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var limits: LimitsMonitor

    @State private var showingSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingSettings {
                SettingsView(limits: limits) {
                    showingSettings = false
                }
                .transition(.opacity)
            } else {
                header
                Divider()
                if monitor.sessions.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(monitor.sessions) { session in
                                row(for: session)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                Divider()
                limitsRow
                Divider()
                footer
            }
        }
        .frame(width: 360)
        .frame(maxHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("Claude Code")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let total = monitor.sessions.count
        if total == 0 { return "No sessions" }
        let working = monitor.sessions.filter { $0.status == .working }.count
        let idle = total - working
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) waiting") }
        return parts.joined(separator: " · ")
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No active Claude Code sessions")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func row(for session: Session) -> some View {
        HStack(spacing: 10) {
            AnimatedDot(status: session.status, size: 12, isStale: session.isStaleIdle)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLine(for: session))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondaryLine(for: session))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
        }
    }

    @ViewBuilder
    private var limitsRow: some View {
        limitsContent
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var limitsContent: some View {
        switch limits.state {
        case .notConfigured:
            Button {
                showingSettings = true
            } label: {
                Text("Set up usage limits…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        case .loading:
            Text("Loading limits…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .error(let msg):
            Text("Limits error: \(msg)")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
        case .ok(let l):
            fiveHourBar(l)
        }
    }

    @ViewBuilder
    private func fiveHourBar(_ l: ClaudeLimits) -> some View {
        if let bucket = l.fiveHour {
            let pct = max(0, min(100, bucket.utilizationPct))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("5-hour limit")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.10))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 1.0, green: 0.58, blue: 0.20))
                            .frame(width: max(0, geo.size.width * pct / 100))
                    }
                }
                .frame(height: 6)
                if let resetText = nextResetText(l) {
                    Text(resetText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("5-hour limit unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func primaryLine(for session: Session) -> String {
        session.title ?? displayName(for: session.cwd)
    }

    private func secondaryLine(for session: Session) -> String {
        var parts: [String] = []
        // If we showed the title above, include the cwd here so the user
        // can still tell which repo it is. If no title, the cwd is already
        // the primary line.
        if session.title != nil {
            parts.append(displayName(for: session.cwd))
        }
        parts.append(session.status.label)
        if let ctx = session.context {
            parts.append("\(ctx.percent)% context")
        }
        return parts.joined(separator: " · ")
    }

    private func displayName(for cwd: String) -> String {
        let url = URL(fileURLWithPath: cwd)
        return url.lastPathComponent.isEmpty ? cwd : url.lastPathComponent
    }

    private func formatLimits(_ l: ClaudeLimits) -> String {
        var parts: [String] = []
        if let f = l.fiveHour { parts.append("5h \(Int(f.utilizationPct.rounded()))%") }
        if let s = l.sevenDay { parts.append("7d \(Int(s.utilizationPct.rounded()))%") }
        if let o = l.sevenDayOpus { parts.append("Opus \(Int(o.utilizationPct.rounded()))%") }
        if let s = l.sevenDaySonnet { parts.append("Sonnet \(Int(s.utilizationPct.rounded()))%") }
        if let e = l.extraUsage {
            parts.append("extra \(Int(e.utilizationPct.rounded()))%")
        }
        if parts.isEmpty { return "No limit data" }
        return parts.joined(separator: " · ")
    }

    private func nextResetText(_ l: ClaudeLimits) -> String? {
        guard let reset = l.fiveHour?.resetAt, reset > Date() else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date(), to: reset)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let body: String
        if h > 0 {
            body = "\(h)h \(m)m"
        } else if m > 0 {
            body = "\(m)m"
        } else {
            body = "<1m"
        }
        return "resets in \(body)"
    }
}
