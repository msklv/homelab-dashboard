import Foundation

/// Лёгкий наблюдатель за YAML-конфигом: периодически проверяет mtime файла
/// и зовёт onChange при изменении — фактически мгновенный hot-reload без kqueue/watchers.
public final class ConfigWatcher {
    public let path: String
    private let checkInterval: TimeInterval
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var lastMtime: Date?
    private var lastSize: Int?
    private var running = false

    public var onChange: (() -> Void)?

    public init(path: String, checkInterval: TimeInterval = 0.5) {
        self.path = path
        self.checkInterval = checkInterval
        self.queue = DispatchQueue(label: "homelab.watcher")
    }

    public func start() {
        queue.async {
            if self.running { return }
            self.running = true
            self.prime()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.checkInterval, repeating: self.checkInterval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.check() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func prime() {
        let (m, s) = stat()
        lastMtime = m; lastSize = s
    }

    private func stat() -> (Date?, Int?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return (nil, nil) }
        let m = attrs[.modificationDate] as? Date
        let s = (attrs[.size] as? NSNumber)?.intValue
        return (m, s)
    }

    private func check() {
        let (m, s) = stat()
        if m != lastMtime || s != lastSize {
            lastMtime = m; lastSize = s
            onChange?()
        }
    }
}