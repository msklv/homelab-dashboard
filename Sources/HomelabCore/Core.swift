import Foundation

// MARK: - Общие модели

public enum HostStatus: Equatable, Sendable {
    case pending, online, offline
}

public struct HostSnapshot: Equatable, Sendable {
    public var host: HostConfig
    /// Тип ОС, определённый программно при первом опросе (по `uname -s`).
    public var os: HostOS = .unknown
    /// Реальное имя хоста из системы (по `hostname`), показывается в заголовке карточки.
    public var hostname: String?
    public var status: HostStatus = .pending
    public var pingMs: Double?
    public var cores: Int?
    public var ramTotal: UInt64?        // bytes
    public var ramUsedPct: Double?
    public var diskTotal: UInt64?       // bytes — суммарный объём ФИЗИЧЕСКИХ дисков
    public var diskKind: String?        // nvme / ssd / hdd
    public var uptimeSec: UInt64?
    public var tempC: Double?
    public var tempBoardC: Double?
    public var linkMbps: Int?           // скорость активного аплинка (Mbps)
    public var cpuPct: Double?
    public var netUp: Double?           // B/s
    public var netDown: Double?         // B/s
    public var diskRead: Double?        // B/s
    public var diskWrite: Double?       // B/s

    public var ramUsed: UInt64? {
        guard let t = ramTotal, let p = ramUsedPct else { return nil }
        return UInt64(Double(t) * p / 100)
    }

    public var uptimeText: String? {
        guard let s = uptimeSec else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    public var isOnline: Bool { status == .online }

    public init(host: HostConfig) { self.host = host }
}

// MARK: - Парсер вывода SSH

public struct RawCounters: Equatable, Sendable {
    public var netRx: UInt64?
    public var netTx: UInt64?
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
}

public struct SampleState: Equatable, Sendable {
    public var snapshot: HostSnapshot
    public var counters: RawCounters
    public var timestamp: Date
}

public enum SampleEngineError: Error, LocalizedError {
    case badInteger(String)
    public var errorDescription: String? {
        switch self {
        case .badInteger(let k): return "Не удалось разобрать число для \(k)"
        }
    }
}

public enum OutputParser {
    /// Парсит ключи `HL_KEY=value` из вывода; ключ = промежуток слева от первого '='.
    public static func keyValues(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.hasPrefix("HL_"), let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[s.startIndex ..< eq])
            let val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            map[key] = val
        }
        return map
    }
}

// MARK: - Построитель snapshot из вывода

public final class SampleEngine {
    /// Строит свежий snapshot и состояние для следующей дельты из вывода batch-команд.
    public static func apply(_ output: String, host: HostConfig, pingMs: Double?,
                             previous: SampleState?, now: Date = Date()) throws -> SampleState {
        let kv = OutputParser.keyValues(output)
        var snap = HostSnapshot(host: host)
        snap.pingMs = pingMs
        snap.status = .online

        snap.os = HostOS(rawValue: kv["HL_OS"] ?? "") ?? .unknown
        let hn = kv["HL_HOSTNAME"] ?? ""
        snap.hostname = hn.isEmpty ? nil : hn
        snap.cores = kv["HL_CORES"].flatMap(Int.init)
        let memTotal = kv["HL_MEM_TOTAL"].flatMap(UInt64.init)
        snap.ramTotal = memTotal
        if let total = memTotal, let used = kv["HL_MEM_USED"].flatMap(UInt64.init), total > 0 {
            snap.ramUsedPct = Double(used) / Double(total) * 100
        }
        snap.diskTotal = kv["HL_DISK_TOTAL"].flatMap(UInt64.init)
        let kind = kv["HL_DISKKIND"] ?? ""
        snap.diskKind = kind.isEmpty ? nil : kind
        snap.uptimeSec = kv["HL_UPTIME"].flatMap(UInt64.init)
        snap.tempC = kv["HL_TEMP"].flatMap(Double.init)
        snap.tempBoardC = kv["HL_TEMP_BOARD"].flatMap(Double.init)
        snap.linkMbps = kv["HL_LINK"].flatMap(Int.init)
        snap.cpuPct = kv["HL_CPU"].flatMap(Double.init)

        var counters = RawCounters()
        counters.netRx = kv["HL_NET_RX"].flatMap(UInt64.init)
        counters.netTx = kv["HL_NET_TX"].flatMap(UInt64.init)
        counters.diskReadBytes = kv["HL_DISK_R"].flatMap(UInt64.init)
        counters.diskWriteBytes = kv["HL_DISK_W"].flatMap(UInt64.init)

        let now = now

        if let p = previous {
            let dt = now.timeIntervalSince(p.timestamp)
            if dt > 0 {
                if let n = counters.netTx, let o = p.counters.netTx, n >= o {
                    snap.netUp = Double(n - o) / dt
                }
                if let n = counters.netRx, let o = p.counters.netRx, n >= o {
                    snap.netDown = Double(n - o) / dt
                }
                if let n = counters.diskWriteBytes, let o = p.counters.diskWriteBytes, n >= o {
                    snap.diskWrite = Double(n - o) / dt
                }
                if let n = counters.diskReadBytes, let o = p.counters.diskReadBytes, n >= o {
                    snap.diskRead = Double(n - o) / dt
                }
            }
        }

        return SampleState(snapshot: snap, counters: counters, timestamp: now)
    }
}

