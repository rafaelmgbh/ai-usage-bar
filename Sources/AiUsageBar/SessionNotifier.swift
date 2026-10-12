import AppKit
import UserNotifications
import AiUsageCore

/// Banner + som dos avisos de sessão; clique no banner foca a aba do iTerm.
///
/// `UNUserNotificationCenter` só funciona dentro de um .app (com bundle id): rodando
/// o binário solto, ou com a notificação negada, o aviso vira só o som "Glass".
@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {

    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    /// Só pergunta na 1ª vez; depois o macOS responde com o que já foi decidido.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            dbg("notificações: autorizado=\(granted) erro=\(error.map { "\($0)" } ?? "-")")
        }
    }

    func deliver(_ events: [SessionEvent], showAccount: Bool) {
        let asking = events.compactMap { event -> Int32? in
            switch event {
            case .finished(let row), .needsYou(let row, _): return row.pid
            case .resolved: return nil
            }
        }
        // Sessão que roda dentro do Clark: ele já avisa dela.
        let hosted = Set(asking.filter { SessionHost.notifiesItself(pid: $0, lookup: ProcessProbe.lineage) })
        let wantsPost = asking.contains { !hosted.contains($0) }
        // AppleScript só quando vai haver banner: é ele que decide o silêncio.
        let focused = wantsPost ? ITermBridge.frontmostTTY() : nil
        if !hosted.isEmpty { dbg("sessões: sem banner, o app delas já avisa: \(hosted.sorted())") }
        let notices = SessionNotices.plan(events, focusedTTY: focused, hostNotifies: hosted,
                                          showAccount: showAccount, home: NSHomeDirectory())
        for notice in notices {
            switch notice {
            case let .post(id, title, body, tty):
                post(id: id, title: title, body: body, tty: tty)
            case let .remove(id):
                center?.removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
    }

    private func post(id: String, title: String, body: String, tty: String?) {
        guard let center else {
            NSSound(named: "Glass")?.play()
            return
        }
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in
                self.show(allowed: allowed, id: id, title: title, body: body, tty: tty)
            }
        }
    }

    /// Notificação negada vira só o som.
    private func show(allowed: Bool, id: String, title: String, body: String, tty: String?) {
        guard allowed, let center else {
            NSSound(named: "Glass")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let tty { content.userInfo = ["tty": tty] }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { dbg("notificação não saiu: \(error)") }
        }
    }

    // Com o popover aberto o app conta como ativo: sem isso o banner não aparece.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tty = response.notification.request.content.userInfo["tty"] as? String
        Task { @MainActor in
            if let tty { ITermBridge.focus(tty: tty) }
        }
        completionHandler()
    }
}
