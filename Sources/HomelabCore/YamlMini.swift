import Foundation

/// Упрощённый YAML-парсер, покрывающий схему конфига homelab-dashboard:
/// блочные mapping (по отступам), блочные последовательности (`- item`),
/// flow-мапы `{k: v, ...}` и flow-списки `[a, b]`, скаляры, комментарии `#`.
/// Парсер не претендует на полный YAML-стандарт — только на наш подмножества.
public enum YVal: Equatable {
    case null
    case str(String)
    case int(Int64)
    case dbl(Double)
    case bool(Bool)
    case arr([YVal])
    case map([String: YVal])
}

public enum YamlMiniError: Error, LocalizedError, Equatable {
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .unexpected(let m): return "YAML: \(m)"
        }
    }
}

public enum YamlMini {
    private struct Line {
        let indent: Int
        let text: String
        var isSeq: Bool { text.hasPrefix("-") }
    }

    private static func lines(of text: String) -> [Line] {
        var out: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = raw[...]
            let ns = s.count - s.drop { $0 == " " }.count
            while let first = s.first, first == " " { s = s.dropFirst() }
            var line = stripComment(String(s))
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            out.append(Line(indent: ns, text: line))
        }
        return out
    }

    /// Убирает `#`-комментарий вне кавычек. Кавычки не разбираются глубоко — достаточно не трогать '#' в простых строках.
    private static func stripComment(_ s: String) -> String {
        var inS = false, inD = false
        for (i, ch) in s.enumerated() {
            if ch == "'" && !inD { inS.toggle() }
            else if ch == "\"" && !inS { inD.toggle() }
            else if ch == "#" && !inS && !inD {
                let prev = i > 0 ? s[s.index(s.startIndex, offsetBy: i - 1)] : " "
                if prev == " " || prev == "\t" { return String(s.prefix(i)) }
            }
        }
        return s
    }

    public static func parseDocument(_ text: String) throws -> YVal {
        let ls = lines(of: text)
        guard let first = ls.first else { return .map([:]) }
        let base = first.indent
        var p = Parser(ls: ls)
        let val = p.parseMapping(keyIndent: base)
        return .map(val)
    }

    public static func parseScalarValue(_ raw: String) -> YVal { parseScalar(raw) }

    private struct Parser {
        let ls: [Line]
        var idx = 0

        func cur() -> Line? { idx < ls.count ? ls[idx] : nil }
        func peekNonBlank() -> Line? { idx < ls.count ? ls[idx] : nil }

        mutating func parseMapping(keyIndent: Int) -> [String: YVal] {
            var map: [String: YVal] = [:]
            while let ln = cur(), ln.indent == keyIndent, !ln.isSeq {
                guard let kv = splitKV(ln.text) else { break }
                idx += 1
                map[kv.key] = value(for: kv.val, parentIndent: keyIndent)
            }
            return map
        }

        /// Значение для `key: val`, где k может быть пустым (блок на след. строке).
        private mutating func value(for raw: String, parentIndent: Int) -> YVal {
            if raw.isEmpty {
                if let nx = peekNonBlank(), nx.indent > parentIndent {
                    if nx.isSeq { return .arr(parseSequence(at: nx.indent)) }
                    return .map(parseMapping(keyIndent: nx.indent))
                }
                return .null
            }
            return parseInline(raw)
        }

        mutating func parseSequence(at itemIndent: Int) -> [YVal] {
            var items: [YVal] = []
            while let ln = cur(), ln.indent == itemIndent, ln.isSeq {
                let rest = String(ln.text.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                idx += 1
                let keyIndent = itemIndent + 2

                var item: YVal
                if rest.isEmpty {
                    if let nx = peekNonBlank(), nx.indent > itemIndent {
                        item = nx.isSeq ? .arr(parseSequence(at: nx.indent)) : .map(parseMapping(keyIndent: nx.indent))
                    } else { item = .null }
                } else if rest.hasPrefix("{") || rest.hasPrefix("[") {
                    item = parseFlow(rest)
                } else if let kv = splitKV(rest) {
                    var m: [String: YVal] = [kv.key: value(for: kv.val, parentIndent: itemIndent)]
                    while let nx = cur(), nx.indent == keyIndent, !nx.isSeq,
                          let k2 = splitKV(nx.text) {
                        idx += 1
                        m[k2.key] = value(for: k2.val, parentIndent: keyIndent)
                    }
                    item = .map(m)
                } else {
                    item = parseScalar(rest)
                }
                items.append(item)
            }
            return items
        }

        private func parseInline(_ s: String) -> YVal {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("{") || t.hasPrefix("[") { return parseFlow(t) }
            return parseScalar(t)
        }

        private func parseFlow(_ t: String) -> YVal {
            if t.hasPrefix("[") {
                guard let close = t.firstIndex(of: "]") else { return parseScalar(t) }
                let inner = t[t.index(after: t.startIndex)..<close]
                let items = inner.split(separator: ",").map { parseScalar(String($0).trimmingCharacters(in: .whitespaces)) }
                return .arr(items)
            }
            guard let close = t.firstIndex(of: "}") else { return parseScalar(t) }
            let inner = t[t.index(after: t.startIndex)..<close]
            var map: [String: YVal] = [:]
            for part in inner.split(separator: ",") {
                let s = part.trimmingCharacters(in: .whitespaces)
                guard let kv = splitKV(s) else { map[kvFallback(s)] = .null; continue }
                map[kv.key] = parseScalar(kv.val)
            }
            return .map(map)
        }

        private func kvFallback(_ s: String) -> String { s }
    }

    /// Разделяет `key: value` по первому ':'.
    private static func splitKV(_ s: String) -> (key: String, val: String)? {
        var depth = 0
        var inS = false, inD = false
        for (i, ch) in s.enumerated() {
            if ch == "'" && !inD { inS.toggle() }
            else if ch == "\"" && !inS { inD.toggle() }
            else if ch == "{" || ch == "[" { depth += 1 }
            else if ch == "}" || ch == "]" { depth = max(0, depth - 1) }
            else if ch == ":" && depth == 0 && !inS && !inD {
                let idx = s.index(s.startIndex, offsetBy: i)
                let after = s.index(after: idx)
                if after == s.endIndex || s[after] == " " {
                    let key = s[s.startIndex..<idx].trimmingCharacters(in: .whitespaces)
                    let val = s[after...].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return ("", val) }
                    return (key, val)
                }
            }
        }
        return nil
    }

    private static func parseScalar(_ raw: String) -> YVal {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, ((t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'"))) {
            t = String(t.dropFirst().dropLast())
        }
        if t.isEmpty { return .null }
        if let i = Int64(t) { return .int(i) }
        if t.lowercased() == "true" { return .bool(true) }
        if t.lowercased() == "false" { return .bool(false) }
        if t.lowercased() == "null" || t == "~" { return .null }
        if t.contains(".") || t.contains(",") {
            if let d = Double(t.replacingOccurrences(of: ",", with: ".")) {
                if t.rangeOfCharacter(from: CharacterSet(charactersIn: "eE.")) != nil {
                    // только если выглядит как число
                    if t.first?.isNumber == true || t.hasPrefix("-") || t.hasPrefix("+") {
                        if d != d.truncatingRemainder(dividingBy: 1) || t.contains(".") {
                            return .dbl(d)
                        }
                    }
                }
            }
        }
        return .str(t)
    }
}

// MARK: - Доступ к значениям
public extension YVal {
    var string: String? {
        switch self {
        case .str(let s): return s
        case .int(let i): return String(i)
        case .dbl(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .str(let s): return Int64(s).map(Int.init)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .dbl(let d): return d
        case .int(let i): return Double(i)
        case .str(let s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .str(let s): return s.lowercased() == "true"
        default: return nil
        }
    }

    var array: [YVal]? { if case .arr(let a) = self { return a }; return nil }
    var map: [String: YVal]? { if case .map(let m) = self { return m }; return nil }

    func stringArray() -> [String] { array?.compactMap { $0.string } ?? [] }
}