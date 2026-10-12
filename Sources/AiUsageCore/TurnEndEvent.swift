import Foundation

/// Fim de turno que o hook `Stop` do Claude Code despejou na inbox. O registro de
/// sessões não mostra esse fim quando sobra subagente ou workflow em segundo plano: a
/// sessão continua `busy`.
public struct TurnEndEvent: Equatable, Sendable {
    public let sessionId: String
    /// mtime do arquivo na inbox ≈ quando o turno acabou.
    public let receivedAt: Date

    /// O hook grava só `hook_event_name` e `session_id`: o stdin cru dele traz a última
    /// resposta do Claude (`last_assistant_message`), que não tem por que ir pro disco.
    public static func parse(_ data: Data, receivedAt: Date) -> TurnEndEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            JSONField.text(root["hook_event_name"]) == "Stop",
            let sessionId = JSONField.text(root["session_id"])
        else { return nil }
        return TurnEndEvent(sessionId: sessionId, receivedAt: receivedAt)
    }
}
