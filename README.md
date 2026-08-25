# zapret-updater
Авто-обновление [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) при загрузке Windows.

## Установка

```powershell
irm https://geardung.github.io/zapret-updater/install-updater.ps1 | iex
```

Что делает:
- Находит zapret через реестр Windows
- Инициализирует git-репозиторий (если ещё не инициализирован)
- Создаёт скрипт авто-обновления в `utils\zapret-auto-update.ps1`
- Регистрирует задачу в Планировщике задач (запуск от SYSTEM, задержка 60с)

## Удаление

```powershell
irm https://geardung.github.io/zapret-updater/uninstall-updater.ps1 | iex
```

Что удаляет:
- Задачу `ZapretAutoUpdate` из Планировщика задач
- Скрипт `utils\zapret-auto-update.ps1`
- Логи `utils\logs\auto-update.log*`

Служба zapret **не затрагивается** — она продолжит работать как раньше.

## Как работает авто-обновление

При каждой загрузке Windows (через 60 секунд):
1. `git pull --ff-only` в папке zapret
2. Если есть обновления — полная пересоздание службы:
   - Остановка службы
   - Удаление службы
   - Парсинг `.bat` файла стратегии
   - Создание службы с новыми аргументами
   - Запуск службы
3. Лог в `utils\logs\auto-update.log` (ротация при 1 МБ)
