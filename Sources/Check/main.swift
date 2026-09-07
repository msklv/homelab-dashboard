import Foundation
import HomelabCore

// Мини-харнесс ассертов (без XCTest — работает с Command Line Tools).
var failures: [String] = []
var total = 0

func eq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    total += 1
    if got == want { print("  ok  \(name)") }
    else { failures.append("\(name): got \(got) want \(want)"); print("  FAIL \(name): got \(got) want \(want)") }
}

func ok(_ cond: Bool, _ name: String, _ detail: String = "") {
    total += 1
    if cond { print("  ok  \(name)") }
    else { failures.append("\(name) \(detail)"); print("  FAIL \(name) \(detail)") }
}

func close(_ got: Double, _ want: Double, _ name: String, _ tol: Double = 1e-6) {
    total += 1
    if abs(got - want) <= tol { print("  ok  \(name)") }
    else { failures.append("\(name): \(got) != \(want)"); print("  FAIL \(name): \(got) != \(want)") }
}

func unwrap<T>(_ v: T?, _ name: String) -> T {
    guard let v else {
        failures.append("unwrap nil: \(name)")
        print("  FAIL unwrap nil: \(name)")
        exit(99)
    }
    return v
}

// MARK: - YAML / Config

func testYaml() throws {
    print("-- YAML/Config --")
    let doc = try YamlMini.parseDocument("""
    poll_interval: 5
    theme: dark
    thresholds:
      warning: 60
      critical: 85
    groups:
      - name: Кластер k8s
    tags:
      - { name: prod, color: green }
    hosts:
      - name: k8s-01
        ssh: dev1@192.0.2.11
        os: linux
        group: Кластер k8s
        tags: [prod, critical]
        poll_interval: 10
        metrics: { cores: true, iostat: false }
    """)
    let m = unwrap(doc.map, "root map")
    eq(m["poll_interval"]?.int, 5, "top poll_interval")
    eq(m["theme"]?.string, "dark", "theme")
    eq(m["thresholds"]?.map?["warning"]?.int, 60, "nested thresholds")
    eq(m["groups"]?.array?.count, 1, "groups count")
    eq(m["groups"]?.array?[0].map?["name"]?.string, "Кластер k8s", "group name")
    eq(m["tags"]?.array?[0].map?["name"]?.string, "prod", "tag name")
    eq(m["tags"]?.array?[0].map?["color"]?.string, "green", "tag color")
    eq(m["hosts"]?.array?[0].map?["ssh"]?.string, "dev1@192.0.2.11", "host ssh")
    eq(m["hosts"]?.array?[0].map?["tags"]?.stringArray(), ["prod", "critical"], "tags flow list")
    eq(m["hosts"]?.array?[0].map?["metrics"]?.map?["iostat"]?.bool, false, "metrics flow map bool")

    let cfg = try Config.parse("""
    timeout: 5
    hosts:
      - name: a
        ssh: u@h
        os: linux
        poll_interval: 10
      - name: b
        ssh: u@h2
    """)
    eq(cfg.pollInterval, 5, "default poll_interval (absent) = 5")
    eq(cfg.interval(for: cfg.hosts[0]), 10, "per-host interval wins")
    eq(cfg.interval(for: cfg.hosts[1]), 5, "global default when no override")
    eq(cfg.groupsWithUngrouped.contains(cfg.unknownGroupName), true, "ungrouped auto-group")
    eq(HostConfig(name: "x", ssh: "demo@192.0.2.12").pingHost, "192.0.2.12", "pingHost strips user")
}

// MARK: - Command batches / parser

func testCommands() {
    print("-- Command batches --")
    let batch = CommandBatch.build(for: HostConfig(name: "k8s-01", ssh: "r@h"))
    for k in ["HL_OS", "HL_CORES", "HL_UPTIME", "HL_MEM_USED", "HL_DISK_TOTAL", "HL_TEMP", "HL_NET_RX", "HL_DISK_R", "HL_CPU"] {
        ok(batch.contains(k), "batch has \(k)")
    }
    ok(batch.contains("/proc/meminfo"), "batch probes /proc (linux)")
    ok(batch.contains("sysctl"), "batch probes sysctl (macos)")
    ok(batch.contains("HL_OS=linux") && batch.contains("HL_OS=macos"), "os auto-detected in-shell")

    print("-- OutputParser --")
    let kv = OutputParser.keyValues("x\nHL_CORES=12\nHL_CPU=2.5\n")
    eq(kv["HL_CORES"], "12", "kv cores")
    eq(kv["HL_CPU"], "2.5", "kv cpu")
}

