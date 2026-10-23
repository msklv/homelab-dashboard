import Foundation

// MARK: - Общие модели

public enum HostStatus: Equatable, Sendable {
    case pending, online, offline
}

/// Одна GPU: имя, VRAM в байтах, загрузка %.
/// Для Apple Silicon «VRAM» — управляемая GPU память (в лимите iogpu.wired_limit_mb),
/// total = лимит (по умолчанию ¾ RAM), used = «In use system memory» из AGX-статистики.
public struct GpuInfo: Equatable, Sendable {
    public var name: String
    public var memTotal: UInt64   // bytes
    public var memUsed: UInt64    // bytes
    public var utilPct: Double    // 0–100

    public var memUsedPct: Double? {
        guard memTotal > 0 else { return nil }
        return min(100, Double(memUsed) / Double(memTotal) * 100)
    }

    public init(name: String, memTotal: UInt64, memUsed: UInt64, utilPct: Double) {
        self.name = name
        self.memTotal = memTotal
        self.memUsed = memUsed
        self.utilPct = utilPct
    }
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
    public var diskTotal: UInt64?       // bytes — объём ФС корневого раздела /
    public var diskAvail: UInt64?       // bytes — свободно на корневом разделе /
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
    /// Есть ли на хосте GPU (дешёвый флаг из основного батча; управляет видимостью кнопки GPU).
    public var hasGpu: Bool?
    /// Детальные GPU-метрики — опрашиваются ОТДЕЛЬНЫМ запросом, только пока
    /// GPU-панель карточки раскрыта. nil — панель не опрашивалась / данных нет.
    public var gpus: [GpuInfo]? = nil

    public var ramUsed: UInt64? {
        guard let t = ramTotal, let p = ramUsedPct else { return nil }
        return UInt64(Double(t) * p / 100)
    }

    /// Доля СВОБОДНОГО места на корневом разделе (0–100). nil — если нет пары total/avail.
    public var diskFreePct: Double? {
        guard let t = diskTotal, let a = diskAvail, t > 0 else { return nil }
        return Double(a) / Double(t) * 100
    }

    public var diskUsedPct: Double? {
        guard let f = diskFreePct else { return nil }
        return 100 - f
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
    public init() {}
}

public struct SampleState: Equatable, Sendable {
    public var snapshot: HostSnapshot
    public var counters: RawCounters
    public var timestamp: Date
    public init(snapshot: HostSnapshot, counters: RawCounters, timestamp: Date) {
        self.snapshot = snapshot
        self.counters = counters
        self.timestamp = timestamp
    }
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

    /// Собирает ВСЕ значения одного повторяющегося ключа (по порядку строк) —
    /// для многострочных метрик вроде `HL_GPU=name|total|used|pct` (по строке на GPU).
    public static func allValues(_ output: String, key: String) -> [String] {
        var out: [String] = []
        for line in output.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.hasPrefix(key + "=") else { continue }
            let val = String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if !val.isEmpty { out.append(val) }
        }
        return out
    }
}

// MARK: - Парсер GPU-строк

public enum GpuParser {
    /// Строка `name|memTotalBytes|memUsedBytes|utilPct` → GpuInfo. Кривые части → nil.
    public static func parseLine(_ s: String) -> GpuInfo? {
        let parts = s.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let total = UInt64(parts[1]),
              let used = UInt64(parts[2]),
              let pct = Double(parts[3]) else { return nil }
        return GpuInfo(name: name, memTotal: total, memUsed: used, utilPct: max(0, min(100, pct)))
    }

