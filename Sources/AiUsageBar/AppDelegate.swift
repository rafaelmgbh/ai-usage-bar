import AppKit
import Combine
import SwiftUI
import AiUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = UsageModel()
    /// Sessões do Claude Code. Lazy: precisa do `config` que o model já leu.
    private(set) lazy var sessions = SessionMonitor(config: model.config)
    private lazy var notifier = SessionNotifier()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let refreshInterval: TimeInterval = 300  // 5 min

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.imagePosition = .imageOnly
            btn.image = statusImage(placeholder: true)
            btn.toolTip = "carregando…"
            btn.action = #selector(togglePopover)
            btn.target = self
        }

        popover.behavior = .transient
        // Altura fixa cortava o conteúdo assim que apareceu a 3ª seção (2 contas
        // Claude + Codex). Deixamos o hosting controller medir a view.
        let host = NSHostingController(
            rootView: PopoverView(
                model: model,
                sessions: sessions,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        // redesenha o texto na cor certa quando o tema do sistema muda
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }

        // Toggle no popover muda o que a menubar desenha sem esperar o refresh.
        // O debounce junta a rajada de @Published de um ciclo num redesenho só.
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncSessions()
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)

        // Sessões mudam a cada poucos segundos, sem passar pelo model.
        sessions.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        sessions.onEvents = { [weak self] events in
            guard let self else { return }
            self.notifier.deliver(events, showAccount: self.sessions.showAccount)
        }
        syncSessions()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @objc private func refresh() {
        Task { @MainActor in
            await model.refresh()
            updateStatusItem()
        }
    }

    /// O switch da seção "Sessões" liga/desliga o observador. Ligar pede a permissão
    /// de notificação (o macOS só pergunta na 1ª vez).
    private func syncSessions() {
        let on = model.isEnabled(MonitorID.sessions)
        if on && !sessions.isRunning { notifier.requestAuthorization() }
        sessions.setRunning(on)
    }

    // MARK: - Menubar (compacta: ícone + bolinha; ou uma linha por conta ligada)

    private func updateStatusItem() {
        guard let btn = statusItem.button else { return }
        btn.image = statusImage(placeholder: false)
        btn.toolTip = buildTooltip()
    }

    /// No placeholder (antes do 1º refresh) a bolinha fica cinza e o bloco de sessões some.
    private func statusImage(placeholder: Bool) -> NSImage {
        if model.compactMenubar {
            return Self.drawCompactImage(level: placeholder ? .unknown : overallLevel,
                                         needsYou: placeholder ? 0 : sessionBadge?.needsYou ?? 0)
        }
        return Self.drawStatusImage(rows: statusRows(placeholder: placeholder),
                                    badge: placeholder ? nil : sessionBadge)
    }

    /// Cor da bolinha: o pior nível entre os monitores ligados, saldos inclusive.
    private var overallLevel: StatusLevel {
        var monitors = enabledClaude.map { acc -> StatusLevel in
            let u = acc.usage
            let windows = [u?.fiveHour, u?.sevenDay].compactMap { $0 } + (u?.scoped.map(\.window) ?? [])
            return .monitor(windows.map { .of(percent: $0.percent) }, failed: acc.error != nil)
        }
        if model.isEnabled(MonitorID.codex) {
            let percents = model.codexUsage.map { [$0.fiveHourPercent, $0.weeklyPercent] } ?? []
            monitors.append(.monitor(percents.map { .of(percent: $0) }, failed: model.codexError != nil))
        }
        if let cfg = model.config.deepseek, model.isEnabled(MonitorID.deepseek) {
            let balance = model.deepseek
            let level = balance?.primary.map {
                BalanceLevel.of(amount: $0.total, alertBelow: cfg.alertBelow,
                                available: balance?.isAvailable ?? false)
            }
            monitors.append(.monitor(level.map { [.of(balance: $0)] } ?? [],
                                     failed: model.deepseekError != nil))
        }
        // Jev sem creditUSD só mostra gasto: não tem limite pra estourar.
        if let cfg = model.config.jev, cfg.creditUSD != nil, model.isEnabled(MonitorID.jev) {
            let level = model.jev?.balanceUSD.map { BalanceLevel.of(amount: $0, alertBelow: cfg.alertBelow) }
            monitors.append(.monitor(level.map { [.of(balance: $0)] } ?? [],
                                     failed: model.jevError != nil))
        }
        return .overall(monitors)
    }

    private var enabledClaude: [AccountUsage] {
        model.claude.filter { model.isEnabled(MonitorID.claude($0.label)) }
    }

    /// Bloco de sessões da menubar; nil = some (switch desligado ou tudo zerado).
    private var sessionBadge: SessionBadge? {
        guard model.isEnabled(MonitorID.sessions) else { return nil }
        let badge = SessionBadge(working: sessions.workingCount, needsYou: sessions.needsYouCount)
        return badge.isEmpty ? nil : badge
    }

    /// Uma linha por conta ligada, rotulada com o label dela: o número na
    /// menubar nunca aparece sem dono. Saldos ficam fora (não são %).
    /// No placeholder a conta Claude já mostra o número do cache, apagado.
    private func statusRows(placeholder: Bool) -> [Row] {
        var rows = enabledClaude.map { acc in
            Row(brand: acc.label,
                cells: [("5h", acc.usage?.fiveHour?.percent),
                        ("7d", acc.usage?.sevenDay?.percent)],
                dim: placeholder || acc.error != nil)
        }
        if model.isEnabled(MonitorID.codex) {
            rows.append(Row(
                brand: "Codex",
                cells: [("5h", placeholder ? nil : model.codexUsage?.fiveHourPercent),
                        ("7d", placeholder ? nil : model.codexUsage?.weeklyPercent)],
                dim: placeholder || model.codexError != nil
            ))
        }
        // Tudo desligado: sem imagem o item some da menubar e não dá mais pra
        // abrir o popover pra religar.
        if rows.isEmpty { rows = [Row(brand: "AI", cells: [], dim: true)] }
        return rows
    }

    private func buildTooltip() -> String {
        var out = [String]()
        var names = enabledClaude.map(\.label) + ["Codex"]
        if model.config.deepseek != nil { names.append("DeepSeek") }
        let pad = names.map(\.count).max() ?? 0

        for acc in enabledClaude {
            let name = acc.label.padding(toLength: pad, withPad: " ", startingAt: 0)
            if let u = acc.usage {
                let windows = [("5h", u.fiveHour), ("7d", u.sevenDay)]
                    .compactMap { label, w in w.map { (label, $0) } }
                    + u.scoped.map { ($0.label, $0.window) }
                var l = "\(name)  " + windows.map { label, w in
                    String(format: "%@ %.0f%% %@", label, w.percent, resetText(w.resetEpoch))
                }.joined(separator: "  ·  ")
                if let e = acc.error { l += "   ⚠︎ \(short(e)) (último dado às \(hourMinute(u.fetchedAt)))" }
                out.append(l)
            } else if let e = acc.error {
                out.append("\(name)  ⚠︎ \(short(e))")
            }
        }

        if model.isEnabled(MonitorID.codex) {
            let codexName = "Codex".padding(toLength: pad, withPad: " ", startingAt: 0)
            if let c = model.codexUsage {
                var l = String(format: "%@  5h %.0f%% %@  ·  7d %.0f%% %@",
                               codexName,
                               c.fiveHourPercent, resetText(c.fiveHourResetEpoch),
                               c.weeklyPercent, resetText(c.weeklyResetEpoch))
                if let e = model.codexError { l += "   ⚠︎ \(short(e))" }
                out.append(l)
            } else if let e = model.codexError {
                out.append("\(codexName)  ⚠︎ \(short(e))")
            }
        }

        if model.config.deepseek != nil, model.isEnabled(MonitorID.deepseek) {
            let name = "DeepSeek".padding(toLength: pad, withPad: " ", startingAt: 0)
            if let b = model.deepseek, let p = b.primary {
                var l = "\(name)  \(Money.format(p.total, currency: p.currency))"
                if !b.isAvailable { l += "  (indisponível)" }
                if let e = model.deepseekError { l += "   ⚠︎ \(e)" }
                out.append(l)
            } else if let e = model.deepseekError {
                out.append("\(name)  ⚠︎ \(e)")
            }
        }

        if model.config.jev != nil, model.isEnabled(MonitorID.jev) {
            let name = "Jev".padding(toLength: pad, withPad: " ", startingAt: 0)
            if let s = model.jev {
                let month = "mês \(Money.format(s.monthUSD, currency: "USD"))"
                var l = s.balanceUSD.map { "\(name)  saldo ~\(Money.format($0, currency: "USD"))  ·  \(month)" }
                    ?? "\(name)  \(month)"
                if let e = model.jevError { l += "   ⚠︎ \(e)" }
                out.append(l)
            } else if let e = model.jevError {
                out.append("\(name)  ⚠︎ \(e)")
            }
        }

        // Horário absoluto: o tooltip só é refeito quando algo muda, e "há 2 min" envelheceria.
        if model.isEnabled(MonitorID.sessions), !sessions.rows.isEmpty {
            if !out.isEmpty { out.append("") }
            out += sessions.rows.map { "\($0.name)  \($0.state.label) desde \(hourMinute($0.since))" }
        }

        return out.isEmpty ? "carregando…" : out.joined(separator: "\n")
    }

    private func short(_ e: String) -> String {
        e.contains("token expirado") ? "token expirado" : e
    }

    // MARK: - Desenho

    private struct Row {
        let brand: String
        let cells: [(label: String, pct: Double?)]
        let dim: Bool
    }

    private struct SessionBadge {
        let working: Int
        let needsYou: Int
        var isEmpty: Bool { working == 0 && needsYou == 0 }
    }

    /// Tamanhos do desenho. A imagem da menubar tem altura fixa (24pt), então
    /// com 3+ linhas a fonte e a barra precisam encolher pra caber. Com 1 ou 2
    /// contas nada muda em relação ao layout original.
    private struct Metrics {
        let brandFont: NSFont
        let labelFont: NSFont
        let barW: CGFloat
        let barH: CGFloat
        let gapSmall: CGFloat   // rótulo→barra
        let gapBig: CGFloat     // entre colunas

        static func forRows(_ n: Int) -> Metrics {
            if n <= 2 {
                return Metrics(brandFont: .systemFont(ofSize: 10, weight: .semibold),
                               labelFont: .systemFont(ofSize: 9, weight: .medium),
                               barW: 28, barH: 7, gapSmall: 3, gapBig: 7)
            }
            return Metrics(brandFont: .systemFont(ofSize: 8, weight: .semibold),
                           labelFont: .systemFont(ofSize: 7, weight: .medium),
                           barW: 26, barH: 5, gapSmall: 2, gapBig: 5)
        }
    }

    private static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: f]).width
    }

    /// Desenha N linhas (marca + células rotuladas), colunas alinhadas verticalmente.
    private static func drawStatusImage(rows: [Row], badge: SessionBadge?) -> NSImage {
        let h: CGFloat = 24
        let rowH = h / CGFloat(max(rows.count, 1))
        let m = Metrics.forRows(rows.count)

        let brandColW = rows.map { textWidth($0.brand, m.brandFont) }.max() ?? 0
        let nCols = rows.map { $0.cells.count }.max() ?? 0
        var labelColW = [CGFloat](repeating: 0, count: nCols)
        for r in rows {
            for (j, c) in r.cells.enumerated() {
                labelColW[j] = max(labelColW[j], textWidth(c.label, m.labelFont))
            }
        }

        var width: CGFloat = 1 + brandColW
        for j in 0..<nCols { width += m.gapBig + labelColW[j] + m.gapSmall + m.barW }
        let badgeX = width + badgeGap
        width += badgeWidth(badge) + 3

        return NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            for (i, r) in rows.enumerated() {
                let midY = h - rowH * (CGFloat(i) + 0.5)   // linha 0 no topo

                // marca
                let bColor = r.dim ? NSColor.labelColor.withAlphaComponent(0.4) : NSColor.labelColor
                let bAttrs: [NSAttributedString.Key: Any] = [.font: m.brandFont, .foregroundColor: bColor]
                let bSize = (r.brand as NSString).size(withAttributes: bAttrs)
                (r.brand as NSString).draw(at: NSPoint(x: 1, y: midY - bSize.height / 2), withAttributes: bAttrs)

                var x: CGFloat = 1 + brandColW
                let lColor = r.dim ? NSColor.secondaryLabelColor.withAlphaComponent(0.4) : NSColor.secondaryLabelColor
                let lAttrs: [NSAttributedString.Key: Any] = [.font: m.labelFont, .foregroundColor: lColor]
                for j in 0..<nCols {
                    x += m.gapBig
                    let cell: (label: String, pct: Double?) = j < r.cells.count ? r.cells[j] : ("", nil)
                    if !cell.label.isEmpty {
                        let lSize = (cell.label as NSString).size(withAttributes: lAttrs)
                        (cell.label as NSString).draw(at: NSPoint(x: x, y: midY - lSize.height / 2), withAttributes: lAttrs)
                    }
                    let bx = x + labelColW[j] + m.gapSmall
                    drawBar(x: bx, y: midY - m.barH / 2, w: m.barW, h: m.barH, percent: cell.pct, dim: r.dim)
                    x = bx + m.barW
                }
            }
            if let badge { drawBadge(badge, x: badgeX, h: h) }
            return true
        }
    }

    private static let compactSymbol = NSImage(
        systemSymbolName: "gauge.medium", accessibilityDescription: "Uso do plano"
    )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))

    /// Medidor com a bolinha do nível geral no canto; "● N" ao lado só quando
    /// há sessão esperando por você.
    private static func drawCompactImage(level: StatusLevel, needsYou: Int) -> NSImage {
        let h: CGFloat = 24
        let dot: CGFloat = 7
        let iconSize = compactSymbol?.size ?? NSSize(width: 16, height: 16)
        let iconRect = NSRect(x: 1, y: (h - iconSize.height) / 2,
                              width: iconSize.width, height: iconSize.height)
        let dotRect = NSRect(x: iconRect.maxX - 4.5, y: iconRect.minY - 1, width: dot, height: dot)

        let badge = needsYou > 0 ? SessionBadge(working: 0, needsYou: needsYou) : nil
        var width = dotRect.maxX
        let badgeX = width + badgeGap
        width += badgeWidth(badge) + 1

        return NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            // Camada à parte: o sourceIn tinge só o símbolo e o destinationOut abre
            // o recorte em volta da bolinha sem furar o que está atrás da imagem.
            ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            compactSymbol?.draw(in: iconRect)
            NSColor.labelColor.setFill()
            iconRect.fill(using: .sourceIn)
            ctx.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.2, dy: -1.2)).fill()
            ctx.compositingOperation = .sourceOver
            ctx.cgContext.endTransparencyLayer()

            levelColor(level).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            if let badge {
                drawBadgeLine(count: badge.needsYou, x: badgeX, midY: h / 2, color: .systemOrange, round: true)
            }
            return true
        }
    }

    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let badgeGlyph: CGFloat = 6
    private static let badgeGap: CGFloat = 8   // barras → bloco

    private static func badgeWidth(_ badge: SessionBadge?) -> CGFloat {
        guard let badge else { return 0 }
        let widest = [badge.working, badge.needsYou].filter { $0 > 0 }
            .map { textWidth("\($0)", badgeFont) }.max() ?? 0
        return badgeGap + badgeGlyph + 3 + widest
    }

    /// "▶ N" trabalhando em cima, "● N" precisa de você (laranja) embaixo; contagem
    /// zero não desenha a linha. Triângulo e círculo saem do NSBezierPath porque o
    /// caractere ▶ vira emoji colorido em algumas fontes.
    private static func drawBadge(_ badge: SessionBadge, x: CGFloat, h: CGFloat) {
        drawBadgeLine(count: badge.working, x: x, midY: h * 0.75, color: .labelColor, round: false)
        drawBadgeLine(count: badge.needsYou, x: x, midY: h * 0.25, color: .systemOrange, round: true)
    }

    private static func drawBadgeLine(count: Int, x: CGFloat, midY: CGFloat, color: NSColor, round: Bool) {
        guard count > 0 else { return }
        let g = badgeGlyph
        color.setFill()
        let rect = NSRect(x: x, y: midY - g / 2, width: g, height: g)
        if round {
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: rect.minX, y: rect.minY))
            tri.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            tri.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            tri.close()
            tri.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: color]
        let text = "\(count)" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x + g + 3, y: midY - size.height / 2), withAttributes: attrs)
    }

    private static func drawBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, percent: Double?, dim: Bool) {
        let radius = h / 2
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                                 xRadius: radius, yRadius: radius)
        NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
        track.fill()

        guard let p = percent, p > 0 else { return }
        let frac = min(max(p, 0), 100) / 100
        let fillW = max(h, w * frac)
        let fill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillW, height: h),
                                xRadius: radius, yRadius: radius)
        var c = levelColor(.of(percent: p))
        if dim { c = c.withAlphaComponent(0.4) }
        c.setFill()
        fill.fill()
    }

    private static func levelColor(_ level: StatusLevel) -> NSColor {
        switch level {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .crit: return .systemRed
        case .unknown: return .systemGray
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
