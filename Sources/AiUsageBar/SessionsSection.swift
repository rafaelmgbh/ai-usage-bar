import SwiftUI
import AiUsageCore

/// Seção "Sessões": uma linha por sessão do Claude Code, quem precisa de você
/// primeiro. Clique na linha foca a aba no iTerm.
struct SessionsSection: View {
    @ObservedObject var monitor: SessionMonitor
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        MonitorSection(name: "Sessões", isOn: isOn, onToggle: onToggle) {
            // "· 3 min" anda sozinho com o popover aberto.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func list(now: Date) -> some View {
        if let problem = monitor.formatProblem {
            Label(SessionText.formatProblem(problem), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if monitor.rows.isEmpty {
            Text("nenhuma sessão aberta").font(.callout).foregroundStyle(.secondary)
        } else {
            let page = SessionText.page(monitor.rows)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(page.visible) { row in
                    SessionLine(row: row, now: now, showAccount: monitor.showAccount)
                }
                if let more = page.more {
                    Text(more).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SessionLine: View {
    let row: SessionRow
    let now: Date
    let showAccount: Bool

    private var color: Color {
        switch row.state {
        case .needsYou: return .orange
        case .working: return .primary
        case .idle: return .secondary
        }
    }

    private var symbol: String {
        switch row.state {
        case .needsYou: return "circle.fill"
        case .working: return "play.fill"
        case .idle: return "circle"
        }
    }

    var body: some View {
        Button {
            if let tty = row.tty { ITermBridge.focus(tty: tty) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 7))
                    .foregroundStyle(color)
                    .frame(width: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(SessionText.status(row, now: now))
                            .font(.caption).foregroundStyle(color)
                            .lineLimit(1)
                    }
                    Text(SessionText.place(row, home: NSHomeDirectory(), showAccount: showAccount))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.tty == nil)
        .help(row.tty == nil ? "Sessão sem terminal" : "Focar a aba no iTerm")
    }
}
