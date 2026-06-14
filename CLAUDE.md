# CLAUDE.md — гид по проекту для ИИ-ассистентов

Нативное macOS-приложение (SwiftUI, Swift Package): чат-клиент к LLM-провайдерам
(DeepSeek, OpenRouter) с настройками генерации, метриками стоимости и
персистентной историей. UI и комментарии в коде — на русском.

## Архитектура (поток данных)

```
ContentView.swift (весь UI, SwiftUI)
        │ читает состояние / зовёт методы
        ▼
ChatViewModel.swift (@MainActor, единственный источник состояния)
        │ send(): история чата целиком        │ автосохранение ($chats, дебаунс)
        ▼                                     ▼
DeepSeekClient.swift (HTTP)            ChatStore.swift (JSON на диск)
        │ endpoint/ключ по провайдеру
        ▼
Providers.swift (Provider, KeyStore, DeepSeekPricing)
```

- **Models.swift** — доменные типы (Chat, ChatMessage, GenerationSettings,
  MessageMetrics; все Codable) + DTO API + PromptBuilder (системный промпт).
- **ComparisonView.swift** — режим сравнения: до 3 «дорожек» (своя модель +
  история), общий ввод шлёт вопрос во все параллельно. Свой ComparisonViewModel,
  переиспользует DeepSeekClient/ModelPickerView; цены берёт через vm.price(for:).
- **Config.swift** — дефолтная модель и системный промпт.
- **App.swift** — вход; AppDelegate чинит активацию окна/иконку при `swift run`.

## Ключевые решения (почему так)

- **API stateless** — «память» модели = повторная отправка истории чата в
  каждом запросе. Из-за этого promptTokens растут с каждым сообщением.
- **Стратегии контекста** (по ТЗ) — GenerationSettings.contextStrategy:
  full / slidingWindow / stickyFacts / branching. Что слать решает
  `ContextManager.payload` (full и branching → вся активная история; sliding →
  последние N; stickyFacts → facts + последние N). Первые три — и в сравнении
  (ContextStrategy.sendStrategies). stickyFacts фоном обновляет Chat.facts через
  client.updateFacts (maybeUpdateFacts). ВАЖНО: стратегия декодируется
  снисходительно (ContextStrategy.init(from:) → unknown/«summary» = .full),
  иначе старый chats.json падает.
- **Ветвление (branching)** — в чате: Chat.branches/activeBranchID, messages =
  зеркало активной ветки (mirrorActiveBranch синхронизирует). makeBranchFrom
  создаёт 2 ветки от чекпоинта, switchBranch переключает; панель веток над
  лентой. В сравнении ветвления НЕТ (структурная стратегия).
- **Миграция chats.json** — у Chat и GenerationSettings РУЧНЫЕ init(from:)
  в extension с decodeIfPresent+дефолтами. Новые поля добавлять ТОЛЬКО так,
  иначе старый файл перестанет декодироваться (уйдёт в .corrupt.json).
  Ловушка: запуск СТАРОГО бинарника перезапишет файл без новых полей.
- **Мультипровайдер** — добавить провайдера = новый case в `Provider` +
  endpoints/keyFileName/envVar; UI подхватит сам через `allCases`.
- **Ключи API — никогда в коде/git.** Лежат в `~/.config/manager-assistant/<p>.key`
  или env (`DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`). Перед коммитом сканируй
  staged-файлы: `git grep -I --cached -e 'sk-'` (плейсхолдеры «sk-...» в доках — ок).
- **История** — `~/Library/Application Support/ManagerAssistant/chats.json`
  (компактный JSON; runtime-поля isLoading/errorText не сериализуются).
- **Цены**: OpenRouter — живые из его `/models`; DeepSeek — захардкожены в
  `DeepSeekPricing` (их API цен не отдаёт) — при изменении прайса править там.
- **Параметры генерации**: только temperature/top_p/max_tokens/stop.
  top_k и penalty не отправляются — DeepSeek не поддерживает.

## Сборка и запуск

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools  # если лицензия Xcode не принята
swift build          # сборка
swift run            # запуск в dev-режиме (окно активируется AppDelegate'ом)
bash run.sh          # упаковка в ManagerAssistant.app (+иконка из Resources)
bash install.sh      # run.sh + установка в /Applications (так пользуется юзер)
```

- Полный Xcode установлен, но его лицензия может быть не принята — поэтому
  `DEVELOPER_DIR` указывает на Command Line Tools.
- Иконка генерируется скриптами в `icon/` → `Sources/ManagerAssistant/Resources/AppIcon.icns`
  (ресурс пакета: в рантайме ставится через `NSApp.applicationIconImage`).
- Зависимость одна: MarkdownUI (рендер ответов ассистента).

## Проверка изменений (workflow)

1. `swift build` — без ошибок и предупреждений.
2. `bash install.sh && open -a /Applications/ManagerAssistant.app` — поднять реальное приложение.
3. UI-проверки делались через computer-use (скриншоты): отправить сообщение,
   проверить фичу глазами. У пользователя поверх поля ввода бывает невидимый
   оверлей Wispr Flow — кликать по левому краю поля.
4. Перед коммитом: скан на ключи (см. выше).

## Git

- Пуш только через SSH на порту 443 (порт 22 заблокирован сетью):
  remote = `ssh://git@ssh.github.com:443/Ra53n/manager-assistant.git`.
- `gh` CLI не установлен. Коммиты — на русском, кратко «что и зачем».
- После каждой фичи: коммит + пуш + `bash install.sh` (обновить копию юзера).

## UI-ловушки macOS/SwiftUI (уже наступали)

- `.roundedBorder` делает TextField однострочным → многострочное поле =
  `.plain` + `axis: .vertical` + `lineLimit(1...5)`.
- Длинный title у TextField в `Form(.grouped)` переносится и ломает вёрстку →
  подсказки только через `prompt:`.
- `Label` в `.toolbar` показывает только иконку → текст оборачивать в HStack.
- Пикер с сотнями моделей бесполезен → отдельный лист с поиском (ModelPickerView).
