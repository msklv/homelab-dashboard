import Foundation

public struct ExecResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public init(exitCode: Int32, stdout: String) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public protocol CommandExecuting {
    func run(_ argv: [String]) -> ExecResult
}

/// Исполнитель системных команд через Process (ssh, ping и т.п.).
public struct SystemCommandExecutor: CommandExecuting {
    public init() {}

    public func run(_ argv: [String]) -> ExecResult {
        guard argv.count >= 1 else { return ExecResult(exitCode: -1, stdout: "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        let epipe = Pipe()
        p.standardOutput = pipe
        p.standardError = epipe

        do {
            try p.run()
        } catch {
            return ExecResult(exitCode: -1, stdout: "exec error: \(error)")
        }

        let handle = pipe.fileHandleForReading
        var data = Data()
        // Читаем асинхронно, чтобы не блокировать до ожидания статуса.
        let available = try? handle.readToEnd()
        if let available { data = available }
        p.waitUntilExit()
        var out = String(data: data, encoding: .utf8) ?? ""
        // Для диагностики: при ненулевом exit-коде подмешиваем stderr в вывод.
        let edata = try? epipe.fileHandleForReading.readToEnd()
        if p.terminationStatus != 0, let edata, let es = String(data: edata, encoding: .utf8), !es.isEmpty {
            out += "\n[stderr]\n" + es
        }
        return ExecResult(exitCode: p.terminationStatus, stdout: out)
    }
}

/// Обёртка ssh: запускает batch на хосте одной сессией, с таймаутом.
public struct SshRunner {
    public let executor: CommandExecuting
    public init(executor: CommandExecuting = SystemCommandExecutor()) { self.executor = executor }

    /// Выполнить batch на сервере.
    public func run(_ host: HostConfig, timeout: Int, batch: String) -> ExecResult {
            let (target, port) = SshRunner.split(host.ssh)
            var argv = [
                "/usr/bin/ssh",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(max(1, timeout))",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "LogLevel=ERROR",
            ]
            if let port { argv += ["-p", "\(port)"] }
            argv += [target, batch]
            return executor.run(argv)
        }

        /// Разбирает ssh-адрес на (target, port?). Синтаксис `user@host[:port]`.
        /// Порт — только если после последнего `:` чистые цифры (не ломать [IPv6]).
        public static func split(_ ssh: String) -> (String, Int?) {
            guard let c = ssh.lastIndex(of: ":") else { return (ssh, nil) }
            let tail = ssh[ssh.index(after: c)...]
            guard !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) else { return (ssh, nil) }
            guard let p = Int(tail), p > 0, p <= 65535 else { return (ssh, nil) }
            return (String(ssh[..<c]), p)
        }
    }

/// Задержка до хоста через системный ping.
public struct PingRunner {
    public let executor: CommandExecuting
    public let count: Int
    public let timeout: Int
    public init(executor: CommandExecuting = SystemCommandExecutor(), count: Int = 3, timeout: Int = 2) {
        self.executor = executor
        self.count = count
        self.timeout = timeout
    }

    public func latency(host: String) -> Double? {
        let r = executor.run(["/sbin/ping", "-t", "\(timeout)", "-c", "\(count)", host])
        guard r.exitCode == 0 else { return nil }
        guard let line = r.stdout.split(separator: "\n").last else { return nil }
        guard let eq = line.range(of: "=") else { return nil }
        let tail = line[eq.upperBound...]
        let firstSlash = tail.split(separator: "/")
        guard firstSlash.count >= 2, let avg = Double(firstSlash[1]) else { return nil }
        return avg
    }
}