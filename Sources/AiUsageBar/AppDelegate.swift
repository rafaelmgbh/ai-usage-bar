import AppKit
import SwiftUI
import AiUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = UsageModel()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?

    private let refreshInterval: TimeInterval = 300  // 5 min

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.imagePosition = .imageOnly
            btn.image = Self.placeholderImage(labels: model.claude.map(\.label))
            btn.toolTip = "carregando…"
            btn.action = #selector(togglePopover)
            btn.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 268, height: 300)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                model: model,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        // redesenha o texto na cor certa quando o tema do sistema muda
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }

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

    // MARK: - Menubar (uma linha por conta Claude + uma do Codex)

    private func updateStatusItem() {
        guard let btn = statusItem.button else { return }

        // Uma linha por conta, rotulada com o label dela: o número na menubar
        // nunca aparece sem dono.
        var rows = model.claude.map { acc in
            Row(brand: acc.label,
                cells: [("5h", acc.usage?.fiveHourPercent),
                        ("7d", acc.usage?.sevenDayPercent)],
                dim: acc.error != nil)
        }
        rows.append(Row(
            brand: "Codex",
            cells: [("5h", model.codexUsage?.fiveHourPercent),
                    ("7d", model.codexUsage?.weeklyPercent)],
            dim: model.codexError != nil
        ))

        btn.image = Self.drawStatusImage(rows: rows)
        btn.toolTip = buildTooltip()
    }

    private func buildTooltip() -> String {
        var out = [String]()
        let pad = max(model.claude.map(\.label.count).max() ?? 0, "Codex".count)

        for acc in model.claude {
            let name = acc.label.padding(toLength: pad, withPad: " ", startingAt: 0)
            if let u = acc.usage {
                var l = String(format: "%@  5h %.0f%% %@  ·  7d %.0f%% %@",
                               name,
                               u.fiveHourPercent, resetText(u.fiveHourResetEpoch),
                               u.sevenDayPercent, resetText(u.sevenDayResetEpoch))
                if let e = acc.error { l += "   ⚠︎ \(short(e))" }
                out.append(l)
            } else if let e = acc.error {
                out.append("\(name)  ⚠︎ \(short(e))")
            }
        }

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

    private static func placeholderImage(labels: [String]) -> NSImage {
        let rows = (labels + ["Codex"]).map {
            Row(brand: $0, cells: [("5h", nil), ("7d", nil)], dim: true)
        }
        return drawStatusImage(rows: rows)
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