// MARK: - Построитель SSH batch-команд

public enum CommandBatch {
    /// Один самоопределяющийся батч: по `uname -s` выбирает ветку macOS/Linux и
    /// собирает ВСЕ метрики. Что недоступно на конкретной ОС — отдаётся пустым →
    /// парсер трактует как N/A. На хосте ничего не ставится; только стандартные утилиты.
    ///
    /// * Диск: суммарный объём ФИЗИЧЕСКИХ дисков (без сетевых/монтируемых томов).
    ///   Linux — `lsblk` (целые диски), macOS — `diskutil list` (internal-physical).
    /// * Температура: Linux — `/sys/class/thermal` (CPU-зоны и плата); macOS —
    ///   нечитаема без root (`powermetrics` требует sudo) → N/A.
    /// * Аплинк: самая быстрая поднятая физическая пасс-скорость (Linux `/sys/class/net/*/speed`,
    ///   macOS `ifconfig … media`). Виртуальные интерфейсы (veth/cilium/docker/lo и т.п.) отбрасываются.
    /// * Тип диска: nvme / ssd / hdd по имени блок-устройства и флагу rotational.
    public static func build(for host: HostConfig) -> String {
        let mac = [
            "echo HL_OS=macos",
            "echo HL_HOSTNAME=$(hostname)",
            "echo HL_CORES=$(sysctl -n hw.ncpu)",
            "boot=$(sysctl -n kern.boottime | awk -F'[,=]' '{gsub(/[^0-9]/,\"\",$2); print $2}'); u=$(( $(date +%s) - boot )); echo HL_UPTIME=$u",
            "total=$(sysctl -n hw.memsize); ps=$(sysctl -n hw.pagesize)",
            "act=$(vm_stat | awk '/Pages active/{print $3}' | tr -d '.'); ina=$(vm_stat | awk '/Pages inactive/{print $3}' | tr -d '.'); spec=$(vm_stat | awk '/Pages speculative/{print $3}' | tr -d '.'); fb=$(vm_stat | awk '/File-backed pages/{print $3}' | tr -d '.'); wd=$(vm_stat | awk '/Pages wired down/{print $4}' | tr -d '.'); oc=$(vm_stat | awk '/Pages occupied by compressor/{print $5}' | tr -d '.'); used=$(( ( (act+ina+spec-fb) + wd + oc ) * ps )); echo HL_MEM_TOTAL=$total; echo HL_MEM_USED=$used",
            // Объём физических внутренних дисков (без NFS/сетевых и без задвоения APFS-слайсов).
            "echo HL_DISK_TOTAL=$(df -b 1 / 2>/dev/null | tail -1 | awk '{print $2*512}')",
            "bootproto=$(diskutil info / | awk -F: '/Protocol/{gsub(/ /,\"\",$2); print toupper($2)}'); case \"$bootproto\" in *SATA*) echo HL_DISKKIND=ssd;; *) echo HL_DISKKIND=nvme;; esac",
            // Температура CPU/платы на macOS без root недоступна (powermetrics требует sudo).
            "echo HL_TEMP=",
            "echo HL_TEMP_BOARD=",
            // Самая быстрая медиа-скорость активного проводного аплинка (напр. 100baseT→100, 1000baseT→1000).
            "echo HL_LINK=$(ifconfig -l | tr ' ' '\\n' | grep -E '^(en|eth|wl|enx)' | while read i; do ifconfig $i 2>/dev/null | grep -oE '[0-9]{3,5}baseT' | head -1 | tr -d 'baseT'; done | sort -n | tail -1)",
            "echo HL_NET_RX=$(netstat -ib | awk 'NR>1{rx+=$7; tx+=$12} END{print rx+0}')",
            "echo HL_NET_TX=$(netstat -ib | awk 'NR>1{rx+=$7; tx+=$12} END{print tx+0}')",
            "echo HL_CPU=$(top -l 1 -n 0 | awk '/CPU usage/{gsub(/%/,\"\",$7); print 100-$7; exit}')",
            "io=$(iostat -w 1 -c 2 2>/dev/null | awk '/disk[0-9]/&&NF<6{for(i=1;i<=NF;i++){if($i~/^disk[0-9]/)nd++}} /^[[:space:]]*[0-9]/{for(i=3;i<=3*nd;i+=3){s+=$i}} END{print int(s*1048576)}'); echo HL_DISK_R=$io",
            "echo HL_DISK_W=",
        ].joined(separator: " ; ")
        let linux = [
            "echo HL_OS=linux",
            "echo HL_HOSTNAME=$(hostname)",
            "echo HL_CORES=$(nproc)",
            "echo HL_UPTIME=$(awk '{print int($1)}' /proc/uptime)",
            "echo HL_MEM_TOTAL=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)",
            "echo HL_MEM_USED=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print (t-a)*1024}' /proc/meminfo)",
            // Сумма объёма всех физических блочных дисков (без loop/zram) — «как на коробке».
            "echo HL_DISK_TOTAL=$(df -B1 / 2>/dev/null | tail -1 | awk '{print $2}')",
            "echo HL_DISKKIND=$(lsblk -dbrno NAME,TYPE,ROTA 2>/dev/null | awk '$2 == \"disk\" && $1 !~ /^(loop|zram|ram)/ { if($1 ~ /nvme/) nv=1; else if($3==0) ss=1; else hd=1 } END { if(nv) print \"nvme\"; else if(ss) print \"ssd\"; else if(hd) print \"hdd\" }')",
            // Температура: pkg/soc-зоны → CPU, остальные (acpitz/pch) → плата.
            "zt=\"\"; for z in /sys/class/thermal/thermal_zone*; do [ -r $z/temp ] || continue; t=$(cat $z/temp 2>/dev/null); ty=$(cat $z/type 2>/dev/null); [ -z \"$t\" ] && continue; zt=\"$zt $ty:$t\"; done; echo $zt | awk '{cb=-1; bb=-1; for(i=1;i<=NF;i++){split($i,a,\":\"); v=a[2]/1000; if(a[1] ~ /x86_pkg_temp|cpu_thermal|soc_thermal|tsens|package/) { if(v>cb) cb=v } else if(v>bb) bb=v }; if(cb<0 && bb>=0) cb=bb; if(cb>=0) printf \"HL_TEMP=%.1f\\n\", cb; if(bb>=0) printf \"HL_TEMP_BOARD=%.1f\\n\", bb}'",
            // Скорость реального аплинка = интерфейс маршрута по умолчанию, иначе самая быстрая поднятая физическая.
            "echo HL_LINK=$(gw=$(awk '$2==\"00000000\"{print $1; exit}' /proc/net/route 2>/dev/null); case \"$gw\" in lo|tun*|utun*|wg*|veth*|cilium_*|lxc_*|docker*|br-*|virbr*) gw=\"\";; esac; s=\"\"; [ -n \"$gw\" ] && s=$(cat /sys/class/net/$gw/speed 2>/dev/null); case \"$s\" in \"\"|0|-1) s=\"\";; esac; [ -z \"$s\" ] && s=$(for f in /sys/class/net/*/speed; do d=$(basename $(dirname $f)); [ \"$(cat $(dirname $f)/operstate 2>/dev/null)\" = up ] || continue; case \"$d\" in lo|cilium_*|lxc_*|docker*|veth*|br-*|virbr*|tun*|tap*|vnet*|utun*|wg*) continue;; esac; sp=$(cat $f 2>/dev/null); case \"$sp\" in \"\"|0|-1) ;; *) echo $sp ;; esac; done | sort -n | tail -1); case \"$s\" in \"\"|0|-1) s=\"\";; esac; echo $s)",
            "echo HL_NET_RX=$(awk 'NR>2{gsub(/:/,\"\",$1); rx+=$2; tx+=$10} END{print rx+0}' /proc/net/dev)",
            "echo HL_NET_TX=$(awk 'NR>2{gsub(/:/,\"\",$1); rx+=$2; tx+=$10} END{print tx+0}' /proc/net/dev)",
            "echo HL_CPU=$(top -bn1 2>/dev/null | awk '/(%?[Cc][Pp][Uu])\\(s\\):/{gsub(/%/,\"\",$8); print 100-$8; exit}')",
            "echo HL_DISK_R=$(awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/{r+=$6*512} END{print r+0}' /proc/diskstats)",
            "echo HL_DISK_W=$(awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/{w+=$10*512} END{print w+0}' /proc/diskstats)",
        ].joined(separator: " ; ")
        return "echo __HOMELAB_START__ ; case \"$(uname -s)\" in Darwin) \(mac) ;; Linux) \(linux) ;; *) echo HL_OS=unknown ;; esac"
    }
}

