import SwiftUI
import AiUsageCore

/// Popover com a seção de sessões do Claude Code no topo, uma seção por conta Claude
/// (5h/7d) + Codex (5h/semana), barras horizontais arredondadas + countdown de reset, e
/// os saldos configurados (DeepSeek, Jev). Cada seção tem um switch que liga/desliga o
/// monitor. Rodapé com última atualização + atualizar + sair.
struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var sessions: SessionMonitor
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

            SessionsSection(
                monitor: sessions,
                isOn: model.isEnabled(MonitorID.sessions),
                onToggle: { model.setEnabled(MonitorID.sessions, $0) }
            )

            Divider()

            // Claude — uma seção por conta, cada uma com o seu próprio erro
            ForEach(model.claude) { acc in
                let id = MonitorID.claude(acc.label)
                ProviderSection(
                    name: acc.label,
                    rows: acc.usage.map(claudeRows),
                    error: acc.error,
                    staleSince: acc.error == nil ? nil : acc.usage?.fetchedAt,
                    isOn: model.isEnabled(id),
                    onToggle: { model.setEnabled(id, $0) }
                )

                Divider()
            }

            // Codex
            ProviderSection(
                name: "Codex",
                rows: model.codexUsage.map {
                    [("5h", $0.fiveHourPercent, resetText($0.fiveHourResetEpoch)),
                     ("7d", $0.weeklyPercent, resetText($0.weeklyResetEpoch))]
                },
                error: model.codexError,
                isOn: model.isEnabled(MonitorID.codex),
                onToggle: { model.setEnabled(MonitorID.codex, $0) }
            )

            Divider()

            if let cfg = model.config.deepseek {
                DeepSeekSection(
                    config: cfg, balance: model.deepseek, error: model.deepseekError,
                    isOn: model.isEnabled(MonitorID.deepseek),
                    onToggle: { model.setEnabled(MonitorID.deepseek, $0) }
                )
                Divider()
            }

            if let cfg = model.config.jev {
                JevSection(
                    config: cfg, spend: model.jev, error: model.jevError,
                    isOn: model.isEnabled(MonitorID.jev),
                    onToggle: { model.setEnabled(MonitorID.jev, $0) }
                )
                Divider()
            }

            HStack {
                Text("Barra compacta").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { model.compactMenubar }, set: model.setCompactMenubar))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Ligado: só o ícone, na cor do nível, na barra de menus. Desligado: barras por conta.")
            }

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

/// Cabeçalho de um monitor com o switch de liga/desliga. Desligado, só o
/// cabeçalho fica — é dele que se religa.
struct MonitorSection<Content: View>: View {
    let name: String
    let isOn: Bool
    let onToggle: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(isOn ? .secondary : .tertiary)
                    .tracking(0.5)
                Spacer()
                Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(isOn ? "Desativar \(name)" : "Ativar \(name)")
            }
            if isOn { content() }
        }
    }
}

/// 5h e 7d (as que vierem) + uma linha por limite de modelo ("Fable", semanal).
private func claudeRows(_ u: ClaudeUsage) -> [(label: String, percent: Double, reset: String)] {
    var rows = [("5h", u.fiveHour), ("7d", u.sevenDay)].compactMap { label, w in
        w.map { (label: label, percent: $0.percent, reset: resetText($0.resetEpoch)) }
    }
    for s in u.scoped {
        let reset = resetText(s.window.resetEpoch)
        rows.append((label: s.label, percent: s.window.percent,
                     reset: reset.isEmpty ? "semanal" : "semanal · \(reset)"))
    }
    return rows
}

/// Seção de provider com barras (ou mensagem de erro/sem-dado).
private struct ProviderSection: View {
    let name: String
    let rows: [(label: String, percent: Double, reset: String)]?
    let error: String?
    /// Horário do número exibido quando a última consulta falhou.
    var staleSince: Date? = nil
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        MonitorSection(name: name, isOn: isOn, onToggle: onToggle) {
            if let rows {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    BarRow(label: r.label, percent: r.percent, reset: r.reset)
                }
                if let error {
                    ErrorLabel(error: error)
                }
                if let staleSince {
                    Text("último dado às \(hourMinute(staleSince))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if let error {
                ErrorLabel(error: error)
            } else {
                NoDataLabel()
            }
        }
    }
}

