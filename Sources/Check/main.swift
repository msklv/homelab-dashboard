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
        collapsed: true
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
    eq(m["groups"]?.array?[0].map?["collapsed"]?.bool, true, "group collapsed bool")
    let cfgG = try Config.parse("""
    groups:
      - name: G
        collapsed: true
    hosts: []
    """)
    eq(cfgG.isGroupCollapsed("G"), true, "isGroupCollapsed reads config true")
    eq(cfgG.isGroupCollapsed("Nope"), false, "isGroupCollapsed absent group false")
    let m0 = try Config.parse("offline_after_misses: 0\nhosts: []")
    eq(m0.offlineAfterMisses, 1, "offline_after_misses:0 clamped to 1")
    let mNeg = try Config.parse("offline_after_misses: -3\nhosts: []")
    eq(mNeg.offlineAfterMisses, 1, "negative offline_after_misses clamped to 1")
    let m5 = try Config.parse("offline_after_misses: 5\nhosts: []")
    eq(m5.offlineAfterMisses, 5, "normal offline_after_misses untouched")
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
        ok(batch.contains("HL_DISK_AVAIL"), "batch collects available disk space")
    ok(batch.contains("/proc/meminfo"), "batch probes /proc (linux)")
    ok(batch.contains("sysctl"), "batch probes sysctl (macos)")
    ok(batch.contains("HL_OS=linux") && batch.contains("HL_OS=macos"), "os auto-detected in-shell")
    ok(batch.contains("0|-1) s="), "linux link: speed -1/0/empty treated as unknown (virtio vm)")
    // Регрессия TrueNAS: у zsh несовпавший глоб роняет всю -c-строку (exit 1) → хост
    // ложно offline. Батч обязан выставлять null_glob до первого глоба.
    ok(batch.contains("setopt null_glob"), "batch guards zsh null_glob (no-match glob != fatal)")
    if let g = batch.range(of: "setopt null_glob")?.lowerBound,
       let t = batch.range(of: "thermal_zone*")?.lowerBound {
        ok(g < t, "null_glob set BEFORE any glob in batch")
    } else { ok(false, "thermal_zone* glob есть в батче") }

    print("-- OutputParser --")
    let kv = OutputParser.keyValues("x\nHL_CORES=12\nHL_CPU=2.5\n")
    eq(kv["HL_CORES"], "12", "kv cores")
    eq(kv["HL_CPU"], "2.5", "kv cpu")

    print("-- Temperature sources (priority list) --")
    ok(batch.contains("k10temp") && batch.contains("coretemp"), "temp: hwmon CPU-датчики в приоритете (k10temp/coretemp)")
    ok(batch.contains("nct6") && batch.contains("it87"), "temp: hwmon SuperIO → плата")
    ok(batch.contains("HL_TEMP_BOARD"), "temp: плата отдельным полем")
    if let hw = batch.range(of: "k10temp")?.lowerBound, let acp = batch.range(of: "acpitz")?.lowerBound {
        ok(hw < acp, "temp: acpitz только как fallback (после hwmon)")
    } else {
        ok(false, "temp: в батче есть и hwmon-, и acpitz-источники")
    }

    print("-- GPU probe batch --")
    let probe = CommandBatch.gpuProbe(for: HostConfig(name: "gpu-01", ssh: "r@h"))
    ok(probe.contains("nvidia-smi") && probe.contains("utilization.gpu"), "gpuProbe linux: nvidia-smi CSV")
    ok(probe.contains("mem_info_vram_total"), "gpuProbe linux: amdgpu sysfs fallback")
    // AMD: имя карты из lspci/pci.ids, а не «cardN» из имени каталога sysfs
    ok(probe.contains("lspci") && probe.contains("pci.ids"), "gpuProbe linux: имя AMD из lspci/pci.ids")
    ok(probe.contains("mem_info_vram_used") && probe.contains("gpu_busy_percent"), "gpuProbe linux: amdgpu VRAM/util")
    ok(!probe.contains("basename $(dirname $c)"), "gpuProbe linux: имя GPU не подменяется на cardN")
    ok(probe.contains("AGXAccelerator") && probe.contains("Device Utilization %"), "gpuProbe mac: AGX utilization")
    ok(probe.contains("iogpu.wired_limit_mb"), "gpuProbe mac: VRAM total из лимита wired")
    ok(probe.contains("In use system memory") && !probe.contains("In use system memory (driver)="),
       "gpuProbe mac: точное поле used без (driver)-варианта")
    ok(batch.contains("HL_GPU"), "main batch has GPU presence flag")
    ok(!batch.contains("query-gpu") && !batch.contains("PerformanceStatistics"),
       "main batch НЕ запускает GPU-зонд (только дешёвый флаг; метрики — отдельный запрос)")
}

