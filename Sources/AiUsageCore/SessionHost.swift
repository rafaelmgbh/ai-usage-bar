import Foundation

/// O app em que a sessão roda, achado subindo pela árvore de processos.
public enum SessionHost {
    /// Apps que já avisam quando um agente deles termina ou pede algo, pelo nome do pacote.
    /// Sessão dentro de um deles fica sem banner daqui: seria o segundo aviso do mesmo fato.
    public static let selfNotifying: Set<String> = ["Clark.app"]
    /// Sessão → shell → app são 2 ou 3 degraus. O teto só encerra árvore estranha
    /// (pid reaproveitado fechando um ciclo).
    public static let maxDepth = 12

    /// `lookup` devolve o pai e o executável de um processo; nil = morto ou sem acesso.
    public static func notifiesItself(pid: Int32, apps: Set<String> = selfNotifying,
                                      lookup: (Int32) -> (parent: Int32, path: String)?) -> Bool {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let process = lookup(current) else { return false }
            if process.path.split(separator: "/").contains(where: { apps.contains(String($0)) }) { return true }
            current = process.parent
        }
        return false
    }
}
