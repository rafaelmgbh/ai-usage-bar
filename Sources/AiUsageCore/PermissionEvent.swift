import Foundation

/// Pedido de permissão (ou diálogo de elicitação) que o hook `Notification` do Claude
/// Code despejou na inbox. O registro de sessões não mostra isso: durante o pedido a
/// sessão continua `busy`.
public struct PermissionEvent: Equatable, Sendable {
    public let sessionId: String
    public let transcriptPath: String?
    /// Texto do Claude Code, ex.: "Claude needs your permission to use Bash".
    public let message: String?
    public let type: String?
    /// mtime do arquivo na inbox ≈ quando o pedido apareceu.
    public let receivedAt: Date

    /// Os tipos que pedem ação de quem está no teclado.
    public static let actionTypes: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// Sem `notification_type` (versão antiga) vale o matcher do hook, que já filtrou.
    /// Evento de outro hook que grava na mesma inbox (`Stop`) não é pedido.
    public static func parse(_ data: Data, receivedAt: Date) -> PermissionEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = JSONField.text(root["session_id"])
        else { return nil }
        if let hook = JSONField.text(root["hook_event_name"]), hook != "Notification" { return nil }
        let type = JSONField.text(root["notification_type"])
        if let type, !actionTypes.contains(type) { return nil }
        return PermissionEvent(sessionId: sessionId,
                               transcriptPath: JSONField.text(root["transcript_path"]),
                               message: JSONField.text(root["message"]),
                               type: type,
                               receivedAt: receivedAt)
    }
}
