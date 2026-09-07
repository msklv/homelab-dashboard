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
    ///
    /// Имя можно задать явно префиксом `имя=address` (напр. `vm2=user@h:2222`).
    /// Для джамп-хостов вида `user:alias@host` имя по умолчанию берётся из `alias`
    /// (это реальная VM за бастионом), а не из host-части (бастион).
    public static func parse(_ raw: String, currentUser: String) -> Dest? {
        var forcedName: String?
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = s.firstIndex(of: "="), s.startIndex < eq, s.index(after: eq) < s.endIndex {
            let lhs = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !lhs.isEmpty, !rest.isEmpty { forcedName = lhs; s = rest }
        }
        guard !s.isEmpty else { return nil }
        var name: String
        var ssh: String
        if let at = s.firstIndex(of: "@") {
            ssh = s
            let userPart = String(s[..<at])
            let host = String(s[s.index(after: at)...])
            if let c = userPart.firstIndex(of: ":") {
                name = String(userPart[userPart.index(after: c)...]) // user:alias@host -> alias
            } else {
                name = SshRunner.split(host).0 // без :port, чтобы имя было чистым host'ом
            }
        } else {
            name = SshRunner.split(s).0
            ssh = currentUser + "@" + s
        }
        if let f = forcedName { name = f }
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