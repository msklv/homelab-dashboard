import Foundation
import HomelabCore

/// Headless-прогон: несколько раундов сбора метрик со всех хостов, вывод и выход.
func runSelfTest(configPath: String, rounds: Int = 3) -> Int32 {
    print("HOMELAB SELF-TEST")
    print("config: \(configPath)")
    guard FileManager.default.fileExists(atPath: configPath) else {
        print("ERR: конфиг не найден")
        return 2
    }
    do {
        let cfg = try Config.load(from: configPath)
        print("hosts: \(cfg.hosts.map(\.name).joined(separator: ", "))")
        let poller = Poller(config: cfg)

        for r in 1...rounds {
            print("--- round \(r) ---")
            for host in cfg.hosts {
                let s = poller.collectOnce(host)
                print(dump(s))
            }
            if r < rounds { Thread.sleep(forTimeInterval: 1.5) }
        }

        let snaps = poller.allSnapshots()
        let online = snaps.filter(\.isOnline).count
        let offline = snaps.filter { $0.status == .offline }.count
        print("RESULT total=\(cfg.hosts.count) online=\(online) offline=\(offline)")
        return (online > 0) ? 0 : 1
    } catch {
        print("ERR: \(error)")
        return 1
    }
}

func dump(_ s: HostSnapshot) -> String {
    let temp = s.tempC.map { String(format: "%.0f°C", $0) } ?? "N/A"
    return "\(s.host.name) [\(s.os.rawValue)] status=\(statusName(s.status)) " +
        "ping=\(Format.ping(s.pingMs)) cpu=\(Format.percent(s.cpuPct)) " +
        "ram=\(Format.percent(s.ramUsedPct))/\(Format.bytes(s.ramTotal)) " +
        "disk=\(Format.bytes(s.diskTotal)) up=\(s.uptimeText ?? "-") temp=\(temp) " +
        "net=↑\(Format.bytesPerSecond(s.netUp))/↓\(Format.bytesPerSecond(s.netDown)) " +
        "dio=R\(Format.bytesPerSecond(s.diskRead))/W\(Format.bytesPerSecond(s.diskWrite)) link=\(s.linkMbps.map(String.init) ?? "-") hn=\(s.hostname ?? "-")"
}

private func statusName(_ s: HostStatus) -> String {
    switch s {
    case .online: return "online"
    case .offline: return "OFFLINE"
    case .pending: return "pending"
    }
}