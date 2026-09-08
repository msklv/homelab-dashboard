import Foundation

public enum HostOS: String, Sendable {
    case linux, macos, unknown
}

public enum ThemeMode: String, Sendable {
    case system, light, dark
}

public struct Thresholds: Equatable, Sendable {
    public var warning: Int
    public var critical: Int
    public static let `default` = Thresholds(warning: 60, critical: 85)
}

public struct TagDef: Equatable, Sendable {
    public var name: String
    public var color: String
    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

/// Одна секция-группа в конфиге. `collapsed` — начальное состояние UI
/// (свёрнутая группа в поллере не опрашивается) и персистится в YAML.
public struct GroupDef: Equatable, Sendable {
    public var name: String
    public var collapsed: Bool
    public init(name: String, collapsed: Bool = false) {
        self.name = name
        self.collapsed = collapsed
    }
}

public struct HostConfig: Equatable, Sendable {
    public var name: String
    public var ssh: String
    /// Необязательное поле: секция-группа. Если пусто — хост попадёт в «Прочее».
    public var group: String?
    /// Необязательное поле: теги для фильтрации (описаны в блоке `tags`).
    public var tags: [String] = []
    public var pollInterval: Int?
    public var timeout: Int?

    public init() { name = ""; ssh = "" }

    public init(name: String, ssh: String, group: String? = nil,
                tags: [String] = [], pollInterval: Int? = nil, timeout: Int? = nil) {
        self.name = name
        self.ssh = ssh
        self.group = group
        self.tags = tags
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Хост для ping: часть строки ssh до последнего '@' и до необязательного порта.
    public var pingHost: String {
        let t = SshRunner.split(ssh).0 // user@host без :port
        if let at = t.lastIndex(of: "@") {
            return String(t[t.index(after: at)...])
        }
        return t
    }
}

public struct Config: Equatable, Sendable {
    public var pollInterval: Int = 5
    public var timeout: Int = 5
    public var offlineAfterMisses: Int = 2
    public var maxConcurrent: Int = 4
    public var theme: ThemeMode = .system
    public var thresholds: Thresholds = .default
    public var groups: [GroupDef] = []
    public var tags: [TagDef] = []
    public var hosts: [HostConfig] = []

    public init() {}

    /// Интервал опроса для конкретного хоста (переопределение) либо глобальный.
    public func interval(for host: HostConfig) -> Int {
        host.pollInterval ?? pollInterval
    }

    public func timeout(for host: HostConfig) -> Int {
        host.timeout ?? timeout
    }

    /// Имя синтетической группы для хоста без группы («Прочее»).
    public static let unknownGroupName = "Прочее"
    public var unknownGroupName: String { Self.unknownGroupName }

    public var groupsWithUngrouped: [String] {
        var g = groups.map { $0.name }
        if hosts.contains(where: { $0.group == nil || ($0.group ?? "").isEmpty }) {
            if !g.contains(unknownGroupName) { g.append(unknownGroupName) }
        }
        return g
    }

    /// Свернута ли группа (персистируемое состояние из конфига).
    public func isGroupCollapsed(_ name: String) -> Bool {
        groups.first { $0.name == name }?.collapsed ?? false
    }

    /// Имена групп, начально свёрнутых (из конфига).
    public var collapsedGroupNames: Set<String> {
        Set(groups.filter { $0.collapsed }.map { $0.name })
    }

