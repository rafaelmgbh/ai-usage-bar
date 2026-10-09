import AppKit
import Combine
import SwiftUI
import AiUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = UsageModel()

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
            btn.image = Self.drawStatusImage(rows: statusRows(placeholder: true))
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
                Task { @MainActor in self?.updateStatusItem() }
            }
            .store(in: &cancellables)

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

    // MARK: - Menubar (uma linha por conta Claude + uma do Codex, só as ligadas)

    private func updateStatusItem() {
        guard let btn = statusItem.button else { return }
        btn.image = Self.drawStatusImage(rows: statusRows(placeholder: false))
        btn.toolTip = buildTooltip()
    }

    private var enabledClaude: [AccountUsage] {
        model.claude.filter { model.isEnabled(MonitorID.claude($0.label)) }
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
    private static func drawStatusImage(rows: [Row]) -> NSImage {
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
        width += 3

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
            return true
        }
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
        var c = barColor(forPercent: p)
        if dim { c = c.withAlphaComponent(0.4) }
        c.setFill()
        fill.fill()
    }

    private static func barColor(forPercent p: Double) -> NSColor {
        if p >= 95 { return .systemRed }
        if p >= 80 { return .systemOrange }
        return .systemGreen
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
