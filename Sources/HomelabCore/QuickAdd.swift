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
    /// Иначе name — host-часть (после последнего `@`, без :port).
    ///
    /// Поддерживается и ssh-cli стиль: `ssh 'user:alias@host' -p PORT`,
    /// `ssh user@host -p PORT`, `'user@host:2222'` — нормализуется в
    /// `user:alias@host:PORT` (порт переводится в `@host:PORT`). Строка
    /// сохраняется как есть — это готовая цель для `ssh` (никакого ProxyJump:
    /// двоеточие в user-части — просто часть логина `login:token@host`).
    public static func parse(_ raw: String, currentUser: String) -> Dest? {
        var forcedName: String?
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = s.firstIndex(of: "="), s.startIndex < eq, s.index(after: eq) < s.endIndex {
            let lhs = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !lhs.isEmpty, !rest.isEmpty { forcedName = lhs; s = rest }
        }
        guard !s.isEmpty else { return nil }
        // ssh-cli форма: `ssh '…' -p PORT`, `ssh host -p PORT`, `'user@host:2222'`.
        // Если строка ведома ssh/кавычкой — нормализация обязана удаться, иначе адрес
        // малформирован (nil, без провала в старый путь, который мог бы изуродовать строку).
        let firstTok = s.prefix(while: { !$0.isWhitespace })
        if firstTok == "ssh" || firstTok.first == "'" || firstTok.first == "\"" {
            guard let n = normalizeSshCli(s) else { return nil }
            s = n
        }
        var name: String
        var ssh: String
        if let at = s.firstIndex(of: "@") {
            ssh = s
            let host = String(s[s.index(after: at)...])
            name = SshRunner.split(host).0 // без :port, чтобы имя было чистым host'ом
        } else {
            name = SshRunner.split(s).0
            ssh = currentUser + "@" + s
        }
        if let f = forcedName { name = f }
        guard !name.isEmpty else { return nil }
        return Dest(name: name, ssh: ssh)
    }

    /// Приводит ssh-cli стиль к каноническому адресу `key@host[:port]`:
    /// `ssh 'user:alias@host' -p PORT`, `ssh user@host -p PORT`, `'user@host:2222'`.
    /// Возвращает nil, если строка не похожа на ssh-cli (тогда parse идёт старым путём).
    private static func normalizeSshCli(_ raw: String) -> String? {
        var rest = raw
        let head = rest.prefix(while: { !$0.isWhitespace })
        if head == "ssh" {
            rest = String(rest.dropFirst(head.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !rest.isEmpty else { return nil }

        // адрес: в кавычках ('…'/"…") — иначе до флага -p/-P, иначе весь остаток (только если был "ssh").
        var addr: String
        var tail = ""
        if let q = rest.first, q == "'" || q == "\"" {
            guard let close = rest.dropFirst().firstIndex(of: q), close > rest.startIndex else { return nil }
            addr = String(rest[rest.index(after: rest.startIndex)..<close])
            tail = String(rest[rest.index(after: close)...])
        } else if let flag = rest.range(of: " -p ") ?? rest.range(of: " -P ") {
            addr = String(rest[..<flag.lowerBound]).trimmingCharacters(in: .whitespaces)
            tail = String(rest[flag.lowerBound...])
        } else if rest.hasSuffix(" -p") || rest.hasSuffix(" -P") {
            addr = String(rest.dropLast(3)).trimmingCharacters(in: .whitespaces)
            tail = ""
        } else if head == "ssh" {
            addr = rest
            tail = ""
        } else {
            return nil
        }
        guard !addr.isEmpty else { return nil }

        // опциональный -p PORT из хвоста
        var port: Int?
        let t = tail.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-p") || t.hasPrefix("-P") {
            let digits = t.dropFirst(2).trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let p = Int(digits), (1...65535).contains(p) else { return nil }
            port = p
        }

        // добавляем :port к host-части (после "@"), если inline-порта ещё нет
        var out = addr
        if let p = port {
            let hostPart: String
            if let at = addr.lastIndex(of: "@") {
                hostPart = String(addr[addr.index(after: at)...])
            } else {
                hostPart = addr
            }
            if !hostPart.contains(":") { out = addr + ":\(p)" }
        }
        return out
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