// MARK: - SampleEngine

func testSampleEngine() throws {
    print("-- SampleEngine --")
    let h = HostConfig(name: "k8s-01", ssh: "r@h")
    let out1 = """
    HL_OS=linux
    HL_HOSTNAME=k8s-01
    HL_CORES=12
    HL_UPTIME=166000
    HL_MEM_TOTAL=17179869184
    HL_MEM_USED=8589934592
    HL_DISK_TOTAL=99774301388
    HL_TEMP=51
    HL_TEMP_BOARD=38.5
    HL_LINK=2500
    HL_DISKKIND=nvme
    HL_CPU=2.4
    HL_NET_RX=1000
    HL_NET_TX=2000
    HL_DISK_R=4096
    HL_DISK_W=1024
    """
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 1010)

    let s1 = try SampleEngine.apply(out1, host: h, pingMs: 3.5, previous: nil, now: t0)
    eq(s1.snapshot.os, .linux, "os auto-detected")
    eq(s1.snapshot.hostname, "k8s-01" as String?, "system hostname")
    eq(s1.snapshot.cores, 12, "cores")
    eq(s1.snapshot.uptimeSec, 166000, "uptime")
    close(s1.snapshot.ramUsedPct ?? -1, 50, "ram pct")
    close(s1.snapshot.tempC ?? -1, 51, "temp")
    close(s1.snapshot.cpuPct ?? -1, 2.4, "cpu")
    eq(s1.snapshot.linkMbps, 2500, "link parse")
    eq(s1.snapshot.diskKind, "nvme" as String?, "disk kind parse")
    close(s1.snapshot.tempBoardC ?? -1, 38.5, "board temp")
    eq(s1.snapshot.uptimeText, "1d 22h", "uptime text")
    eq(s1.snapshot.isOnline, true, "online status")

    let out2 = """
    HL_OS=linux
    HL_CORES=12
    HL_UPTIME=166010
    HL_MEM_TOTAL=17179869184
    HL_MEM_USED=10000000000
    HL_DISK_TOTAL=99774301388
    HL_TEMP=52
    HL_CPU=5.0
    HL_NET_RX=1000
    HL_NET_TX=3000
    HL_DISK_R=4096
    HL_DISK_W=4096
    """
    let s2 = try SampleEngine.apply(out2, host: h, pingMs: nil, previous: s1, now: t1)
    close(s2.snapshot.netUp ?? -1, 100, "net up rate 100 B/s")
    close(s2.snapshot.netDown ?? -1, 0, "net down 0 B/s (no change)")
    close(s2.snapshot.diskWrite ?? -1, 307.2, "disk write rate")

    let rollPrev = try SampleEngine.apply("HL_NET_TX=100\nHL_NET_RX=100", host: h, pingMs: nil, previous: nil, now: t0)
    let roll = try SampleEngine.apply("HL_NET_TX=50\nHL_NET_RX=300", host: h, pingMs: nil, previous: rollPrev, now: t1)
    ok(roll.snapshot.netUp == nil, "rolled-back tx -> no rate")
    close(roll.snapshot.netDown ?? -1, 20, "rx rate after rollback")

    print("-- Format --")
    eq(Format.bytesPerSecond(2048), "2.0 K/s", "fmt K/s")
    eq(Format.bytes(17179869184), "16.0 G", "fmt GB")
    eq(Format.percent(64.2), "64%", "fmt pct")
    eq(Format.link(2500), "2.5G", "fmt link 2.5G")
    eq(Format.link(1000), "1G", "fmt link 1G")
    eq(Format.link(100), "100M", "fmt link 100M")
    eq(Format.temp(39.7), "40°", "fmt temp")
    eq(Format.temp(nil), "—", "fmt temp none")
}