// MARK: - Утилиты форматирования

public enum Format {
    public static func bytesPerSecond(_ bps: Double?) -> String {
        guard let v = bps else { return "N/A" }
        if v >= 1_048_576 { return String(format: "%.1f M/s", v / 1_048_576) }
        if v >= 1_024 { return String(format: "%.1f K/s", v / 1_024) }
        return String(format: "%.0f B/s", v)
    }

    public static func gb(_ b: UInt64?) -> String {
        guard let b else { return "—" }
        let g = Double(b) / 1_000_000_000
        if g >= 1000 { return String(format: "%.2f TB", g / 1000) }
        return String(format: "%.1f GB", g)
    }

    public static func bytes(_ b: UInt64?) -> String {
        guard let v = b else { return "N/A" }
        let f = Double(v)
        if f >= 1_073_741_824 { return String(format: "%.1f G", f / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.1f M", f / 1_048_576) }
        if f >= 1_024 { return String(format: "%.1f K", f / 1_024) }
        return "\(v) B"
    }

    public static func percent(_ d: Double?) -> String {
        guard let v = d else { return "--" }
        return String(format: "%.0f%%", v)
    }

    public static func ping(_ ms: Double?) -> String {
        guard let v = ms else { return "-- ms" }
        return String(format: "%.0f ms", v)
    }

    /// Скорость аплинка: 1000→"1G", 2500→"2.5G", 10000→"10G", 100→"100M".
    public static func link(_ mbps: Int?) -> String {
        guard let v = mbps, v > 0 else { return "—" }
        if v >= 1000 {
            let g = Double(v) / 1000
            if g == Double(Int(g)) { return String(format: "%.0fG", g) }
            return String(format: "%.1fG", g)
        }
        return "\(v)M"
    }

    /// Температура в компактном виде; nil → «—» (нет датчика).
    public static func temp(_ c: Double?) -> String {
        guard let v = c else { return "—" }
        return String(format: "%.0f°", v)
    }
}