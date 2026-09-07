import Foundation

/// Логика быстрого добавления хоста из строки адреса.
/// Вид ввода: `user@host`, `192.0.2.13`, `hostname`.
public enum QuickAdd {
    public struct Dest: Equatable, Sendable {
        public var name: String
        public var ssh: String
        public init(name: String, ssh: String) {
            self.name = name
            self.ssh = ssh
        }
    }

    /// Парсит строку адреса в (name, ssh). Для адреса без user'а name = адрес,
    /// ssh = currentUser@адрес. nil — если строка пуста или адрес не распознан.
    public static func parse(_ raw: String, currentUser: String) -> Dest? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var name: String
        var ssh: String
        if let at = s.firstIndex(of: "@") {
            ssh = s
            name = String(s[s.index(after: at)...])
        } else {
            name = s
            ssh = currentUser + "@" + s
        }
        guard !name.isEmpty else { return nil }
        return Dest(name: name, ssh: ssh)
    }

    /// Добавляет хост в конфиг. Возвращает nil в случае успеха, иначе текст ошибки
    /// (пустая строка / не распознан / такой ssh уже есть / имя занято).
    public static func append(to config: inout Config, address: String, currentUser: String) -> String? {
        let s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "Строка пуста" }
        guard let d = parse(s, currentUser: currentUser) else { return "Не распознан адрес: \(s)" }
        if config.hosts.contains(where: { $0.ssh == d.ssh }) { return "Такой хост уже есть: \(d.ssh)" }
        if config.hosts.contains(where: { $0.name == d.name }) { return "Имя \(d.name) уже занято" }
        config.hosts.append(HostConfig(name: d.name, ssh: d.ssh))
        return nil
    }
}