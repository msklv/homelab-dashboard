import AppKit
import SwiftUI
import HomelabCore

final class DashboardStore: ObservableObject {
    @Published var config: Config
    @Published var snapshots: [String: HostSnapshot] = [:]
    @Published var tagFilter: Set<String> = []
    @Published var themeOverride: ThemeMode?
    @Published var errorMessage: String?
    @Published var pausedHosts: Set<String> = []

    public let log: LogStore

    private var poller: Poller?
    private var watcher: ConfigWatcher?
    private(set) var path: String

    init(path: String, log: LogStore) {
        self.path = path
        self.log = log
        self.config = (try? Config.load(from: path)) ?? Config()
        let saved = UserDefaults.standard.string(forKey: "themeOverride")
        self.themeOverride = saved.flatMap(ThemeMode.init(rawValue:))
    }

    func start() {
        guard poller == nil else { return }
        log.log(.info, "app", "Запуск: конфиг \(path), хостов: \(config.hosts.count)")
        startPoller(with: config)

        let watcher = ConfigWatcher(path: path)
        watcher.onChange = { [weak self] in
            guard let self else { return }
            if let c = try? Config.load(from: self.path) {
                DispatchQueue.main.async { self.reload(c) }
            } else {
                DispatchQueue.main.async {
                    self.errorMessage = "Конфиг некорректен — оставлен прежний"
                    self.log.log(.error, "config", "Ошибка чтения конфига — оставлен прежний")
                }
            }
        }
        self.watcher = watcher
        watcher.start()
    }

    private func startPoller(with c: Config) {
        poller?.stop()
        poller = nil
        let p = Poller(config: c, log: log)
        p.onUpdate = { [weak self] _, snap in
            DispatchQueue.main.async { self?.snapshots[snap.host.name] = snap }
        }
        poller = p
        p.start()
    }

    func reload(_ c: Config) {
        let added = c.hosts.map(\.name)
        config = c
        errorMessage = nil
        log.log(.info, "config", "Конфиг перечитан: хостов \(added.count)")
        let names = Set(added)
        snapshots = snapshots.filter { names.contains($0.key) }
        pausedHosts = [] // сброс пауз при перечитывании конфига
        startPoller(with: c)
    }

    // MARK: - Сохранение изменений в конфиг

