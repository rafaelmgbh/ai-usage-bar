import SwiftUI

/// Popover com duas seções: Claude (5h/7d) e Codex (5h/semana), barras horizontais
/// arredondadas + countdown de reset. Rodapé com última atualização + atualizar + sair.
struct PopoverView: View {
    @ObservedObject var model: UsageModel
    var onRefresh: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.medium").foregroundStyle(.secondary)
                Text("Uso do plano")
                    .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }

            // Claude
            ProviderSection(
                name: "Claude",
                rows: model.usage.map {
                    [("5h", $0.fiveHourPercent, resetText($0.fiveHourResetEpoch)),
                     ("7d", $0.sevenDayPercent, resetText($0.sevenDayResetEpoch))]
                },
                error: model.errorText
            )

            Divider()

            // Codex
            ProviderSection(
                name: "Codex",
                rows: model.codexUsage.map {
                    [("5h", $0.fiveHourPercent, resetText($0.fiveHourResetEpoch)),
                     ("7d", $0.weeklyPercent, resetText($0.weeklyResetEpoch))]
                },
                error: model.codexError
            )

            Divider()

            HStack(spacing: 10) {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Atualizar agora")
                if let t = model.lastUpdated {
                    Text(timeStr(t)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onQuit) { Image(systemName: "power") }
                    .buttonStyle(.plain).help("Sair")
            }
            .imageScale(.medium)
        }
        .padding(14)
        .frame(width: 268)
    }
}

/// Cabeçalho de provider + suas barras (ou mensagem de erro/sem-dado).
private struct ProviderSection: View {
    let name: String
    let rows: [(label: String, percent: Double, reset: String)]?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name.uppercased())
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(0.5)

            if let rows {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    BarRow(label: r.label, percent: r.percent, reset: r.reset)
                }
                if let error {
                    errorLabel(error)
                }
            } else if let error {
                errorLabel(error)
            } else {
                Text("sem dados ainda…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func errorLabel(_ e: String) -> some View {
        Label(prettyError(e), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(e.contains("token expirado") ? .red : .orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Uma barra de progresso arredondada com rótulo, % e reset embaixo.
private struct BarRow: View {
    let label: String
    let percent: Double
    let reset: String

    private var clamped: Double { min(max(percent, 0), 100) }
    private var barColor: Color { percent >= 95 ? .red : (percent >= 80 ? .orange : .green) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                    .frame(width: 48, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(barColor)
                            .frame(width: max(6, geo.size.width * clamped / 100))
                    }
                }
                .frame(height: 8)

                Text(String(format: "%.0f%%", percent))
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(barColor)
                    .frame(width: 42, alignment: .trailing)
            }
            if !reset.isEmpty {
                Text(reset).font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 56)
            }
        }
    }
}

// MARK: - Helpers

private func prettyError(_ err: String) -> String {
    if err.contains("token expirado") { return "Token expirado — abra o app/CLI uma vez." }
    return err
}

private func timeStr(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

/// Converte epoch de reset num countdown legível ("reset 1h23m" / "reset 4d2h").
func resetText(_ epoch: Double?) -> String {
    guard let epoch else { return "" }
    let secs = epoch - Date().timeIntervalSince1970
    if secs <= 0 { return "reset agora" }
    let d = Int(secs) / 86400
    let h = (Int(secs) % 86400) / 3600
    let m = (Int(secs) % 3600) / 60
    if d > 0 { return "reset \(d)d\(h)h" }
    if h > 0 { return "reset \(h)h\(m)m" }
    return "reset \(m)m"
}
