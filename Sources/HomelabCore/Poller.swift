import Foundation

/// Периодический сбор метрик по всем хостам поверх инъектируемых executor'ов.
public final class Poller {
    public typealias Update = (HostConfig, HostSnapshot) -> Void

    let config: Config
    private let ssh: SshRunner
    private let pinger: PingRunner
    public var onUpdate: Update?

    public let log: LogStore?

    private let lock = NSLock()
    private var states: [String: HostState] = [:]
    private var timers: [String: DispatchSourceTimer] = [:]
    private let sem: DispatchSemaphore
    private var running = false
    private var pausedHosts: Set<String> = []

    private final class HostState {
        let lock = NSLock()
        var misses = 0
        var prev: SampleState?
        var last: HostSnapshot?
    }

    public init(config: Config, ssh: SshRunner = SshRunner(), pinger: PingRunner = PingRunner(), log: LogStore? = nil) {
        self.config = config
        self.ssh = ssh
        self.pinger = pinger
        self.log = log
        self.sem = DispatchSemaphore(value: max(1, config.maxConcurrent))
    }

    private func state(for name: String) -> HostState {
        lock.lock(); defer { lock.unlock() }
        if let s = states[name] { return s }
        let s = HostState()
        states[name] = s
        return s
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        for host in config.hosts { schedule(host) }
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Приостановленные хосты (по имени). Состояние рантайма, не персистится.
    public func isPaused(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pausedHosts.contains(name)
    }

    public func setPaused(_ host: HostConfig, _ paused: Bool) {
        lock.lock()
        if paused { pausedHosts.insert(host.name) } else { pausedHosts.remove(host.name) }
        lock.unlock()
        // при снятии паузы — один мгновенный опрос, НО не на вызывающем потоке
        // (вызов приходит из UI, блокирующий ssh завис бы на главном потоке)
        if !paused && !isPaused(host.name) { // снятие паузы
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.tick(host)
            }
        }
    }

    private func schedule(_ host: HostConfig) {
        let q = DispatchQueue(label: "homelab.poller.\(host.name)")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .seconds(max(1, config.interval(for: host))), leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick(host) }
        lock.lock(); timers[host.name] = t; lock.unlock()
        t.resume()
    }

    /// Синхронный одиночный сбор метрики для хоста (используется и таймером, и тестами).
    @discardableResult
    public func collectOnce(_ host: HostConfig) -> HostSnapshot {
        _ = sem.wait(timeout: .now() + .seconds(30))
        defer { sem.signal() }

        let st = state(for: host.name)
        let timeout = config.timeout(for: host)
        let batch = CommandBatch.build(for: host)
        let res = ssh.run(host, timeout: timeout, batch: batch)
        let ping = pinger.latency(host: host.pingHost)

        st.lock.lock()
        if res.exitCode == 0 {
            let recovered = st.misses > 0
            st.misses = 0
            do {
                let ns = try SampleEngine.apply(res.stdout, host: host, pingMs: ping, previous: st.prev)
                st.prev = ns
                st.last = ns.snapshot
                st.lock.unlock()
                if recovered { log?.log(.info, host.name, "Хост восстановлен") }
                onUpdate?(host, ns.snapshot)
                return ns.snapshot
            } catch {
                var degraded = st.last ?? HostSnapshot(host: host)
                degraded.status = .pending
                degraded.pingMs = ping
                st.lock.unlock()
                log?.log(.warn, host.name, "Не удалось разобрать ответ: \(error)")
                onUpdate?(host, degraded)
                return degraded
            }
        } else {
            st.misses += 1
            let offline = st.misses >= config.offlineAfterMisses
            log?.log(offline ? .error : .warn, host.name, sshFailure(res, misses: st.misses, offline: offline))
            var snap = st.last ?? HostSnapshot(host: host)
            snap.status = offline ? .offline : .pending
            snap.pingMs = ping
            snap.host = host
            st.lock.unlock()
            onUpdate?(host, snap)
            return snap
        }
    }

    private func sshFailure(_ res: ExecResult, misses: Int, offline: Bool) -> String {
        let snippet = res.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .drop(while: { $0 != "[stderr]" })
            .dropFirst()
            .first
        let detail = snippet.map(String.init) ?? ""
        let head = detail.count > 120 ? String(detail.prefix(120)) + "…" : detail
        let state = offline ? "offline (после \(misses) сбоев)" : "сбой №\(misses)"
        return "SSH \(state), exit \(res.exitCode)\(head.isEmpty ? "" : " — \(head)")"
    }

    public func tick(_ host: HostConfig) {
        if isPaused(host.name) { return }
        _ = collectOnce(host)
    }

    public func snapshot(for name: String) -> HostSnapshot? {
        let st: HostState? = {
            lock.lock(); defer { lock.unlock() }
            return states[name]
        }()
        guard let s = st else { return nil }
        s.lock.lock(); defer { s.lock.unlock() }
        return s.last
    }

    public func allSnapshots() -> [HostSnapshot] {
        lock.lock(); let st = Array(states.values); lock.unlock()
        return st.compactMap { s in
            s.lock.lock(); let last = s.last; s.lock.unlock()
            return last
        }
    }
}