    /// Применяет мутацию на копию конфига; если она вернула true — пишет файл и
    /// перезагружает. Возвращает false, если ничего не изменилось или запись не удалась.
    @discardableResult
    func saveConfig(_ mutate: (inout Config) -> Bool) -> Bool {
        var c = config
        guard mutate(&c) else { return false }
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try c.yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            reload(c) // fallback: только в память
            return false
        }
        reload(c)
        return true
    }

    // MARK: - Быстрое добавление хоста

    /// Добавляет хост по строке вида `user@host`, `192.0.2.13` или `hostname`.
    /// Парсинг/дедупликация — в HomelabCore.QuickAdd (покрыт тестами).
    /// Сохраняет в конфиг-файл и перезапускает поллер. Возвращает nil при успехе,
    /// иначе — текст ошибки.
    @discardableResult
    func quickAddHost(_ raw: String) -> String? {
        var message: String?
        let ok = saveConfig { c in
            if let e = QuickAdd.append(to: &c, address: raw, currentUser: NSUserName()) {
                message = e
                return false
            }
            return true
        }
        if ok {
            log.log(.info, "action", "Добавлен хост: \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            log.log(message == nil ? .error : .warn, "action", message ?? "Не удалось сохранить конфиг")
        }
        return ok ? nil : message
    }

    // MARK: - Drag&drop (группа) и удаление

    /// Переносит хост в группу указанного хоста-цели (nil = «Прочее»).
    func setGroup(of hostName: String, to group: String?) {
        saveConfig { c in
            guard let i = c.hosts.firstIndex(where: { $0.name == hostName }),
                  c.hosts[i].group != group else { return false }
            c.hosts[i].group = group
            return true
        }
    }

    /// Удаляет хост из конфигурации.
    func deleteHost(_ name: String) {
        if saveConfig({ c in
            guard c.hosts.contains(where: { $0.name == name }) else { return false }
            c.hosts.removeAll { $0.name == name }
            return true
        }) {
            log.log(.info, "action", "Удалён хост: \(name)")
        }
    }

    // MARK: Группы и теги (контекстное меню карточки)

    func createGroup(_ g: String) -> Bool {
        saveConfig { c in
            let name = g.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            if !c.groups.contains(name) { c.groups.append(name) }
            return true
        }
    }

    func createGroupAndMove(_ host: String, _ g: String) -> Bool {
        saveConfig { c in
            let name = g.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            if !c.groups.contains(name) { c.groups.append(name) }
            if let i = c.hosts.firstIndex(where: { $0.name == host }) {
                c.hosts[i].group = name
            }
            return true
        }
    }

    func setTags(_ host: String, tag: String, on: Bool) -> Bool {
        saveConfig { c in
            guard let i = c.hosts.firstIndex(where: { $0.name == host }) else { return false }
            if on {
                if !c.hosts[i].tags.contains(tag) { c.hosts[i].tags.append(tag) }
            } else {
                c.hosts[i].tags.removeAll { $0 == tag }
            }
            return true
        }
    }

    func createTagAndAssign(_ host: String, _ name: String) -> Bool {
        saveConfig { c in
            let tag = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return false }
            let used = Set(c.tags.map { $0.color })
            if !c.tags.contains(where: { $0.name == tag }) {
                c.tags.append(TagDef(name: tag, color: nextTagColor(used: used)))
            }
            if let i = c.hosts.firstIndex(where: { $0.name == host }), !c.hosts[i].tags.contains(tag) {
                c.hosts[i].tags.append(tag)
            }
            return true
        }
    }

    private func nextTagColor(used: Set<String>) -> String {
        let palette = ["green", "blue", "orange", "red", "purple", "teal", "yellow"]
        return palette.first { !used.contains($0) } ?? "gray"
    }

    func snapshot(for name: String) -> HostSnapshot {
        snapshots[name] ?? HostSnapshot(host: config.hosts.first { $0.name == name } ?? .init(name: name, ssh: ""))
    }

    // MARK: - Фильтры и тема

    func toggle(_ hostTags: [String]) {
        for t in hostTags { toggleTag(t) }
    }

    func toggleTag(_ t: String) {
        if tagFilter.contains(t) { tagFilter.remove(t) } else { tagFilter.insert(t) }
    }

    func togglePause(_ name: String) {
        guard let host = config.hosts.first(where: { $0.name == name }),
              let p = poller else { return }
        let pausing = !pausedHosts.contains(name)
        p.setPaused(host, pausing)
        if pausing { pausedHosts.insert(name) } else { pausedHosts.remove(name) }
        log.log(.info, name, pausing ? "Пауза опроса" : "Опрос возобновлён")
    }

    func isFilterActive(_ t: String) -> Bool { tagFilter.contains(t) }

    var appliedTheme: ThemeMode { themeOverride ?? config.theme }

    func cycleTheme() {
        switch appliedTheme {
        case .system: setThemeOverride(.light)
        case .light: setThemeOverride(.dark)
        case .dark: setThemeOverride(nil)
        }
    }

    func setThemeOverride(_ m: ThemeMode?) {
        themeOverride = m
        if let m { UserDefaults.standard.set(m.rawValue, forKey: "themeOverride") }
        else { UserDefaults.standard.removeObject(forKey: "themeOverride") }
    }

    var colorScheme: ColorScheme? {
        switch appliedTheme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    // MARK: - Агрегаты

    func hosts(in group: String) -> [HostConfig] {
        config.hosts.filter { groupName(of: $0) == group }
    }

    func groupName(of h: HostConfig) -> String {
        let g = h.group ?? ""
        return g.isEmpty ? config.unknownGroupName : g
    }

    var filteredHosts: [HostConfig] {
        guard !tagFilter.isEmpty else { return config.hosts }
        return config.hosts.filter { h in h.tags.contains(where: { tagFilter.contains($0) }) }
    }

    var statusCount: (total: Int, online: Int, offline: Int) {
        let h = config.hosts
        let online = h.filter { snapshots[$0.name]?.isOnline == true }.count
        let offline = h.filter { snapshots[$0.name]?.status == .offline }.count
        return (h.count, online, offline)
    }
}

