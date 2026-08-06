# Clabar

Меню-бар приложение для macOS: лимиты Claude + уведомления от Claude Code.
Ядро отслеживания лимитов взято из [claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) (BSD-2-Clause), слой уведомлений — свой (идея из [треда на r/ClaudeAI](https://www.reddit.com/r/ClaudeAI/comments/1puwxie/)).

## Возможности

- **Иконка в меню-баре** с выпадающей панелью. Настраивается: мини-полоски, проценты текстом (5ч / неделя / Fable), счётчик непрочитанных, 🔥 при «сгорающем» лимите.
- **Лимиты**: 5-часовое окно, недельное, Fable/Opus/Sonnet и любые новые бакеты API подхватываются автоматически. График истории (1ч–30д).
- **Уведомления от Claude Code** через хуки: запросы (permission, вопросы, план готов), завершение работы, сбои — с разными иконками. Системные баннеры; у запросов кнопки «⏎ Разрешить / ⎋ Отклонить / Открыть». Клик ведёт в приложение с сессией (VS Code — с открытием нужной папки).
- **Журнал уведомлений**: отдельное окно («История…»), таблица с сортировкой и фильтрами по типу / непрочитанным / тексту. Двойной клик — переход в сессию.
- **Nudge «сожги лимит»**: если использовано меньше N% недельного окна, а до сброса меньше M часов — подсветка в иконке и баннер в панели.
- **Автонастройка**: хуки ставятся сами при первом запуске. Кнопка настройки DevContainer.
- **Локализация**: русский/английский — автоматически по языку системы, принудительный выбор в настройках.

## Сборка и запуск

```sh
make app          # соберёт build/Clabar.app (нужен Xcode / CLT)
open build/Clabar.app
# по желанию: cp -R build/Clabar.app /Applications/
```

Первый запуск:

1. Разрешите **уведомления** (системный запрос).
2. В панели нажмите **«Войти через Claude»** — OAuth в браузере, вставьте код.
3. Хуки в `~/.claude/settings.json` поставятся автоматически (бэкап: `settings.json.clabar-backup`).
4. Для кнопок «Разрешить/Отклонить» клавишами включите опцию в настройках и выдайте Clabar право **Универсальный доступ** (Accessibility). По умолчанию выключено — кнопки просто фокусируют сессию.

## Как это работает

Хуки Claude Code (`Notification`, `Stop`, `PermissionRequest`, `PreToolUse` для AskUserQuestion/ExitPlanMode, `PostToolUseFailure`, `SessionEnd`) вызывают `~/.claude/hooks/clabar-hook.sh`, который отправляет JSON события на `http://127.0.0.1:8737/event` (fire-and-forget, сессию не блокирует и не ломает). Приложение классифицирует событие, пишет в журнал и показывает баннер.

## DevContainers (VS Code)

Настройки → Интеграция → **«Настроить проект…»** патчит `devcontainer.json`:

```jsonc
"mounts": [
  "source=${localEnv:HOME}/.claude,target=/clabar/claude-config,type=bind"
],
"containerEnv": {
  "CLAUDE_CONFIG_DIR": "/clabar/claude-config",
  "CLABAR_HOST": "host.docker.internal"
}
```

Хостовый `~/.claude` монтируется в контейнер, `CLAUDE_CONFIG_DIR` заставляет Claude Code использовать его — настройки, хуки и логин едут в контейнер и обратно автоматически. Уведомления из контейнера идут на хост через `host.docker.internal` (Docker Desktop). Если в `devcontainer.json` есть комментарии, приложение не переписывает файл, а показывает сниппет для ручной вставки. После патча пересоберите контейнер. В контейнере нужен `curl` (есть почти везде).

Если в проекте уже задан свой `CLAUDE_CONFIG_DIR`, Clabar его не трогает: добавляет только `CLABAR_HOST`, а хуки ставит прямо в тот конфиг — когда его хостовый путь удаётся вычислить (папка внутри workspace или объявленный bind-маунт). Существующие `mounts` (в том числе объектные) сохраняются.

### Кастомный DevContainer (конфиг Claude на named volume)

Если `.claude` в контейнере живёт на docker-томе (named volume) и заменить его на локальную папку нельзя, Clabar с хоста в этот том не попадёт — хуки нужно ставить **изнутри контейнера**. Clabar'у от контейнера нужно всего три вещи:

1. хук-скрипт и его регистрация в `settings.json` того конфига, который реально использует Claude Code в контейнере (`$CLAUDE_CONFIG_DIR`, по умолчанию `~/.claude`);
2. переменная `CLABAR_HOST=host.docker.internal`, чтобы события уходили на хост;
3. `curl` в образе.

Пошагово:

1. Скопируйте [`extras/clabar-container-setup.sh`](extras/clabar-container-setup.sh) из этого репозитория в `.devcontainer/` вашего проекта. Скрипт идемпотентен: пишет `hooks/clabar-hook.sh` и аккуратно домердживает регистрацию хуков в `settings.json`, не трогая ваши существующие хуки (нужен `python3` в образе — есть почти во всех devcontainer-образах).

2. В `devcontainer.json` добавьте:

   ```jsonc
   "containerEnv": {
     "CLABAR_HOST": "host.docker.internal"
   },
   "postStartCommand": "sh .devcontainer/clabar-container-setup.sh"
   ```

   `postStartCommand` (а не `postCreateCommand`) — чтобы установка самовосстанавливалась при каждом старте: том переживает пересборки, а вот чистый `settings.json` после `claude logout`/сброса — нет.

3. Пересоберите контейнер (**Dev Containers: Rebuild Container**). В логе старта появится `Clabar hooks installed into …`.

Проверка изнутри контейнера: `curl -s -m 2 http://host.docker.internal:8737/ping` должен ответить `clabar`. Если нет — на Docker Desktop это работает из коробки, а на «голом» Docker/colima добавьте в `devcontainer.json` `"runArgs": ["--add-host=host.docker.internal:host-gateway"]`.

Если `python3` в образе нет, впишите хуки в `settings.json` тома один раз вручную (скрипт `clabar-hook.sh` создайте тем же heredoc'ом из `clabar-container-setup.sh`):

```json
"hooks": {
  "Notification":       [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "Stop":               [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "PermissionRequest":  [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "PreToolUse":         [{ "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }],
  "SessionEnd":         [{ "hooks": [{ "type": "command", "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh\"", "async": true, "timeout": 5 }] }]
}
```

Нюанс: в этой схеме уведомления с лимитами работают полностью, но настройки/логин Claude в томе живут своей жизнью и с хостом не синхронизируются — это свойство named volume, Clabar тут ничего не меняет.

## Где лежат данные

| Что | Где |
|---|---|
| OAuth-токены | `~/.config/clabar/credentials.json` (0600) |
| История лимитов | `~/.config/clabar/history.json` (30 дней) |
| Журнал уведомлений | `~/.config/clabar/notifications.json` (последние 2000) |
| Хук-скрипт | `~/.claude/hooks/clabar-hook.sh` |

Наружу данные не уходят — только запросы к API Anthropic за лимитами.

## Переменные окружения

- `CLABAR_DATA_DIR` — переопределить папку данных приложения.
- `CLABAR_NO_AUTOINSTALL=1` — не ставить хуки автоматически.
- `CLABAR_HOST` / `CLABAR_PORT` — куда хук-скрипт шлёт события (для контейнеров/нестандартного порта).

## Разработка

```sh
swift test   # юнит-тесты (парсинг бакетов, nudge, merge хуков, классификация, dedupe)
make app     # релизная сборка .app
```
