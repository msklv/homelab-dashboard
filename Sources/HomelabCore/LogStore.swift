import Foundation
import Combine

/// Уровень журналирования.
public enum LogLevel: String, CaseIterable, Sendable {
    case info, warn, error
}

/// Одна запись журнала.
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let source: String
    public let message: String

    public init(level: LogLevel, source: String, message: String) {
        self.date = Date()
        self.level = level
        self.source = source
        self.message = message
    }

    public var time: String { Self.fmt.string(from: date) }
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Потокобезопасный журнал действий и особенно ошибок.
/// Все мутации — на main (небольшой объём), чтение — только из UI.
/// Кольцевой буфер: при превышении capacity старые записи вытесняются.
public final class LogStore: ObservableObject {
    @Published public private(set) var entries: [LogEntry] = []
    /// Число ошибок/предупреждений, появившихся с последнего открытия панели.
    @Published public private(set) var unseenErrors = 0

    public let capacity: Int
    private var panelOpen = false

    public init(capacity: Int = 1000) {
        self.capacity = max(64, capacity)
    }

    public func log(_ level: LogLevel, _ source: String, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(LogEntry(level: level, source: source, message: message))
            if self.entries.count > self.capacity {
                self.entries.removeFirst(self.entries.count - self.capacity)
            }
            if (level == .error || level == .warn) && !self.panelOpen {
                self.unseenErrors += 1
            }
        }
    }

    public func clear() {
        DispatchQueue.main.async { [weak self] in self?.entries.removeAll() }
    }

    /// Панель открыта/закрыта: при открытии сбрасываем счётчик непросмотренных.
    public func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open { unseenErrors = 0 }
    }
}