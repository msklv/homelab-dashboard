import Foundation
import HomelabCore

// Точка входа. `--selftest` — headless-прогон сбора метрик и выход (для тестирования).
if CommandLine.arguments.contains("--selftest") {
    let code = runSelfTest(configPath: Config.defaultPath())
    exit(code)
} else {
    HomeLabApp.main()
}