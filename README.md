# homelab-dashboard

Нативный macOS-дашборд (Apple Silicon / ARM) для мониторинга Linux и macOS-серверов по SSH:
живые метрики, группы, цветные теги, светлая/тёмная тема, YAML-конфиг с hot-reload.
Ноль зависимостей, кроме Yams.

A native macOS (Apple Silicon) SSH-based dashboard for monitoring your Linux and macOS servers:
live metrics, groups, colored tags, light/dark theme, and a YAML config with instant hot-reload.
Only one dependency (Yams) on top of the system SSH/Ping and SwiftUI.

## Особенности / Features

- Live pull-мониторинг по SSH (без агентов на серверах)
- Метрики: статус, ping, cores, RAM, диск, uptime, температура, CPU %, RAM %, сеть ↑/↓, диск I/O R/W
- Сводка: Итого / Онлайн / Оффлайн
- Группы (секции) и цветные теги-фильтры
- Светлая / тёмная тема (system | light | dark)
- YAML-конфиг с мгновенным hot-reload
- Только ARM (Apple Silicon), минимальные зависимости

## Требования / Requirements

- macOS 12+
- Apple Silicon (arm64)
- `ssh` и `ping` доступны из консоли; серверы авторизованы через `~/.ssh` (ключи / config)

## Сборка / Build

```sh
# Xcode project + Swift Package
open homelab-dashboard.xcodeproj
```

## Конфигурация / Configuration

См. `SPEC.md` (раздел 4) и пример в `config.example.yaml`.

```
config: ~/.config/homelab-dashboard/config.yaml
```

## Спецификация

Полное описание устройства: **`SPEC.md`** (архитектура, схема YAML, пары команд сбора,
спецификация UI, цветовая семантика порогов, hot-reload, безопасность).

## Лицензия / License

[MIT](LICENSE)