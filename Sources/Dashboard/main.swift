import Foundation
import HomelabCore

// Точка входа. `--selftest` — headless-прогон сбора метрик и выход (для тестирования).
if CommandLine.arguments.contains("--selftest") {
    let code = runSelfTest(configPath: Config.defaultPath())
    exit(code)
} else if let i = CommandLine.arguments.firstIndex(of: "--gpucheck"),
          CommandLine.arguments.count > i + 1 {
    // Диагностика GPU-зонда: подключиться к хосту, выполнить gpuProbe, показать разбор.
    let dest = CommandLine.arguments[i + 1]
    let host = HostConfig(name: "gpucheck", ssh: dest)
    let res = SshRunner().run(host, timeout: 8, batch: CommandBatch.gpuProbe(for: host))
    print("exit=\(res.exitCode)")
    let gpus = GpuParser.parse(res.stdout)
    for g in gpus {
        print("GPU \(g.name): util=\(Format.percent(g.utilPct)) VRAM \(Format.bytes(g.memUsed))/\(Format.bytes(g.memTotal)) (\(g.memUsedPct.map { String(format: "%.0f%%", $0) } ?? "--"))")
    }
    if gpus.isEmpty { print("нет GPU-строк. raw:\n\(res.stdout)") }
    exit(gpus.isEmpty ? 1 : 0)
} else {
    HomeLabApp.main()
}