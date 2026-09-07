import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HomelabCore

// MARK: - Цвета уровней

enum LevelColor {
    static func forPct(_ pct: Double?, _ th: Thresholds) -> Color {
        guard let p = pct else { return Color(nsColor: .tertiaryLabelColor) }
        if p < Double(th.warning) { return LevelColor.green }
        if p < Double(th.critical) { return LevelColor.warning }
        return LevelColor.critical
    }
    static let green = Color(red: 0.10, green: 0.68, blue: 0.30)
    static let warning = Color(red: 0.92, green: 0.56, blue: 0.08)
    static let critical = Color(red: 0.86, green: 0.20, blue: 0.20)
    static let accent = Color(red: 0.25, green: 0.50, blue: 0.90)
}

private enum HostPrompt {
    case newGroup, newTag
}

// MARK: - Главный экран

struct ContentView: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var log: LogStore
    @State private var quickAdd = ""
    @State private var quickAddStatus: String?
    @State private var quickAddIsError = false
    @State private var showLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                quickAddBar
                if store.errorMessage != nil {
                    errorBanner
                }
                Divider()
                if !store.config.tags.isEmpty {
                    tagFilterBar
                }
                if store.config.groups.isEmpty {
                    HostGrid(hosts: store.config.hosts)
                } else {
                    ForEach(store.config.groupsWithUngrouped, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group)
                                .font(.callout.weight(.semibold))
                                .foregroundColor(.secondary)
                            HostGrid(hosts: store.hosts(in: group))
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(store.colorScheme)
        .onAppear { store.start() }
        .sheet(isPresented: $showLogs, onDismiss: { log.setPanelOpen(false) }) {
            LogsView()
                .environmentObject(log)
                .onAppear { log.setPanelOpen(true) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(LevelColor.accent)
            Text("Homelab Dashboard")
                .font(.title2.weight(.semibold))
            miniSummary
            Spacer()
            if store.tagFilter.isEmpty == false {
                Button {
                    store.tagFilter = []
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Сбросить фильтр тегов")
            }
            Button {
                showLogs = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 13, weight: .semibold))
                    if log.unseenErrors > 0 {
                        Text("\(log.unseenErrors)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Circle().fill(LevelColor.critical))
                            .offset(x: 8, y: -6)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .help("Консоль действий и ошибок")
            Button(action: store.cycleTheme) {
                Image(systemName: themeIcon())
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .help("Тема: \(themeName())")
        }
    }

    private func themeIcon() -> String {
        switch store.appliedTheme {
        case .light: return "sun.max"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    private func themeName() -> String {
        switch store.appliedTheme {
        case .light: return "светлая"
        case .dark: return "тёмная"
        case .system: return "авто (по системе)"
        }
    }

    private var miniSummary: some View {
        let c = store.statusCount
        return HStack(spacing: 16) {
            SummaryBadge(color: LevelColor.accent, value: c.total, label: "Итого")
            SummaryBadge(color: LevelColor.green, value: c.online, label: "Онлайн")
            SummaryBadge(color: LevelColor.critical, value: c.offline, label: "Оффлайн")
        }
    }

    // Панель быстрого добавления хоста — растянута на всю ширину окна.
    private var quickAddBar: some View {
        HStack(spacing: 8) {
            Button(action: submitQuickAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(LevelColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Добавить хост")

            TextField("Добавить хост: user@host, IP или hostname…", text: $quickAdd)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .onSubmit(submitQuickAdd)

            if let st = quickAddStatus {
                Text(st)
                    .font(.caption)
                    .foregroundColor(quickAddIsError ? LevelColor.critical : LevelColor.green)
                    .lineLimit(1)
            }
        }
    }

    private func submitQuickAdd() {
        let raw = quickAdd
        let err = store.quickAddHost(raw)
        quickAddIsError = err != nil
        quickAddStatus = err ?? "добавлено"
        if err == nil { quickAdd = "" }
    }

    private var errorBanner: some View {
        Label(store.errorMessage ?? "", systemImage: "exclamationmark.triangle.fill")
            .foregroundColor(LevelColor.critical)
            .font(.callout)
    }

    private var tagFilterBar: some View {
        HStack(spacing: 8) {
            Text("Теги:")
                .font(.callout)
                .foregroundColor(.secondary)
            ForEach(store.config.tags, id: \.name) { tag in
                TagChip(tag: tag, active: store.isFilterActive(tag.name)) {
                    store.toggleTag(tag.name)
                }
            }
            Spacer()
        }
    }
}

struct SummaryBadge: View {
    let color: Color
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(value)")
                .font(.system(.callout, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Группа хостов

struct HostGrid: View {
    let hosts: [HostConfig]
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        let visible = store.tagFilter.isEmpty
            ? hosts
            : hosts.filter { $0.tags.contains(where: { store.tagFilter.contains($0) }) }
        let columns = [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(visible) { h in
                HostCard(host: h)
            }
        }
    }
}

// MARK: - Карточка хоста

struct HostCard: View {
    let host: HostConfig
    @EnvironmentObject private var store: DashboardStore
    @State private var showDelete = false
    @State private var dropActive = false
    @State private var prompt: HostPrompt?
    @State private var promptText = ""

    var body: some View {
        let s = store.snapshot(for: host.name)
        VStack(alignment: .leading, spacing: 7) {
            header(s)
            specsLine(s)
            Divider()
            metricStrip(s)
            tempRow(s)
            tagRow
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor(s), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(dropActive ? LevelColor.accent : .clear, lineWidth: 2))
        .onDrag { NSItemProvider(object: host.name as NSString) }
        .onDrop(of: [.text], isTargeted: $dropActive) { providers in
            guard let p = providers.first else { return false }
            p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let from = obj as? String else { return }
                DispatchQueue.main.async { store.setGroup(of: from, to: host.group) }
            }
            return true
        }
        .confirmationDialog("Удалить хост «\(host.name)»?",
                            isPresented: $showDelete,
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { store.deleteHost(host.name) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Хост и его данные будут удалены из конфигурации.")
        }
        .contextMenu {
            Menu {
                Button { store.setGroup(of: host.name, to: nil) } label: {
                    if host.group == nil { Label("Без группы", systemImage: "checkmark") } else { Text("Без группы") }
                }
                Divider()
                ForEach(store.config.groups, id: \.self) { g in
                    Button { store.setGroup(of: host.name, to: g) } label: {
                        if host.group == g { Label(g, systemImage: "checkmark") } else { Text(g) }
                    }
                }
                Divider()
                Button("Новая группа…") { prompt = .newGroup }
            } label: {
                Label("Группа: \(host.group ?? "Прочее")", systemImage: "folder")
            }
            Menu {
                if store.config.tags.isEmpty {
                    Text("Тегов пока нет")
                }
                ForEach(store.config.tags, id: \.name) { tag in
                    Button { store.setTags(host.name, tag: tag.name, on: !host.tags.contains(tag.name)) } label: {
                        if host.tags.contains(tag.name) { Label(tag.name, systemImage: "checkmark") } else { Text(tag.name) }
                    }
                }
                if !store.config.tags.isEmpty { Divider() }
                Button("Новый тег…") { prompt = .newTag }
            } label: {
                Label("Теги: \(host.tags.count)", systemImage: "tag")
            }
            Divider()
            Button {
                let md = HostCardMarkdown.build(s)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(md, forType: .string)
                store.log.log(.info, "action", "Карточка «\(host.name)»: markdown скопирован (\(md.count) симв.)")
            } label: {
                Label("Копировать карточку (MD)", systemImage: "doc.on.doc")
            }
            Divider()
            Button("Удалить хост…", role: .destructive) { showDelete = true }
        }
        .alert(prompt == .newGroup ? "Новая группа" : "Новый тег", isPresented: Binding(
            get: { prompt != nil },
            set: { if !$0 { promptText = ""; prompt = nil } })) {
            if prompt == .newGroup {
                TextField("Имя группы", text: $promptText)
                Button("Создать и переместить") { store.createGroupAndMove(host.name, promptText); promptText = ""; prompt = nil }
                Button("Только создать") { store.createGroup(promptText); promptText = ""; prompt = nil }
                Button("Отмена", role: .cancel) { promptText = ""; prompt = nil }
            } else {
                TextField("Имя тега", text: $promptText)
                Button("Создать и применить") { store.createTagAndAssign(host.name, promptText); promptText = ""; prompt = nil }
                Button("Отмена", role: .cancel) { promptText = ""; prompt = nil }
            }
        } message: {
            Text(prompt == .newGroup ? "Переместить хост в новую группу" : "Создать тег и добавить его хосту")
        }
    }

    private func borderColor(_ s: HostSnapshot) -> Color {
        switch s.status {
        case .offline: return LevelColor.critical.opacity(0.5)
        case .online: return LevelColor.green.opacity(0.45)
        case .pending: return .secondary.opacity(0.15)
        }
    }

    private func header(_ s: HostSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: osIcon(s.os))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(LevelColor.accent)
                .frame(width: 18)
            Text(s.hostname ?? host.name)
                .font(.headline)
                .lineLimit(1)
            Button {
                TerminalOpener.open(host.ssh, log: store.log)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LevelColor.accent)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Открыть SSH-терминал: \(host.ssh)")
            Spacer()
            statusDot(s)
            Text(Format.ping(s.pingMs))
                .font(.caption.monospacedDigit())
                .foregroundColor(s.isOnline ? LevelColor.green : .secondary)
        }
    }

    private func statusDot(_ s: HostSnapshot) -> some View {
        Circle()
            .fill(s.isOnline ? LevelColor.green : (s.status == .offline ? LevelColor.critical : .gray))
            .frame(width: 8, height: 8)
            .shadow(radius: s.isOnline ? 2 : 0)
    }

    private func specsLine(_ s: HostSnapshot) -> some View {
        let parts = [
            s.cores.map { String($0) + " C" },
            s.ramTotal.map(Format.bytes),
            s.diskTotal.map(Format.gb),
            s.uptimeText.map { "up " + $0 },
        ].compactMap { $0 }
        return HStack(spacing: 8) {
            Text(parts.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(osName(s.os))
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
    }

    private func metricStrip(_ s: HostSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RingMetric(label: "CPU", pct: s.cpuPct, color: LevelColor.forPct(s.cpuPct, store.config.thresholds))
            RingMetric(label: "RAM", pct: s.ramUsedPct, color: LevelColor.forPct(s.ramUsedPct, store.config.thresholds))
            Divider().frame(height: 42)
            TextTwin(title: "Сеть", rows: [("↑", Format.bytesPerSecond(s.netUp)), ("↓", Format.bytesPerSecond(s.netDown))],
                     accessory: s.linkMbps.map(Format.link))
            Spacer(minLength: 0)
            TextTwin(title: "Диск", rows: [("R", Format.bytesPerSecond(s.diskRead)), ("W", Format.bytesPerSecond(s.diskWrite))],
                     accessory: s.diskKind)
        }
    }

    private func tempRow(_ s: HostSnapshot) -> some View {
        HStack(spacing: 14) {
            TempItem(label: "CPU", value: s.tempC)
            TempItem(label: "Плата", value: s.tempBoardC)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var tagRow: some View {
        if !host.tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(host.tags, id: \.self) { name in
                    if let def = store.config.tags.first(where: { $0.name == name }) {
                        TagChip(tag: def, active: store.isFilterActive(name)) {
                            store.toggleTag(name)
                        }
                    }
                }
            }
            .frame(height: 18)
        }
    }

    private func osIcon(_ os: HostOS) -> String {
        switch os {
        case .macos: return "macmini.fill"
        case .linux: return "terminal"
        case .unknown: return "globe"
        }
    }

    private func osName(_ os: HostOS) -> String {
        switch os {
        case .macos: return "macOS"
        case .linux: return "Linux"
        case .unknown: return "—"
        }
    }
}

// MARK: - Метрика-кольцо

struct RingMetric: View {
    let label: String
    let pct: Double?
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 6)
                if let p = pct {
                    let shown = p > 0 ? max(p, 4) : 0
                    Circle()
                        .trim(from: 0, to: min(1, max(0, shown / 100)))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: p)
                }
                Text(Format.percent(pct))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundColor(pct == nil ? .secondary : .primary)
            }
            .frame(width: 52, height: 52)
        }
    }
}

// MARK: - Двухрядный числовой блок

struct TextTwin: View {
    let title: String
    let rows: [(String, String)]
    var accessory: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title).font(.caption).foregroundColor(.secondary)
                if let a = accessory, !a.isEmpty {
                    Text(a)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .foregroundColor(LevelColor.accent)
                        .background(LevelColor.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            ForEach(0..<rows.count, id: \.self) { i in
                HStack(spacing: 5) {
                    Text(rows[i].0).font(.caption.weight(.bold)).foregroundColor(.secondary)
                    Text(rows[i].1).font(.callout.monospacedDigit())
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Температура CPU / плата

struct TempItem: View {
    let label: String
    let value: Double?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "thermometer.medium")
                .font(.caption2)
                .foregroundColor(LevelColor.accent)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(Format.temp(value))
                .font(.callout.monospacedDigit())
        }
    }
}

// MARK: - Чип тега

struct TagChip: View {
    let tag: TagDef
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag.name)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(active ? 0.25 : 0.12))
                .foregroundColor(color)
                .overlay(Capsule().stroke(color.opacity(active ? 0.9 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .clipShape(Capsule())
    }

    private var color: Color {
        switch tag.color {
        case "green": return LevelColor.green
        case "blue": return LevelColor.accent
        case "orange": return LevelColor.warning
        case "red": return LevelColor.critical
        case "purple": return .purple
        case "teal": return .teal
        case "yellow": return .yellow
        default: return .gray
        }
    }
}

extension HostConfig: Identifiable {
    public var id: String { name }
}

// MARK: - Консоль действий и ошибок

private enum LogFilter: String, CaseIterable, Identifiable {
    case all = "Все", issues = "Ошибки"
    var id: String { rawValue }
}

struct LogsView: View {
    @EnvironmentObject private var log: LogStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter: LogFilter = .all
    @State private var autoscroll = true

    private var visible: [LogEntry] {
        switch filter {
        case .all: return log.entries
        case .issues: return log.entries.filter { $0.level != .info }
        }
    }
    private var issueCount: Int { log.entries.filter { $0.level != .info }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundColor(LevelColor.accent)
            Text("Консоль действий и ошибок")
                .font(.headline)
            Group {
                if log.entries.isEmpty {
                    Text("пусто")
                } else {
                    Text("\(log.entries.count) записей · \(issueCount) ошибок")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: $filter) {
                ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 176)
            Button("Очистить") { log.clear() }
                .disabled(log.entries.isEmpty)
            Button("Готов") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { entry in
                        LogRow(entry: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: log.entries.count) { _ in
                if autoscroll, let last = visible.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Автопрокрутка", isOn: $autoscroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Spacer()
            Text("Логируются действия пользователя, сбои SSH, переходы online/offline и события конфига.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(entry.time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 54, alignment: .leading)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
            Spacer(minLength: 0)
            if !entry.source.isEmpty {
                Text(entry.source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(highlight.opacity(entry.level == .info ? 0 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var dotColor: Color {
        switch entry.level {
        case .info: return Color.secondary
        case .warn: return LevelColor.warning
        case .error: return LevelColor.critical
        }
    }
    private var textColor: Color {
        entry.level == .error ? LevelColor.critical : .primary
    }
    private var highlight: Color {
        entry.level == .error ? LevelColor.critical.opacity(0.16) : LevelColor.warning.opacity(0.16)
    }
}

// MARK: - Копирование карточки в Markdown

/// Собирает markdown-представление карточки хоста: всё видимое на экране
/// + строку подключения + фактические цифры CPU/RAM.
private enum HostCardMarkdown {
    static func build(_ s: HostSnapshot) -> String {
        let title = (s.hostname?.isEmpty == false) ? s.hostname! : s.host.name
        let status: String
        switch s.status {
        case .online: status = "🟢 онлайн"
        case .offline: status = "🔴 offline"
        case .pending: status = "🟡 ожидание"
        }
        let ping = s.pingMs.map { "\(Int($0.rounded())) мс" } ?? "—"
        let osName: String
        switch s.os {
        case .macos: osName = "macOS"
        case .linux: osName = "Linux"
        case .unknown: osName = "—"
        }

        let cores = s.cores.map(String.init) ?? "—"
        let ramTotal = Format.gb(s.ramTotal)
        let ramUsed = s.ramUsed.map { Format.gb($0) } ?? "—"
        let ramPct = s.ramUsedPct.map { "\(Int($0.rounded()))%" } ?? "—"
        let disk = Format.gb(s.diskTotal)
        let kind = s.diskKind?.uppercased() ?? "—"
        let uptime = s.uptimeText ?? "—"
        let tempC = s.tempC.map { "\(Int($0.rounded()))°C" } ?? "—"
        let tempB = s.tempBoardC.map { "\(Int($0.rounded()))°C" } ?? "—"
        let cpu = s.cpuPct.map { "\(Int($0.rounded()))%" } ?? "—"
        let net = "\(linkText(s)) ↑\(Format.bytesPerSecond(s.netUp)) ↓\(Format.bytesPerSecond(s.netDown))"
        let io = "R \(Format.bytesPerSecond(s.diskRead)) · W \(Format.bytesPerSecond(s.diskWrite))"

        var lines: [String] = []
            lines.append("### \(title)  ·  \(status)  ·  ping \(ping)")
            lines.append("")
            let target = SshRunner.split(s.host.ssh)
            let sshCmd = target.1.map { "ssh -p \($0) \(target.0)" } ?? "ssh \(s.host.ssh)"
            lines.append("- **Подключение:** `\(sshCmd)`")
        lines.append("- **Хост:** \(osName) · \(cores) Cores · RAM \(ramUsed)/\(ramTotal) (\(ramPct)) · Диск \(kind) \(disk)")
        lines.append("- **Нагрузка:** CPU **\(cpu)** · RAM **\(ramPct)**")
        lines.append("- **Uptime:** \(uptime) · Температура: CPU \(tempC) / Плата \(tempB)")
        lines.append("- **Сеть:** \(net)")
        lines.append("- **Диск I/O:** \(io)")
        var meta: [String] = []
        if let g = s.host.group, !g.isEmpty { meta.append("группа «\(g)»") }
        if !s.host.tags.isEmpty { meta.append("теги: \(s.host.tags.joined(separator: ", "))") }
        if !meta.isEmpty { lines.append("- \(meta.joined(separator: " · "))") }
        return lines.joined(separator: "\n")
    }

    private static func linkText(_ s: HostSnapshot) -> String {
        guard let m = s.linkMbps, m > 0 else { return "—" }
        if m >= 1000 {
            if m % 1000 == 0 { return "\(m / 1000)G" }
            return String(format: "%.1fG", Double(m) / 1000.0)
        }
        return "\(m)M"
    }
}