public struct HomeLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: DashboardStore
    @StateObject private var logStore: LogStore
    @Environment(\.openWindow) private var openWindow

    public init() {
        let log = LogStore()
        _logStore = StateObject(wrappedValue: log)
        _store = StateObject(wrappedValue: DashboardStore(path: Config.defaultPath(), log: log))
    }

    public var body: some Scene {
        WindowGroup("Homelab Dashboard") {
            ContentView()
                .environmentObject(store)
                .environmentObject(logStore)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 760)

        Window("О программе", id: "about") {
            AboutView()
                .frame(width: 420, height: 320)
        }
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(after: .appInfo) {
                Button("О программе…") {
                    openWindow(id: "about")
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Не даём AppKit прибить приложение по AutomaticTermination/SuddenTermination,
        // пока окно ещё не успело открыться (иначе headless-квitt через пару секунд).
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("dashboard window")
        if let icon = AppIcon.make() { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Открывает новое окно Терминала и запускает в нём SSH к переданному хосту.
enum TerminalOpener {
    static func open(_ destination: String, log: LogStore? = nil) {
        let seg = SshRunner.split(destination)
        let raw = seg.1.map { "ssh -o ServerAliveInterval=30 -p \($0) \(seg.0)" } ?? "ssh -o ServerAliveInterval=30 \(destination)"
        let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var err: NSDictionary?
        let ran = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if ran == nil {
            let msg = err?[NSAppleScript.errorMessage] as? String ?? "неизвестная ошибка"
            log?.log(.error, "terminal", "Не удалось открыть терминал (\(destination)): \(msg)")
            NSLog("HLD: не удалось открыть терминал: %@", msg)
        } else {
            log?.log(.info, "terminal", "Открыт терминал: ssh \(destination)")
        }
    }
}
/// Рисует иконку приложения программно (SwiftPM без asset-каталога):
/// скруглённый квадрат с градиентом и символом серверной стойки.
enum AppIcon {
    static func make() -> NSImage? {
        let size = NSSize(width: 512, height: 512)
        let icon = NSImage(size: size)
        icon.lockFocus()
        defer { icon.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: 118, cornerHeight: 118, transform: nil)
        ctx.addPath(path)
        ctx.clip()

        // Диагональный градиент индиго → тёмно-синий.
        let colors = [
            NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.98, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.80, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.34, alpha: 1).cgColor,
        ]
        let space = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.55, 1])
        ctx.drawLinearGradient(grad!, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])

        // Мягкий блик в левом верхнем углу для глубины.
        let sheen = CGGradient(colorsSpace: space,
                               colors: [NSColor.white.withAlphaComponent(0.26).cgColor,
                                        NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 1])
        ctx.drawRadialGradient(sheen!, startCenter: CGPoint(x: size.width * 0.28, y: size.height * 0.78),
                               startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.28, y: size.height * 0.78),
                               endRadius: size.width * 0.62, options: [])

        // Глиф «активность/пульс» — чистая дашборд-иконка.
        if let base = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil),
           let gray = base.withSymbolConfiguration(.init(pointSize: 226, weight: .medium)) {
            let tinted = NSImage(size: gray.size)
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: gray.size).fill()
            gray.draw(at: .zero, from: .zero, operation: .sourceIn, fraction: 1.0)
            tinted.unlockFocus()
            tinted.draw(in: CGRect(x: 143, y: 143, width: 226, height: 226))
        }
        return icon
    }
}

/// Собственное окно «О программе»: имя автора, ник и ссылка на репозиторий.
struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
    private let repoURL = URL(string: "https://github.com/msklv/homelab-dashboard")!

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("Homelab Dashboard")
                .font(.title2.bold())

            Text("Версия \(version)")
                .foregroundStyle(.secondary)

            Divider()

            Text("Михаил Соколов")
                .font(.headline)
            Text("@msklv")
                .foregroundStyle(.secondary)

            Link("github.com/msklv/homelab-dashboard", destination: repoURL)
                .font(.callout)
        }
        .padding(24)
        .fixedSize()
    }
}