    /// Сериализация конфига обратно в YAML — для сохранения изменений в файл.
    public var yaml: String {
        var o = "# homelab-dashboard config\n"
        o += "poll_interval: \(pollInterval)\n"
        o += "timeout: \(timeout)\n"
        o += "offline_after_misses: \(offlineAfterMisses)\n"
        o += "max_concurrent: \(maxConcurrent)\n"
        o += "theme: \(theme.rawValue)\n\n"
        o += "thresholds:\n  warning: \(thresholds.warning)\n  critical: \(thresholds.critical)\n\n"
        if !groups.isEmpty {
            o += "groups:\n"
            for g in groups {
                o += "  - name: \(g.name)\n"
                if g.collapsed { o += "    collapsed: true\n" }
            }
            o += "\n"
        }
        if !tags.isEmpty {
            o += "tags:\n"
            for t in tags { o += "  - { name: \(t.name), color: \(t.color) }\n" }
            o += "\n"
        }
        o += "hosts:\n"
        for h in hosts {
            o += "  - name: \(h.name)\n    ssh: \(h.ssh)\n"
            if let g = h.group, !g.isEmpty { o += "    group: \(g)\n" }
            if !h.tags.isEmpty { o += "    tags: [\(h.tags.joined(separator: ", "))]\n" }
            if let p = h.pollInterval { o += "    poll_interval: \(p)\n" }
            if let t = h.timeout { o += "    timeout: \(t)\n" }
        }
        return o
    }
}

public enum ConfigError: Error, LocalizedError {
    case missingRequiredHostField(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredHostField(let field, let host):
            return "Host \(host): обязательное поле '\(field)' отсутствует"
        }
    }
}

public extension Config {
    /// Стандартный путь к конфигу.
    /// Приоритет: env HOMELAB_CONFIG / аргумент, затем первый существующий из
    /// `~/Library/Application Support/homelab-dashboard/config.yaml` (каноничный
    /// macOS) и `~/.config/homelab-dashboard/config.yaml` (legacy); если нет ни
    /// одного — каноничный путь (Application Support).
    static func defaultPath() -> String {
        if let p = ProcessInfo.processInfo.environment["HOMELAB_CONFIG"], !p.isEmpty { return p }
        if let idx = CommandLine.arguments.firstIndex(of: "HOMELAB_CONFIG") {
            let v = CommandLine.arguments[idx + 1]
            if !v.isEmpty { return v }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/homelab-dashboard/config.yaml").path,
            home.appendingPathComponent(".config/homelab-dashboard/config.yaml").path,
        ]
        let fm = FileManager.default
        for c in candidates where fm.fileExists(atPath: c) { return c }
        return candidates[0]
    }

    static func parse(_ yamlText: String) throws -> Config {
        let doc = try YamlMini.parseDocument(yamlText)
        let root = doc.map ?? [:]

        var c = Config()
        c.pollInterval = root["poll_interval"]?.int ?? c.pollInterval
        c.timeout = root["timeout"]?.int ?? c.timeout
        c.offlineAfterMisses = root["offline_after_misses"]?.int ?? c.offlineAfterMisses
        c.maxConcurrent = root["max_concurrent"]?.int ?? c.maxConcurrent
        if let themeStr = root["theme"]?.string, let t = ThemeMode(rawValue: themeStr) { c.theme = t }

        if let th = root["thresholds"]?.map {
            c.thresholds.warning = th["warning"]?.int ?? c.thresholds.warning
            c.thresholds.critical = th["critical"]?.int ?? c.thresholds.critical
        }

        c.groups = root["groups"]?.array?.compactMap { v -> GroupDef? in
            guard let m = v.map, let n = m["name"]?.string else { return nil }
            return GroupDef(name: n, collapsed: m["collapsed"]?.bool ?? false)
        } ?? []
        c.tags = root["tags"]?.array?.compactMap { v -> TagDef? in
            guard let m = v.map, let n = m["name"]?.string else { return nil }
            return TagDef(name: n, color: m["color"]?.string ?? "gray")
        } ?? []

        if let hostsArr = root["hosts"]?.array {
            c.hosts = try hostsArr.compactMap { v -> HostConfig? in
                guard let m = v.map,
                      let name = m["name"]?.string,
                      let ssh = m["ssh"]?.string else {
                    let nm = v.map?["name"]?.string ?? "?"
                    throw ConfigError.missingRequiredHostField("name/ssh", nm)
                }
                var h = HostConfig(name: name, ssh: ssh)
                h.group = m["group"]?.string
                h.tags = m["tags"]?.stringArray() ?? []
                h.pollInterval = m["poll_interval"]?.int
                h.timeout = m["timeout"]?.int
                return h
            }
        }
        return c
    }

    static func load(from path: String) throws -> Config {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(text)
    }
}