import AppKit

/// Fala com o iTerm2 por AppleScript (pede a permissão de Automação uma vez).
///
/// `tell application` abre o app se ele estiver fechado, então tudo aqui checa antes
/// se o iTerm está rodando (ou na frente): fechado, não há aba pra focar.
enum ITermBridge {
    static let bundleID = "com.googlecode.iterm2"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// tty ("ttys005") da aba em foco, só com o iTerm na frente. nil também quando
    /// a Automação foi negada.
    static func frontmostTTY() -> String? {
        guard isFrontmost else { return nil }
        let out = run(#"tell application id "com.googlecode.iterm2" to get tty of current session of current window"#)
        return out.map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 }
    }

    /// Seleciona janela, aba e painel cuja tty bate e traz o iTerm pra frente.
    static func focus(tty: String) {
        guard isSafe(tty), isRunning else { return }
        _ = run("""
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "/dev/\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    }

    /// A tty vem do kernel ("ttys005"), mas entra em AppleScript: só letra e dígito passam.
    private static func isSafe(_ tty: String) -> Bool {
        !tty.isEmpty && tty.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            dbg("iTerm: AppleScript falhou: \(error ?? [:])")
            return nil
        }
        return result.stringValue
    }
}