func shell(_ cmd: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func testCpuTopParse() {
    print("-- CPU top parser (regression) --")
    // достаём из собранного батча реальный linux-awk для HL_CPU (top -bn2, живой 2-й сэмпл)
        let batch = CommandBatch.build(for: HostConfig(name: "k8s-01", ssh: "r@h"))
        guard let s = batch.range(of: "top -bn2 -d 1 2>/dev/null | awk '")?.upperBound,
              let e = batch[s...].firstIndex(of: "'") else {
            ok(false, "awk cpu есть в linux-батче")
            return
        }
        let awkProg = String(batch[s..<e])
                // подаём строки как отдельные аргументы printf (без \"-обёртки — ломала шелл);
                // это же даёт несколько записей входных данных awk (для проверки «последняя строка»)
                func cpuProg(_ lines: [String]) -> Double? {
                    let quoted = lines.map { "'" + $0 + "'" }.joined(separator: " ")
                    guard let s = shell("printf '%s\\n' " + quoted + " | awk '" + awkProg + "'") else { return nil }
                    return Double(s)
                }
                // ранее баг: паттерн /%Cpu/ (нижний регистр) не матчил строку top "%CPU(s):"
                close(cpuProg(["%CPU(s):  15.9 us,  0.0 sy,  0.0 ni, 84.1 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st"]) ?? -1, 15.9, "modern %CPU(s): -> 100-idle", 0.05)
                close(cpuProg(["Cpu(s):  91.8 us,  0.0 sy,  0.0 ni,  8.2 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st"]) ?? -1, 91.8, "legacy Cpu(s): (no %) -> 100-idle", 0.05)
                // ранее баг: на гостевых top при idle=100.0 значение слипает с меткой ("ni,100.0"),
                // все поля сдвигаются и позиционный парсер (100-$8) читал "id," как 0 -> ложный CPU 100%.
                close(cpuProg(["%CPU(s):  0.0 us,  0.0 sy,  0.0 ni,100.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st"]) ?? -1, 0.0, "glued 'ni,100.0 id,' (idle=100.0) -> 0, not 100", 0.05)
                // топ -bn2: 1-я строка = среднее с загрузки, 2-я = живой интервал. awk должен брать ПОСЛЕДНЮЮ.
                let two = cpuProg(["Cpu(s):  40.0 us,  0.0 sy,  0.0 ni, 60.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st",
                                   "Cpu(s):  3.0 us,  0.0 sy,  0.0 ni, 97.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st"]) ?? -1
                close(two, 3.0, "last (live) cpu line wins, not boot-average", 0.05)
                // ранее баг: на хосте с LANG=ru_RU top печатает "97,3 id"; gsub(/,/) сносит
                // и десятичную запятую -> токены "97 3 id", парсер брал "3" -> ложные 97%.
                // Лечение: LC_ALL=C в батче. Проверяем саму команду батча.
                ok(batch.contains("LC_ALL=C top -bn2 -d 1"), "linux CPU batch forces LC_ALL=C (ru-comma locale fix)")
            }

    func testMacCpuParse() {
        print("-- macOS top CPU parser (regression) --")
        let batch = CommandBatch.build(for: HostConfig(name: "mac-dev", ssh: "u@h"))
        guard let s = batch.range(of: "top -l 2 -n 0 -s 1 2>/dev/null | awk '")?.upperBound,
              let e = batch[s...].firstIndex(of: "'") else {
            ok(false, "awk mac cpuc есть в mac-батче")
            return
        }
        let awkProg = String(batch[s..<e])
        // top -l 2: 1-я "CPU usage" = среднее с загрузки, 2-я = живой интервал -> последняя побеждает
        let script = "printf '%s\\n' \"CPU usage: 4.00% user, 2.00% sys, 94.00% idle\" \"CPU usage: 12.00% user, 3.00% sys, 85.00% idle\" | awk '" + awkProg + "'"
        guard let out = shell(script), let v = Double(out) else { ok(false, "mac awk cpu выполнился"); return }
        close(v, 15.0, "last (live) mac cpu: 100-85=15", 0.05)
        // аналог linux-бага: при idle=100.00 top слипает значение с меткой ("sys,100.00% idle") -> должен быть 0, не 100
        let glued = "printf '%s\\n' \"CPU usage: 0.00% user, 0.00% sys,100.00% idle\" | awk '" + awkProg + "'"
        if let out = shell(glued), let g = Double(out) { close(g, 0.0, "glued 'sys,100.00% idle' -> 0, not 100", 0.05) }
    }

    func testLinuxNetFilter() {
        print("-- linux /proc/net/dev virtual-interface filter (regression) --")
        let batch = CommandBatch.build(for: HostConfig(name: "k8s-01", ssh: "r@h"))
        guard let s = batch.range(of: "HL_NET_RX=$(awk '")?.upperBound,
              let e = batch[s...].firstIndex(of: "'") else {
            ok(false, "awk net linux есть в linux-батче")
            return
        }
        let awkProg = String(batch[s..<e])
        let lines = [
            "Inter-|   Receive                                                |  Transmit",
            " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed",
            "    lo: 900000000       0    0    0     0     0          0         0 900000000       0    0    0    0     0       0          0",
            "  eth0:  500000000       0    0    0     0     0          0         0 300000000       0    0    0    0     0       0          0",
            "docker0: 700000000       0    0    0     0     0          0         0 700000000       0    0    0    0     0       0          0",
            "  veth:  600000000       0    0    0     0     0          0         0 600000000       0    0    0    0     0       0          0",
        ]
        let quoted = lines.map { "'" + $0 + "'" }.joined(separator: " ")
        let srx = "printf '%s\\n' " + quoted + " | awk '" + awkProg + "'"
        guard let rx = shell(srx) else { ok(false, "awk net linux выполнился"); return }
        eq(rx, "500000000", "linux net RX: только физические eth*/en* (lo/docker/veth отброшены)")
    }

func testYamlZeroIndentSeq() {
    print("-- YAML zero-indent sequence (hosts:\n- a) --")
    let yaml = """
    hosts:
    - name: a
      ssh: x
    - name: b
      ssh: y
    """
    let v = try! YamlMini.parseDocument(yaml)
    guard let hosts = v.map?["hosts"]?.array else { ok(false, "hosts стал массивом"); return }
    eq(hosts.count, 2, "two hosts из zero-indent seq")
    ok(hosts.first?.map?["name"]?.string == "a", "host[0].name == a")
    ok(hosts[1].map?["ssh"]?.string == "y", "host[1].ssh == y")
}

func testMacNetParse() {
    print("-- macOS netstat RX/TX parser (regression) --")
    // достаём из mac-батча реальный awk для HL_NET_RX (и TX — тот же скрипт)
    let batch = CommandBatch.build(for: HostConfig(name: "mac-dev", ssh: "u@h"))
    func netAwk(_ marker: String) -> String? {
        guard let m = batch.range(of: marker)?.upperBound,
              let x = batch[m...].firstIndex(of: "'") else { return nil }
        return String(batch[m..<x])
    }
    guard let rxProg = netAwk("echo HL_NET_RX=$(netstat -ib | awk '"),
          let txProg = netAwk("echo HL_NET_TX=$(netstat -ib | awk '") else {
        ok(false, "awk net RX/TX есть в mac-батче")
        return
    }
    let lines = [
        "Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll",
        "lo0        16384 <Link#1>                      1000     0      5000      1000     0      6000      0",
        "lo0        16384 127           localhost       1000     -      5000      1000     -      6000      -",
        "en0        1500  <Link#5>     c6:0f:ad:11:bb:a5  1000     0     1000000     500     0     2000000    0",
        "en0        1500  192.168.3     192.168.3.89    1000     -     1000000     500     -     2000000    -",
        "en0        1500  fe80:e::14e2   fe80::14e2:1469  1000     -     1000000     500     -     2000000    -",
    ]
    let quoted = lines.map { "'" + $0 + "'" }.joined(separator: " ")
    let srx = "printf '%s\\n' " + quoted + " | awk '" + rxProg + "'"
    let stx = "printf '%s\\n' " + quoted + " | awk '" + txProg + "'"
    guard let rx = shell(srx), let tx = shell(stx) else { ok(false, "awk net выполнился"); return }
    eq(rx, "1000000", "RX: dedupe по link-строке (одно значение на интерфейс)")
    eq(tx, "2000000", "TX: колонка $10 (Obytes), не $12")
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
    HL_DISK_AVAIL=49887150694
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
    close(s1.snapshot.diskFreePct ?? -1, 50.0, "disk free pct (avail/total)")
    close(s1.snapshot.diskUsedPct ?? -1, 50.0, "disk used pct = 100 - free")
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
    eq(Format.link(-1), "—", "fmt link -1 (virtio unknown) -> dash")
    eq(Format.link(nil), "—", "fmt link nil -> dash")
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

final class MockRecordingExecutor: CommandExecuting {
    let sshResult: ExecResult
    private(set) var calls = 0
    init(sshResult: ExecResult) { self.sshResult = sshResult }
    func run(_ argv: [String]) -> ExecResult {
        calls += 1
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
    do {
        // пауза: приостановленный хост не опрашивается; resume -> мгновенный опрос
        var c5 = Config(); c5.offlineAfterMisses = 2
        let h5 = HostConfig(name: "h5", ssh: "user@192.0.2.15")
        c5.hosts = [h5]
        let ex5 = MockRecordingExecutor(sshResult: ExecResult(exitCode: 0, stdout: okOut))
        let p5 = Poller(config: c5, ssh: SshRunner(executor: ex5), pinger: PingRunner(executor: ex5))
        let before = ex5.calls
        p5.setPaused(h5, true)
        p5.tick(h5)
        eq(ex5.calls, before, "paused хост не опрашивается")
        ok(p5.isPaused(h5.name), "isPaused true после паузы")
        p5.setPaused(h5, false)
        ok(!p5.isPaused(h5.name), "isPaused false после старта")
        // при снятии паузы мгновенный опрос уходит в фон (не блокирует вызывающий поток)
        let afterResume = ex5.calls
        p5.tick(h5)
        ok(ex5.calls > afterResume, "после старта tick снова опрашивает хост")
    }
    do {
        // свёрнутая группа: хосты не опрашиваются; при разворачивании — возобновляются
        var cg = Config(); cg.offlineAfterMisses = 2
        cg.groups = [GroupDef(name: "Кластер k8s")]
        let gHost = HostConfig(name: "k8s-01", ssh: "user@192.0.2.16", group: "Кластер k8s")
        cg.hosts = [gHost]
        let exg = MockRecordingExecutor(sshResult: ExecResult(exitCode: 0, stdout: okOut))
        let pg = Poller(config: cg, ssh: SshRunner(executor: exg), pinger: PingRunner(executor: exg))
        ok(!pg.isCollapsedGroup("Кластер k8s"), "группа по умолчанию развёрнута")
        pg.setGroupCollapsed("Кластер k8s", true)
        ok(pg.isCollapsedGroup("Кластер k8s"), "isCollapsedGroup после сжатия")
        let beforeG = exg.calls
        pg.tick(gHost)
        eq(exg.calls, beforeG, "свёрнутая группа: хосты не опрашиваются")
        pg.setGroupCollapsed("Кластер k8s", false)
        pg.tick(gHost)
        ok(exg.calls > beforeG, "развёрнутая группа: tick снова опрашивает")
        // инициализация поллера уже свёрнутой группой
        let pInit = Poller(config: cg, ssh: SshRunner(executor: exg), pinger: PingRunner(executor: exg),
                           collapsedGroups: ["Кластер k8s"])
        ok(pInit.isCollapsedGroup("Кластер k8s"), "init принимает свёрнутые группы")
        // ungrouped хосты принадлежат «Прочее» — свернутое «Прочее» их не опрашивает
        var cg2 = Config(); cg2.offlineAfterMisses = 2
        let flat = HostConfig(name: "flat", ssh: "user@192.0.2.17")
        cg2.hosts = [flat]
        let exf = MockRecordingExecutor(sshResult: ExecResult(exitCode: 0, stdout: okOut))
        let pf = Poller(config: cg2, ssh: SshRunner(executor: exf), pinger: PingRunner(executor: exf))
        pf.setGroupCollapsed("Прочее", true)
        let beforeF = exf.calls
        pf.tick(flat)
        eq(exf.calls, beforeF, "свернутое «Прочее» не опрашивает ungrouped хост")
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

    // ssh-cli стиль: ssh 'user:token@host' -p PORT / ssh 'host' -p PORT / кавычки без ssh / малформированный
    let s1 = QuickAdd.parse("ssh 'admin:worker-3@bastion.example.com' -p 2222", currentUser: u)
    ok(s1?.name == "bastion.example.com" && s1?.ssh == "admin:worker-3@bastion.example.com:2222",
       "ssh 'user:token@host' -p PORT -> host name, строка как есть (без ProxyJump)")
    let s2 = QuickAdd.parse("ssh 'bastion.example.com' -p 2222", currentUser: "me")
    ok(s2?.name == "bastion.example.com" && s2?.ssh == "me@bastion.example.com:2222",
       "ssh 'bare host' -p PORT -> currentUser@host:port")
    let s3 = QuickAdd.parse("ssh deploy:vm-02@h -p 23", currentUser: u)
    ok(s3?.name == "h" && s3?.ssh == "deploy:vm-02@h:23", "ssh user:token@host -p PORT без кавычек -> host name")
    let s4 = QuickAdd.parse("'user@host:2222'", currentUser: "me")
    ok(s4?.name == "host" && s4?.ssh == "user@host:2222", "кавычки без ssh: inline :port сохраняется")
    ok(QuickAdd.parse("ssh '' -p 22", currentUser: u) == nil, "пустой адрес в кавычках -> nil")
    ok(QuickAdd.parse("ssh x@h -p 70000", currentUser: u) == nil, "порт >65535 -> nil")
    ok(QuickAdd.parse("ssh 'x@h' -p abc", currentUser: u) == nil, "нечисловой порт -> nil")

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
    ok(e3 == nil && c2.hosts.count == 3 && c2.hosts.last?.name == "a 2",
       "same host-part name, different ssh: добавляется с уникальным именем")
    let e4 = QuickAdd.append(to: &c2, address: "  ", currentUser: u)
    ok(e4 != nil && c2.hosts.count == 3, "blank rejected")
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
    c.groups = [GroupDef(name: "Кластер k8s", collapsed: true), GroupDef(name: "macOS")]
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
    eq(parsed.groups[0].collapsed, true, "group0 collapsed round")
    eq(parsed.groups[1].collapsed, false, "group1 (no flag) collapsed false round")
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

final class CallRecorder { var calls: [String] = [] }
struct RecordingExecutor: CommandExecuting {
    let rec = CallRecorder()
    let result: ExecResult
    func run(_ argv: [String]) -> ExecResult {
        rec.calls.append(argv.joined(separator: " "))
        return result
    }
}

func testSshPort() {
    print("-- ssh port support --")
    eq(SshRunner.split("user@h").1, nil, "no port -> nil")
    eq(SshRunner.split("user@h").0, "user@h", "target unchanged")
    eq(SshRunner.split("user@h:2222").0, "user@h", "port: target")
    eq(SshRunner.split("user@h:2222").1 ?? -1, 2222, "port parsed")
    eq(SshRunner.split("h:22junk").1, nil, "non-numeric port ignored")
    eq(SshRunner.split("[2001:db8::1]:22").0, "[2001:db8::1]", "ipv6 bracket + port")
    eq(SshRunner.split(":0").1, nil, "port 0 rejected")
    eq(SshRunner.split("user@h:70000").1, nil, "port >65535 rejected")
    eq(HostConfig(name: "x", ssh: "user@h:2222").pingHost, "h", "pingHost strips port")
    eq(HostConfig(name: "x", ssh: "user@h").pingHost, "h", "pingHost no port")
    ok(PingRunner().count == 3 && PingRunner().timeout == 3, "ping: -c 3 при timeout 3 (все 3 пакета возвращаются)")
    let d1 = QuickAdd.parse("user@h:2222", currentUser: "me")
    ok(d1?.name == "h" && d1?.ssh == "user@h:2222", "quickadd: name=host, ssh keeps :port")
    let d2 = QuickAdd.parse("h:2222", currentUser: "me")
    ok(d2?.name == "h" && d2?.ssh == "me@h:2222", "quickadd bare:port -> name=host, ssh=user@host:port")
    let d3 = QuickAdd.parse("vm2=user@h:2222", currentUser: "me")
    ok(d3?.name == "vm2" && d3?.ssh == "user@h:2222", "quickadd explicit name=address")
    let d4 = QuickAdd.parse("deploy:vm-02@h:2222", currentUser: "me")
    ok(d4?.name == "h" && d4?.ssh == "deploy:vm-02@h:2222", "user:token@host:port -> host name, строка как есть")
    // дубликат ssh (строки подключения) отклоняется независимо от имени
    var c3 = Config()
    c3.hosts = [HostConfig(name: "vm-01", ssh: "deploy:vm-01@h:2222")]
    let e4 = QuickAdd.append(to: &c3, address: "deploy:vm-02@h:2222", currentUser: "me")
    ok(e4 == nil && c3.hosts.count == 2 && c3.hosts[1].name == "h", "разные ssh-строки обе добавляются, name=host")
    let rec = RecordingExecutor(result: ExecResult(exitCode: 0, stdout: ""))
    let runner = SshRunner(executor: rec)
    runner.run(HostConfig(name: "x", ssh: "user@h:2222"), timeout: 5, batch: "echo hi")
    let argv = rec.rec.calls.first ?? ""
    ok(argv.contains("-p") && argv.contains("2222"), "ssh argv has -p 2222")
    ok(!argv.contains("user@h:2222"), "argv target has no :port (invalid ssh syntax)")

    // Строка подключения ssh: используется как есть (никакого ProxyJump).
    // Двоеточие в user-части (login:token@host) — часть имени пользователя, не джамп.
    let recJ = RecordingExecutor(result: ExecResult(exitCode: 0, stdout: ""))
    SshRunner(executor: recJ).run(HostConfig(name: "w", ssh: "admin:worker-3@bastion.example.com:2222"),
                                  timeout: 5, batch: "echo hi")
    let aJ = recJ.rec.calls.first ?? ""
    ok(!aJ.contains("-J"), "login:token@host: NO -J (нет ProxyJump)")
    ok(aJ.contains("admin:worker-3@bastion.example.com"), "login:token@host: destination как есть")
    ok(aJ.contains("2222"), "login:token@host: порт вынесен в -p 2222")
    let recJ2 = RecordingExecutor(result: ExecResult(exitCode: 0, stdout: ""))
    SshRunner(executor: recJ2).run(HostConfig(name: "w", ssh: "svc:tok-7-test@mock-jump.example.com"),
                                  timeout: 5, batch: "echo hi")
    let aJ2 = recJ2.rec.calls.first ?? ""
    ok(aJ2.contains("svc:tok-7-test@mock-jump.example.com") && !aJ2.contains("-J"),
       "login:token@host: как есть, без -J")
    // plain user@host[:port] (нет двоеточия в user-части) — без -J
    let recP = RecordingExecutor(result: ExecResult(exitCode: 0, stdout: ""))
    SshRunner(executor: recP).run(HostConfig(name: "h", ssh: "admin@bastion.example.com:2222"),
                                  timeout: 5, batch: "echo hi")
    let aP = recP.rec.calls.first ?? ""
    ok(aP.contains("admin@bastion.example.com") && aP.contains("2222") && !aP.contains("-J"),
       "plain user@host[:port]: без -J, destination user@host + -p port")

    // SshRunner.tail — единый builder, используемый и консолью, и экспортом
    eq(SshRunner.tail(for: "user@h:2222"), ["-p", "2222", "user@h"], "tail plain with port")
    eq(SshRunner.tail(for: "user@h"), ["user@h"], "tail plain no port")
    eq(SshRunner.tail(for: "h:22"), ["-p", "22", "h"], "tail bare host port")
    // login:token@host — строка как есть; порт выносится в -p (НЕ джамп).
    eq(SshRunner.tail(for: "svc:tok-7-test@mock-jump.example.com:2222"),
       ["-p", "2222", "svc:tok-7-test@mock-jump.example.com"],
       "tail login:token@host:port -> -p port + destination как есть")
}

// MARK: - GPU: парсер и ленивый опрос

func testGpu() throws {
    print("-- GPU parser --")
    let out = """
    __HOMELAB_START__
    HL_GPU=Apple M4 Max|38654705664|1973649408|9
    HL_GPU=NVIDIA GeForce RTX 4090|25757220864|6514802688|42
    HL_GPU=битая строка
    HL_GPU=|1|2|3
    HL_GPU=ok|1|abc|3
    """
    let gpus = GpuParser.parse(out)
    eq(gpus.count, 2, "парсятся только валидные HL_GPU-строки")
    eq(gpus.first?.name, "Apple M4 Max" as String?, "первая GPU — имя")
    close(gpus.first?.memUsedPct ?? -1, 1_973_649_408 / 38_654_705_664.0 * 100, "memUsedPct = used/total*100", 0.01)
    eq(gpus.last?.name, "NVIDIA GeForce RTX 4090" as String?, "вторая GPU (nvidia) имя")
    close(gpus.last?.utilPct ?? -1, 42, "util pct 42")
    // util за пределами 0–100 клампится
    let clamped = GpuParser.parseLine("G|10|1|140")
    eq(clamped?.utilPct, 100, "util >100 clamp к 100")
    ok(GpuParser.parseLine("G|10|1|140") != nil, "клампинг не роняет строку")

    print("-- SampleEngine: hasGpu + кэш gpus --")
    let h = HostConfig(name: "gpu-host", ssh: "r@h")
    let t0 = Date(timeIntervalSince1970: 2000)
    let t1 = Date(timeIntervalSince1970: 2010)
    let s1 = try SampleEngine.apply("HL_OS=linux\nHL_GPU=1", host: h, pingMs: nil, previous: nil, now: t0)
    eq(s1.snapshot.hasGpu, true, "HL_GPU=1 -> hasGpu true")
    ok(s1.snapshot.gpus == nil, "основной батч не несёт gpus")
    let s1z = try SampleEngine.apply("HL_OS=linux\nHL_GPU=0", host: h, pingMs: nil, previous: nil, now: t0)
    eq(s1z.snapshot.hasGpu, false, "HL_GPU=0 -> hasGpu false")
    let s1n = try SampleEngine.apply("HL_OS=linux", host: h, pingMs: nil, previous: nil, now: t0)
    ok(s1n.snapshot.hasGpu == nil, "нет HL_GPU -> nil (не определяли)")
    // gpus из previous переносятся в свежий снапшот (кэш панели живёт между опросами)
    var cached = s1.snapshot
    cached.gpus = [GpuInfo(name: "RTX", memTotal: 1000, memUsed: 500, utilPct: 10)]
    let prevState = SampleState(snapshot: cached, counters: s1.counters, timestamp: t0)
    let s2 = try SampleEngine.apply("HL_OS=linux\nHL_GPU=1", host: h, pingMs: nil, previous: prevState, now: t1)
    eq(s2.snapshot.gpus?.count, 1, "gpus из previous перенесены")
    eq(s2.snapshot.gpus?.first?.name, "RTX" as String?, "кэш GPU-имени перенесён")

    print("-- Poller: GPU опрашивается только при открытой панели --")
    var c = Config(); c.offlineAfterMisses = 2
    let host = HostConfig(name: "gpu1", ssh: "user@192.0.2.21")
    c.hosts = [host]
    // executor отличает GPU-пробу от основного батча по маркерам, которых нет
    // в основном батче (query-gpu / PerformanceStatistics)
    final class GpuAwareExecutor: CommandExecuting {
        let rec = CallRecorder()
        let mainOut = "HL_OS=linux\nHL_CORES=8\nHL_GPU=1\n"
        var probes = 0
        /// true — зонд отвечает успешно, но без GPU-строк (транзиентный сбой nvidia-smi)
        var emptyProbes = false
        func run(_ argv: [String]) -> ExecResult {
            rec.calls.append(argv.joined(separator: " "))
            if argv.first?.contains("ping") == true {
                return ExecResult(exitCode: 0, stdout: "round-trip min/avg/max = 1.000/2.500/4.000 ms")
            }
            let joined = argv.joined(separator: " ")
            if joined.contains("query-gpu") || joined.contains("PerformanceStatistics") {
                probes += 1
                if emptyProbes { return ExecResult(exitCode: 0, stdout: "__HOMELAB_START__\n") }
                return ExecResult(exitCode: 0, stdout: "__HOMELAB_START__\nHL_GPU=NVIDIA RTX 4090|25757220864|6514802688|42\n")
            }
            return ExecResult(exitCode: 0, stdout: mainOut)
        }
    }
    let ex = GpuAwareExecutor()
    let p = Poller(config: c, ssh: SshRunner(executor: ex), pinger: PingRunner(executor: ex))
    ok(!p.isGpuPanelOpen("gpu1"), "панель по умолчанию закрыта")
    p.collectOnce(host)
    eq(ex.probes, 0, "закрытая панель: GPU-зонд НЕ выполнялся")
    let snapClosed = p.snapshot(for: "gpu1")
    ok(snapClosed?.hasGpu == true && snapClosed?.gpus == nil, "есть флаг hasGpu, но данных GPU нет")
    // тики с закрытой панелью тоже не трогают GPU
    p.tick(host)
    eq(ex.probes, 0, "tick с закрытой панелью: зонда нет")
    // открытие — мгновенный зонд (фон) + тики с открытой панелью опрашивают GPU
    p.setGpuPanel(host, true)
    ok(p.isGpuPanelOpen("gpu1"), "isGpuPanelOpen после открытия")
    var waited = 0
    while ex.probes == 0 && waited < 50 { usleep(20_000); waited += 1 }
    ok(ex.probes >= 1, "открытие панели -> мгновенный GPU-зонд в фоне")
    let beforeTick = ex.probes
    p.tick(host)
    ok(ex.probes > beforeTick, "tick с открытой панелью доопрашивает GPU")
    let snapOpen = p.snapshot(for: "gpu1")
    eq(snapOpen?.gpus?.count, 1, "снапшот содержит GPU")
    close(snapOpen?.gpus?.first?.utilPct ?? -1, 42, "util 42 из пробы")
    eq(snapOpen?.gpus?.first?.memTotal, 25_757_220_864, "VRAM total из MiB*1048576")
    // пустой ответ зонда НЕ обнуляет показанное: иначе панель схлопывается и
    // нижний край карточки прыгает на каждом тике
    ex.emptyProbes = true
    p.tick(host)
    let snapAfterEmpty = p.snapshot(for: "gpu1")
    eq(snapAfterEmpty?.gpus?.count, 1, "пустой ответ зонда сохраняет последние GPU-метрики")
    close(snapAfterEmpty?.gpus?.first?.utilPct ?? -1, 42, "значения не сброшены в 0")
    ex.emptyProbes = false
    // закрытие — кэш сброшен, зондов больше нет
    p.setGpuPanel(host, false)
    ok(p.snapshot(for: "gpu1")?.gpus == nil, "закрытие панели сбрасывает кэш GPU")
    let afterClose = ex.probes
    p.tick(host)
    eq(ex.probes, afterClose, "закрытая панель после открытия: зондов нет")
    // GPU-проба не влияет на статус: хост остаётся online даже при пустом выводе
}

// MARK: - main


do {
    try testYaml()
    testQuickAdd()
    try testYamlRoundTrip()
    testCommands()
    testCpuTopParse()
    testMacCpuParse()
    testYamlZeroIndentSeq()
    testMacNetParse()
    testLinuxNetFilter()
    testSshPort()
    try testSampleEngine()
    try testGpu()
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