// MARK: - Poller

struct MockExecutor: CommandExecuting {
    var sshResult: ExecResult
    func run(_ argv: [String]) -> ExecResult {
        if argv.first?.contains("ping") == true {
            return ExecResult(exitCode: 0, stdout: "round-trip min/avg/max = 1.000/2.500/4.000 ms")
        }
        return sshResult
    }
}

func testPoller() {
    print("-- Poller --")
    let okOut = """
    HL_CORES=12
    HL_UPTIME=3600
    HL_MEM_TOTAL=17179869184
    HL_MEM_USED=8589934592
    HL_CPU=3.3
    """
    func make(_ misses: Int, _ result: ExecResult) -> (Poller, HostConfig) {
        var c = Config(); c.offlineAfterMisses = misses
        let h = HostConfig(name: "host1", ssh: "user@192.0.2.11")
        c.hosts = [h]
        let ex = MockExecutor(sshResult: result)
        return (Poller(config: c, ssh: SshRunner(executor: ex), pinger: PingRunner(executor: ex)), h)
    }
    do {
        let (p, h) = make(2, ExecResult(exitCode: 0, stdout: okOut))
        let snap = p.collectOnce(h)
        eq(snap.status, .online, "online status")
        eq(snap.cores, 12, "online cores")
        close(snap.cpuPct ?? -1, 3.3, "online cpu")
        ok(snap.pingMs != nil, "ping parsed")
    }
    do {
        let (p, h) = make(1, ExecResult(exitCode: 255, stdout: "denied"))
        eq(p.collectOnce(h).status, .offline, "offline after threshold")
    }
    do {
        let (p, h) = make(3, ExecResult(exitCode: 255, stdout: "down"))
        eq(p.collectOnce(h).status, .pending, "pending before threshold")
    }
}

// MARK: - Watcher

func testWatcher() {
    print("-- ConfigWatcher --")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.yaml")
    try? "a: 1\n".write(to: file, atomically: true, encoding: .utf8)

    let watcher = ConfigWatcher(path: file.path, checkInterval: 0.05)
    var fired = false
    watcher.onChange = { fired = true }
    watcher.start()
    try? "a: 2\n".write(to: file, atomically: true, encoding: .utf8)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    ok(fired, "watcher fires onChange on file edit")
    watcher.stop()
    try? FileManager.default.removeItem(at: dir)
}


// MARK: - QuickAdd + yaml round-trip

func testQuickAdd() {
    print("-- QuickAdd --")
    let u = "bob"
    let d1 = QuickAdd.parse("dev2@192.0.2.13", currentUser: u)
    ok(d1 != nil && d1!.name == "192.0.2.13" && d1!.ssh == "dev2@192.0.2.13", "user@host -> name=host")
    let d2 = QuickAdd.parse("192.0.2.13", currentUser: u)
    ok(d2 != nil && d2!.name == "192.0.2.13" && d2!.ssh == "bob@192.0.2.13", "bare ip uses current user")
    let d3 = QuickAdd.parse("nas1", currentUser: u)
    ok(d3 != nil && d3!.name == "nas1" && d3!.ssh == "bob@nas1", "bare hostname uses current user")
    ok(QuickAdd.parse("", currentUser: u) == nil, "empty -> nil")
    ok(QuickAdd.parse("user@", currentUser: u) == nil, "trailing @ (empty name) -> nil")
    ok(QuickAdd.parse("@host", currentUser: u)?.name == "host", "@host collapses to name=host")
    ok(QuickAdd.parse("  user@h  ", currentUser: u) != nil, "trims surrounding whitespace")

    var cfg = Config()
    cfg.hosts = [HostConfig(name: "a", ssh: "u@h")]
    var c2 = cfg
    let e1 = QuickAdd.append(to: &c2, address: "x@192.0.2.1", currentUser: u)
    ok(e1 == nil && c2.hosts.count == 2, "appends new host")
    eq(c2.hosts.last!.group, nil, "new host has no default group")
    eq(c2.hosts.last!.tags, [], "new host has no default tags")
    let e2 = QuickAdd.append(to: &c2, address: "u@h", currentUser: u)
    ok(e2 != nil && c2.hosts.count == 2, "duplicate ssh rejected")
    let e3 = QuickAdd.append(to: &c2, address: "user@a", currentUser: u)
    ok(e3 != nil && c2.hosts.count == 2, "duplicate name rejected")
    let e4 = QuickAdd.append(to: &c2, address: "  ", currentUser: u)
    ok(e4 != nil && c2.hosts.count == 2, "blank rejected")
}