/// Saldo da API DeepSeek.
private struct DeepSeekSection: View {
    let config: DeepSeekConfig
    let balance: DeepSeekBalance?
    let error: String?
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        MonitorSection(name: "DeepSeek", isOn: isOn, onToggle: onToggle) {
            if let balance, let p = balance.primary {
                BalanceRow(
                    label: "saldo",
                    value: Money.format(p.total, currency: p.currency),
                    level: BalanceLevel.of(amount: p.total, alertBelow: config.alertBelow,
                                           available: balance.isAvailable),
                    caption: caption(balance, p)
                )
                if let error { ErrorLabel(error: error) }
            } else if let error {
                ErrorLabel(error: error)
            } else {
                NoDataLabel()
            }
        }
    }

    private func caption(_ b: DeepSeekBalance, _ p: DeepSeekBalance.Entry) -> String {
        guard b.isAvailable else { return "indisponível — sem saldo pra chamar a API" }
        guard p.granted > 0 else { return "" }
        return "bônus \(Money.format(p.granted, currency: p.currency)) · "
            + "recarga \(Money.format(p.toppedUp, currency: p.currency))"
    }
}

/// Saldo estimado do Jev (crédito − gasto do log local) + gasto do mês.
private struct JevSection: View {
    let config: JevConfig
    let spend: JevSpend?
    let error: String?
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        MonitorSection(name: "Jev", isOn: isOn, onToggle: onToggle) {
            if let spend {
                if let balance = spend.balanceUSD {
                    BalanceRow(
                        label: "saldo",
                        value: "~" + Money.format(balance, currency: "USD"),
                        level: BalanceLevel.of(amount: balance, alertBelow: config.alertBelow),
                        caption: balanceCaption(spend)
                    )
                }
                BalanceRow(
                    label: "mês",
                    value: Money.format(spend.monthUSD, currency: "USD"),
                    level: nil,
                    caption: spend.balanceUSD == nil
                        ? "\(spend.monthCalls) chamadas · defina creditUSD no accounts.json pra ver o saldo"
                        : "\(spend.monthCalls) chamadas · log deste Mac"
                )
                if let error { ErrorLabel(error: error) }
            } else if let error {
                ErrorLabel(error: error)
            } else {
                NoDataLabel()
            }
        }
    }

    private func balanceCaption(_ s: JevSpend) -> String {
        let credit = Money.format(config.creditUSD ?? 0, currency: "USD")
        let spent = Money.format(s.sinceUSD ?? 0, currency: "USD")
        let since = config.since.map { " desde \(dayMonth($0))" } ?? ""
        return "crédito \(credit) − gasto \(spent)\(since)"
    }
}

/// Uma linha de valor (saldo/gasto) com rótulo, valor colorido e legenda.
private struct BalanceRow: View {
    let label: String
    let value: String
    /// `nil` = valor neutro (gasto), sem semáforo.
    let level: BalanceLevel?
    let caption: String

    private var color: Color {
        switch level {
        case .ok: return .green
        case .low: return .orange
        case .empty: return .red
        case nil: return .primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                    .frame(width: 48, alignment: .leading)
                Spacer()
                Text(value)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
            }
            if !caption.isEmpty {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 56)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ErrorLabel: View {
    let error: String

    var body: some View {
        Label(prettyError(error), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(error.contains("token expirado") ? .red : .orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NoDataLabel: View {
    var body: some View {
        Text("sem dados ainda…").font(.callout).foregroundStyle(.secondary)
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

/// "2026-09-30" → "30/09".
private func dayMonth(_ iso: String) -> String {
    let p = iso.split(separator: "-")
    return p.count == 3 ? "\(p[2])/\(p[1])" : iso
}

/// "14:05" — horário de um dado que pode estar velho.
func hourMinute(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
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
