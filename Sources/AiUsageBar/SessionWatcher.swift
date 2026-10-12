import Foundation

/// Acorda o `SessionMonitor` quando algo muda nas pastas observadas (registro de
/// sessões e inbox do hook) e a cada 5 s. O timer cobre o que o evento de pasta não
/// vê: arquivo reescrito no lugar, processo que morreu sem apagar o registro,
/// transcript que avançou, pasta criada depois.
@MainActor
final class SessionWatcher {
    static let interval: TimeInterval = 5

    private let paths: [URL]
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var scheduled = false

    init(paths: [URL], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        for url in paths { watch(url) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onChange() }
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        timer?.invalidate()
        timer = nil
    }

    /// Pasta que ainda não existe (conta que nunca abriu o Claude Code) fica só no timer.
    private func watch(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            dbg("sessões: sem observar \(url.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    /// Junta a rajada de eventos de uma escrita (tmp + rename) numa varredura só.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.scheduled = false
            guard self.timer != nil else { return }   // parado nesse meio-tempo
            self.onChange()
        }
    }
}