    /// Разбирает все `HL_GPU=` строки batch-вывода.
    public static func parse(_ output: String) -> [GpuInfo] {
        OutputParser.allValues(output, key: "HL_GPU").compactMap(parseLine)
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
        snap.diskAvail = kv["HL_DISK_AVAIL"].flatMap(UInt64.init)
        let kind = kv["HL_DISKKIND"] ?? ""
        snap.diskKind = kind.isEmpty ? nil : kind
        snap.uptimeSec = kv["HL_UPTIME"].flatMap(UInt64.init)
        snap.tempC = kv["HL_TEMP"].flatMap(Double.init)
        snap.tempBoardC = kv["HL_TEMP_BOARD"].flatMap(Double.init)
        snap.linkMbps = kv["HL_LINK"].flatMap(Int.init)
        snap.cpuPct = kv["HL_CPU"].flatMap(Double.init)
        // Флаг наличия GPU из основного батча (дешёвая проверка). Детальные gpus
        // в основном батче НЕ собираются — их несёт отдельный GPU-запрос; при
        // каждом обычном опросе переносим последний GPU-снимок, пока панель жива.
        switch kv["HL_GPU"] ?? "" {
        case "1": snap.hasGpu = true
        case "0": snap.hasGpu = false
        default: snap.hasGpu = nil
        }
        snap.gpus = previous?.snapshot.gpus

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
    /// * Диск (total + avail): объём и свободное место ФС КОРНЕВОГО раздела `/`
    ///   (`df /`). На однонишниковых серверах совпадает с объёмом диска;
    ///   это тот же раздел, размер которого показывается в шапке карточки.
    ///   Не сумма физических дисков. Тип диска (`DISKKIND`) определяется отдельно.
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
            // Объём и свободное место корневого раздела / (df /); раздел из шапки карточки.
            "echo HL_DISK_TOTAL=$(df -b 1 / 2>/dev/null | tail -1 | awk '{print $2*512}')",
            "echo HL_DISK_AVAIL=$(df -b 1 / 2>/dev/null | tail -1 | awk '{print $4*512}')",
            // Тип диска (macOS): по протоколу корневого устройства — SATA→ssd, иначе nvme.
            // НЕДОЧЁТ: rotational не проверяется, поэтому SATA-HDD будет помечен ssd.
            "bootproto=$(diskutil info / | awk -F: '/Protocol/{gsub(/ /,\"\",$2); print toupper($2)}'); case \"$bootproto\" in *SATA*) echo HL_DISKKIND=ssd;; *) echo HL_DISKKIND=nvme;; esac",
            // Температура CPU/платы на macOS без root недоступна (powermetrics требует sudo).
            "echo HL_TEMP=",
            "echo HL_TEMP_BOARD=",
            // Самая быстрая медиа-скорость активного проводного аплинка (напр. 100baseT→100, 1000baseT→1000).
            "echo HL_LINK=$(ifconfig -l | tr ' ' '\\n' | grep -E '^(en|eth|wl|enx)' | while read i; do ifconfig $i 2>/dev/null | grep -oE '[0-9]{3,5}baseT' | head -1 | tr -d 'baseT'; done | sort -n | tail -1)",
            // Наличие GPU (дешёвый флаг для кнопки GPU в UI): Apple Silicon (AGX) или
            // PCI-класс 0300 (VGA-совместимый). Детальные метрики — отдельным gpuProbe-запросом.
            "g=0; ioreg -c AGXAccelerator 2>/dev/null | grep -q AGXAccelerator && g=1; [ $g = 0 ] && ioreg -c IOPCIDevice -l 2>/dev/null | grep class-code | grep -q 00000300 && g=1; echo HL_GPU=$g",
            // Net RX/TX: суммируем ТОЛЬКО link-слой (по одной строке на интерфейс, иначе
            // интерфейс с несколькими IP/en0 с IPv6 задваивает счётчики в N раз) и только
            // физические en*/eth*. Колонки netstat -ib: $7=Ibytes(RX), $10=Obytes(TX) (не $12).
            "echo HL_NET_RX=$(netstat -ib | awk '$3 ~ /^<Link/ && $1 ~ /^(en|enx|eth|enP)/ {rx+=$7; tx+=$10} END{print rx+0}')",
            "echo HL_NET_TX=$(netstat -ib | awk '$3 ~ /^<Link/ && $1 ~ /^(en|enx|eth|enP)/ {rx+=$7; tx+=$10} END{print tx+0}')",
            "echo HL_CPU=$(top -l 2 -n 0 -s 1 2>/dev/null | awk '/CPU usage/{gsub(/,/,\" \"); for(i=1;i<=NF;i++) if($i==\"idle\") v=100-$(i-1)} END{print v}')",
            // Живой CPU — 2-й сэмпл top -l 2 (первый -l 1/`-bn1` = среднее с загрузки).
            // Кумулятивные байты диска из ioreg (без root): SampleEngine берёт дельту
            // (n−o)/dt → MB/s, поэтому нужен монотонный счётчик, а не MB/s-рейт iostat.
            "echo HL_DISK_R=$(ioreg -c IOBlockStorageDriver -r -w 0 2>/dev/null | grep -o '\"Bytes (Read)\"=[0-9]*' | cut -d= -f2 | awk '{s+=$1} END{print s+0}')",
            "echo HL_DISK_W=$(ioreg -c IOBlockStorageDriver -r -w 0 2>/dev/null | grep -o '\"Bytes (Write)\"=[0-9]*' | cut -d= -f2 | awk '{s+=$1} END{print s+0}')",
        ].joined(separator: " ; ")
        let linux = [
            "echo HL_OS=linux",
            "echo HL_HOSTNAME=$(hostname)",
            "echo HL_CORES=$(nproc)",
            "echo HL_UPTIME=$(awk '{print int($1)}' /proc/uptime)",
            "echo HL_MEM_TOTAL=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)",
            "echo HL_MEM_USED=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print (t-a)*1024}' /proc/meminfo)",
            // Объём и свободное место корневого раздела / (df /); раздел из шапки карточки.
            "echo HL_DISK_TOTAL=$(df -B1 / 2>/dev/null | tail -1 | awk '{print $2}')",
            "echo HL_DISK_AVAIL=$(df -B1 / 2>/dev/null | tail -1 | awk '{print $4}')",
            "echo HL_DISKKIND=$(lsblk -dbrno NAME,TYPE,ROTA 2>/dev/null | awk '$2 == \"disk\" && $1 !~ /^(loop|zram|ram)/ { if($1 ~ /nvme/) nv=1; else if($3==0) ss=1; else hd=1 } END { if(nv) print \"nvme\"; else if(ss) print \"ssd\"; else if(hd) print \"hdd\" }')",
            // Температура — приоритетный список источников (первый непустой выигрывает):
            // CPU: 1) hwmon k10temp/zenpower (AMD Tctl/Tdie) / coretemp (Intel pkg) / cpu_thermal
            //      2) thermal_zone package-типа (x86_pkg_temp, cpu-thermal, soc_thermal, tsens)
            //      3) acpitz — только если больше нечего (на многих платах это заглушка 20°C)
            // Плата: 1) hwmon SuperIO (nct6xxx/it87/f718xx/asus/dell_smm/thinkpad)
            //        2) прочие thermal_zone (не CPU-типа и не acpitz)
            "cpu=\"\"; brd=\"\"; for h in /sys/class/hwmon/hwmon*; do [ -r \"$h/name\" ] || continue; n=$(cat \"$h/name\" 2>/dev/null); case \"$n\" in *k10temp*|*zenpower*|*coretemp*|*cpu_thermal*|*soc_thermal*) for f in \"$h\"/temp*_input; do [ -r \"$f\" ] || continue; r=$(cat \"$f\" 2>/dev/null); [ -n \"$r\" ] || continue; v=$((r/1000)); [ \"$v\" -gt \"${cpu:-0}\" ] && cpu=$v; done ;; *nct6*|*it87*|*f718*|*asus*|*dell_smm*|*thinkpad*|*applesmc*|*nzxt*) for f in \"$h\"/temp*_input; do [ -r \"$f\" ] || continue; r=$(cat \"$f\" 2>/dev/null); [ -n \"$r\" ] || continue; v=$((r/1000)); [ \"$v\" -gt \"${brd:-0}\" ] && brd=$v; done ;; esac; done; zcpu=\"\"; zbrd=\"\"; zacp=\"\"; for z in /sys/class/thermal/thermal_zone*; do [ -r \"$z/temp\" ] || continue; ty=$(cat \"$z/type\" 2>/dev/null); r=$(cat \"$z/temp\" 2>/dev/null); [ -n \"$r\" ] || continue; v=$((r/1000)); case \"$ty\" in *x86_pkg_temp*|*cpu_thermal*|*cpu-thermal*|*soc_thermal*|*soc-thermal*|*package*|*tsens*) [ \"$v\" -gt \"${zcpu:-0}\" ] && zcpu=$v ;; acpitz) [ \"$v\" -gt \"${zacp:-0}\" ] && zacp=$v ;; *) [ \"$v\" -gt \"${zbrd:-0}\" ] && zbrd=$v ;; esac; done; [ -z \"$cpu\" ] && cpu=$zcpu; [ -z \"$brd\" ] && brd=$zbrd; if [ -z \"$brd\" ] && [ -n \"$zacp\" ]; then if [ -z \"$cpu\" ] || [ \"$zacp\" -ge $((cpu-10)) ]; then brd=$zacp; fi; fi; [ -z \"$cpu\" ] && cpu=$zacp; [ -n \"$cpu\" ] && echo HL_TEMP=$cpu; [ -n \"$brd\" ] && echo HL_TEMP_BOARD=$brd",
            // Скорость реального аплинка = интерфейс маршрута по умолчанию, иначе самая быстрая поднятая физическая.
            "echo HL_LINK=$(gw=$(awk '$2==\"00000000\"{print $1; exit}' /proc/net/route 2>/dev/null); case \"$gw\" in lo|tun*|utun*|wg*|veth*|cilium_*|lxc_*|docker*|br-*|virbr*) gw=\"\";; esac; s=\"\"; [ -n \"$gw\" ] && s=$(cat /sys/class/net/$gw/speed 2>/dev/null); case \"$s\" in \"\"|0|-1) s=\"\";; esac; [ -z \"$s\" ] && s=$(for f in /sys/class/net/*/speed; do d=$(basename $(dirname $f)); [ \"$(cat $(dirname $f)/operstate 2>/dev/null)\" = up ] || continue; case \"$d\" in lo|cilium_*|lxc_*|docker*|veth*|br-*|virbr*|tun*|tap*|vnet*|utun*|wg*) continue;; esac; sp=$(cat $f 2>/dev/null); case \"$sp\" in \"\"|0|-1) ;; *) echo $sp ;; esac; done | sort -n | tail -1); case \"$s\" in \"\"|0|-1) s=\"\";; esac; echo $s)",
            "echo HL_NET_RX=$(awk 'NR>2{gsub(/:/,\"\",$1); if($1 ~ /^(eth|en|wl)/){rx+=$2; tx+=$10}} END{print rx+0}' /proc/net/dev)",
            "echo HL_NET_TX=$(awk 'NR>2{gsub(/:/,\"\",$1); if($1 ~ /^(eth|en|wl)/){rx+=$2; tx+=$10}} END{print tx+0}' /proc/net/dev)",
            // Наличие GPU (дешёвый флаг для кнопки GPU в UI): nvidia-smi в PATH ИЛИ
            // amdgpu sysfs (mem_info_vram_total). «Любой drm card» не берём — virtio/qxl
            // в ВМ дал бы пустую кнопку. Детальные метрики — отдельным gpuProbe-запросом.
            "g=0; command -v nvidia-smi >/dev/null 2>&1 && g=1; for c in /sys/class/drm/card*/device; do [ -r \"$c/mem_info_vram_total\" ] && g=1; done; echo HL_GPU=$g",
            // Живой CPU: -bn2, 2-я итерация = интервал за 1с (первая -bn1 = среднее с загрузки).
            // Парсинг ПО ТОКЕНАМ (ищем "id"), НЕ по позиции $8: на гостевых top при idle=100.0
            // значение слипает с меткой ("ni,100.0"), все поля сдвигаются и 100-$8 даёт ложный 100%.
            // LC_ALL=C ОБЯЗАТЕЛЕН: на хостах с ru locale top печатает дробь через запятую
            // ("97,3 id"), gsub сносит и разделитель, и десятичную запятую ("97 3 id"),
            // парсер читает дробную часть ("3") как idle -> ложные ~97% CPU на пустой машине.
            "echo HL_CPU=$(LC_ALL=C top -bn2 -d 1 2>/dev/null | awk '/%?[Cc][Pp][Uu]\\(s\\):/{gsub(/,/,\" \"); for(i=1;i<=NF;i++) if($i==\"id\") v=100-$(i-1)} END{print v}')",
            "echo HL_DISK_R=$(awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/{r+=$6*512} END{print r+0}' /proc/diskstats)",
            "echo HL_DISK_W=$(awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/{w+=$10*512} END{print w+0}' /proc/diskstats)",
        ].joined(separator: " ; ")
        // Зашита от zsh: у него несовпавший глоб («no matches found») роняет ВЕСЬ
        // командный строкой с exit 1 (bash/sh передают глоб литералом дальше). На
        // хостах без /sys/class/thermal (напр. TrueNAS) это обрывало батч в начале →
        // дашборд видел ненулевой exit и помечал хост offline. null_glob — штатный аналог
        // bash-поведения; в sh/bash условие ложно и нетривиального эффекта не даёт.
        return "[ -n \"$ZSH_VERSION\" ] && setopt null_glob 2>/dev/null; echo __HOMELAB_START__ ; case \"$(uname -s)\" in Darwin) \(mac) ;; Linux) \(linux) ;; *) echo HL_OS=unknown ;; esac"
    }

    /// Отдельный GPU-зонд: выполняется ВТОРОЙ ssh-сессией и только пока
    /// GPU-панель карточки раскрыта (в основной батч не входит — экономим хост).
    /// Выводит по строке `HL_GPU=name|memTotalBytes|memUsedBytes|utilPct` на GPU.
    /// * Linux: `nvidia-smi` (CSV без units; MiB → байты); если утилиты нет —
    ///   amdgpu sysfs (`mem_info_vram_*` — байты как есть, `gpu_busy_percent`),
    ///   имя карты из `lspci -mm` (поле 6), иначе `pci.ids` по PCI_ID из uevent,
    ///   иначе «AMD GPU <id>» — но никогда не имя каталога sysfs (`card0`).
    /// * macOS (Apple Silicon): `AGXAccelerator` → PerformanceStatistics:
    ///   «Device Utilization %» и «In use system memory» — точное поле, без
    ///   варианта `(driver)`; всего = лимит `iogpu.wired_limit_mb` (0/нет → ¾ RAM).
    /// Кавычки — тот же уровень, что в build(): `\"` сдирает удалённый шелл.
    /// Awk-программы в ОДИНАРНЫХ кавычках шелла, поэтому двойные внутри — простые.
    /// Проверка вживую: `Dashboard --gpucheck <ssh-строка>`.
    public static func gpuProbe(for host: HostConfig) -> String {
        let mac = "lim=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null); tot=$(sysctl -n hw.memsize); case \"$lim\" in ''|*[!0-9]*) lim=0;; esac; if [ \"$lim\" -gt 0 ]; then vt=$((lim*1048576)); else vt=$((tot*3/4)); fi; gn=$(sysctl -n machdep.cpu.brand_string 2>/dev/null); ioreg -r -c AGXAccelerator 2>/dev/null | awk -v n=\"$gn\" -v T=\"$vt\" '/\"PerformanceStatistics\"/{u=-1;m=-1; if(match($0,/\"Device Utilization %\"=[0-9]+/)){s=substr($0,RSTART,RLENGTH);sub(/.*=/,\"\",s);u=s+0} if(match($0,/\"In use system memory\"=[0-9]+/)){s=substr($0,RSTART,RLENGTH);sub(/.*=/,\"\",s);m=s+0} if(u>=0) printf \"HL_GPU=%s|%.0f|%.0f|%.0f\\n\", n, T, m, u}'"
        let linux = "if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk -F, '{nm=$1; gsub(/^ +| +$/,\"\",nm); t=$2; u=$3; p=$4; gsub(/[^0-9.]/,\"\",t); gsub(/[^0-9.]/,\"\",u); gsub(/[^0-9.]/,\"\",p); if(nm==\"\") next; printf \"HL_GPU=%s|%d|%d|%d\\n\", nm, t*1048576, u*1048576, p+0}'; else for c in /sys/class/drm/card*/device; do [ -r \"$c/mem_info_vram_total\" ] || continue; t=$(cat \"$c/mem_info_vram_total\" 2>/dev/null); u=$(cat \"$c/mem_info_vram_used\" 2>/dev/null); p=$(cat \"$c/gpu_busy_percent\" 2>/dev/null); id=$(sed -n 's/^PCI_ID=//p' \"$c/uevent\" 2>/dev/null | head -1); case \"${id%%:*}\" in 1002) pfx=AMD;; 10de) pfx=NVIDIA;; 8086) pfx=Intel;; *) pfx=;; esac; nm=\"\"; if command -v lspci >/dev/null 2>&1; then bdf=$(basename \"$(readlink -f \"$c\" 2>/dev/null)\" 2>/dev/null); [ -n \"$bdf\" ] && nm=$(lspci -s \"$bdf\" -mm 2>/dev/null | cut -d'\"' -f6); fi; if [ -z \"$nm\" ] || [ \"$nm\" != \"${nm#Device }\" ]; then for f in /usr/share/hwdata/pci.ids /usr/share/misc/pci.ids /usr/share/pci.ids; do [ -r \"$f\" ] || continue; nm=$(awk -v v=${id%%:*} -v d=${id##*:} '{ if ($0 !~ /^[[:space:]]/ && length($1)==4 && $1 ~ /^[0-9a-fA-F]+$/) cur=tolower($1); else if (cur==v && tolower($1)==d && $0 ~ /^[[:space:]][^[:space:]]/) { sub(/^[[:space:]]+[0-9a-fA-F]+[[:space:]]+/, \"\"); print; exit } }' \"$f\" 2>/dev/null); [ -n \"$nm\" ] && break; done; fi; [ -z \"$nm\" ] && nm=\"GPU ${id:-?}\"; [ -n \"$pfx\" ] && [ \"${nm#$pfx }\" = \"$nm\" ] && nm=\"$pfx $nm\"; echo \"HL_GPU=$nm|${t:-0}|${u:-0}|${p:-0}\"; done; fi"
        // Тот же zsh-guard, что в build(): gpuProbe тоже содержит глобы.
        return "[ -n \"$ZSH_VERSION\" ] && setopt null_glob 2>/dev/null; echo __HOMELAB_START__ ; case \"$(uname -s)\" in Darwin) \(mac) ;; Linux) \(linux) ;; esac"
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