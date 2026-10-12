import Darwin
import Foundation

/// Vida, início e terminal de um processo via libproc. Sem subprocesso `ps`.
enum ProcessProbe {
    struct Info {
        let start: Date
        /// "ttys005"; nil = sem terminal.
        let tty: String?
    }

    /// nil = processo morto (ou de outro usuário, sem acesso — sessões são sempre nossas).
    static func info(pid: Int32) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                         + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        var tty: String?
        if bsd.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: bsd.e_tdev), mode_t(S_IFCHR)) {
            let s = String(cString: name)
            if s != "??" { tty = s }
        }
        return Info(start: start, tty: tty)
    }

    /// Pai e executável de um processo, pra descobrir em que app a sessão roda. nil = morto.
    static func lineage(pid: Int32) -> (parent: Int32, path: String)? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        // `PROC_PIDPATHINFO_MAXSIZE` é uma macro que o Swift não importa: 4 × MAXPATHLEN.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return (Int32(bitPattern: bsd.pbi_ppid), length > 0 ? String(cString: buffer) : "")
    }
}