func testYamlRoundTrip() throws {
    print("-- yaml round-trip --")
    var c = Config()
    c.pollInterval = 7
    c.timeout = 4
    c.offlineAfterMisses = 3
    c.maxConcurrent = 6
    c.theme = .dark
    c.thresholds.warning = 55
    c.thresholds.critical = 90
    c.groups = ["Кластер k8s", "macOS"]
    c.tags = [TagDef(name: "prod", color: "green"), TagDef(name: "homelab", color: "blue")]
    c.hosts = [
        HostConfig(name: "k8s-01", ssh: "u@192.0.2.11", group: "Кластер k8s", tags: ["prod"]),
        HostConfig(name: "mac", ssh: "u@192.0.2.12", group: "macOS", tags: ["homelab"], pollInterval: 10),
    ]
    let parsed = try Config.parse(c.yaml)
    eq(parsed.pollInterval, 7, "poll round")
    eq(parsed.timeout, 4, "timeout round")
    eq(parsed.offlineAfterMisses, 3, "misses round")
    eq(parsed.maxConcurrent, 6, "concurrent round")
    eq(parsed.theme, .dark, "theme round")
    eq(parsed.thresholds.warning, 55, "warning round")
    eq(parsed.thresholds.critical, 90, "critical round")
    eq(parsed.groups, c.groups, "groups round")
    eq(parsed.tags, c.tags, "tags round")
    eq(parsed.hosts.count, 2, "hosts count round")
    eq(parsed.hosts[0].name, "k8s-01", "host0 name")
    eq(parsed.hosts[0].ssh, "u@192.0.2.11", "host0 ssh")
    eq(parsed.hosts[0].group, "Кластер k8s", "host0 group")
    eq(parsed.hosts[0].tags, ["prod"], "host0 tags")
    eq(parsed.hosts[1].name, "mac", "host1 name")
    eq(parsed.hosts[1].pollInterval, 10, "host1 poll round")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hl_qa_\(UUID().uuidString).yaml")
    try c.yaml.write(to: tmp, atomically: true, encoding: .utf8)
    let reloaded = try Config.load(from: tmp.path)
    eq(reloaded.hosts.count, 2, "persist-to-file reload hosts")
    eq(reloaded.hosts[1].name, "mac", "persist-to-file reload host1")

    var m = reloaded
    m.hosts[0].group = "Другая"
    try m.yaml.write(to: tmp, atomically: true, encoding: .utf8)
    let mr = try Config.load(from: tmp.path)
    eq(mr.hosts[0].group, "Другая", "setGroup persists")
    eq(mr.hosts[0].name, "k8s-01", "setGroup keeps host")

    var d = mr
    d.hosts.removeAll { $0.name == "mac" }
    try d.yaml.write(to: tmp, atomically: true, encoding: .utf8)
    let dr = try Config.load(from: tmp.path)
    eq(dr.hosts.count, 1, "deleteHost persists")
    eq(dr.hosts[0].name, "k8s-01", "deleteHost keeps remaining")
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - main


do {
    try testYaml()
    testQuickAdd()
    try testYamlRoundTrip()
    testCommands()
    try testSampleEngine()
    testPoller()
    testWatcher()

    print("\n=== \(total - failures.count)/\(total) passed ===")
    if failures.isEmpty {
        print("ALL TESTS PASSED")
        exit(0)
    }
    print("FAILURES:\n" + failures.joined(separator: "\n"))
    exit(1)
} catch {
    print("TEST ERROR: \(error)")
    exit(2)
}