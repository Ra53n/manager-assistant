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
- **Memory.swift / MemoryStore.swift** — память (см. ниже): типы (MemoryItem +
  MemoryScope/MemoryKind для долго-/краткосрочной; Project + ProjectEntry —
  рабочая память), сборка блока для промпта (MemoryContext) и персистентность
  (MemoryStore→memory.json, ProjectStore→projects.json).
- **MarkdownText.swift** — Markdown ответа агента в ОДИН AttributedString (для
  сплошного выделения; BubbleContent/ComparisonMessage рендерят им вместо MarkdownUI).
- **Profile.swift** — «Профиль ответа» (ResponseProfile): пресет стиля/формата/
  ограничений/языка + доп. инструкции; ProfileStore→profiles.json. Инжектится
  директивами в системный промпт; переключается на чат через Chat.profileID.
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
- **Ветвление (branching)** — ДЕРЕВО узлов: Chat.nodes ([MsgNode] с parentID),
  Chat.currentTipID; Chat.messages — COMPUTED путь от tip к корню (общий префикс
  не дублируется). Именованные ветки = Chat.branchLeaves ([BranchLeaf {name,tipID}])
  + activeLeafID. Добавление сообщения — ТОЛЬКО через addMessage (узел под tip),
  не messages.append (сеттер messages перестроил бы дерево линейно и снёс ветки!).
  makeBranchFrom (2 ветки от чекпоинта), switchBranch (сменить tip), deleteBranch
  (+pruneOrphanNodes), mergeBranch (копирует расходящийся хвост). Миграция старого
  линейного messages → дерево в Chat.init(from:) (LegacyKeys.messages). В сравнении
  ветвления НЕТ.
- **Конечный автомат задачи (FSM) — формальная детерминированная модель** — задача
  проходит этапы planning → execution → validation → **answer** НА УРОВНЕ КОДА.
  Формализация (под референс пользователя), всё в Models.swift одним блоком «FSM»:
  • **`TaskState`** — состояние/этап (planning/execution/validation/answer).
  • **`TaskFSM.transitions`** — ЯВНАЯ таблица переходов (`planning→[execution]`,
    `execution→[validation,planning]`, `validation→[answer,execution]`, `answer→[]`)
    + `allows(_:to:)`. ЕДИНСТВЕННЫЙ источник истины «откуда куда можно».
  • **`TaskContext.transitioned(to:)`** — страж: меняет `state` ТОЛЬКО через
    `precondition(TaskFSM.allows(...))`. Оркестратор НИКОГДА не пишет `state` напрямую
    → нелегальный скачок (planning→answer и т.п.) невозможен.
  • **`TaskContext`** (бывш. `TaskRun`) — сущность: task/state/step/total/plan(`[String]`)/
    done(`[String]`)/current (+ служебные mode/status/answer/retries…). В `Chat.taskContext`.
  • **`PipelinePrompts.buildPrompt(query:ctx:profile:)`** — user-сообщение из контекста
    (`[STATE]/[CURRENT]/[PLAN]/[DONE]/[PROFILE]/[QUERY]` + Правила); системный промпт =
    роль этапа `systemPrompt(for:)`. Профиль ответа инжектится и в FSM.
  Оркестратор — `ChatViewModel.runStateMachine`. **Пошаговость**: этап `.execution`
  идёт ПО ШАГАМ плана — один `client.runPhase` на шаг, `current=plan[step]`,
  `done.append`, `step+=1`; к `.validation` только когда `step>=total` (маркер
  `NEXT_STEP`). Каждый шаг — сообщение «Выполнение · шаг N/total». ВАЖНО: `.answer` —
  САМ ОТВЕТ пользователю (`TaskContext.answer`), а НЕ отчёт о работе FSM. Режим в
  `GenerationSettings.pipelineMode` (off/auto/plan): **auto** — подряд; **plan** — стоп
  после планирования (`status=.awaitingPlan` → `approvePlan`/`replan`). **Шаги назад**
  (легальны по таблице): validation→execution по вердикту `parseVerdict`
  (лимит `maxExecutionRetries=2`); execution→planning — авто по маркеру `REPLAN` ИЛИ
  кнопкой «Перепланировать» (`requestReplan`, лимит `maxPlanRetries=2`). Этапы
  самодостаточны (только из артефактов `TaskContext`), не зависят от contextStrategy;
  вывод в ленту через `addMessage(..., state:step:total:)`. **Краш-устойчивость**:
  `persistNow()` СИНХРОННО пишет `chats` на диск после КАЖДОГО шага/перехода/паузы/
  ошибки (аналог `repo.save(ctx)`) — переживает выключение питания/`kill -9`/нехватку
  токенов. **Пауза/возобновление**: `pausePipeline` отменяет Task; отмена приходит как
  `URLError.cancelled` ИЛИ `CancellationError` ИЛИ `Task.isCancelled` → ПАУЗА (не ошибка!),
  `status=.paused`; при старте `ChatStore.load` + `normalizeTaskRuns` (висящий running→
  paused) + `resumePipeline` входят в `runStateMachine` и продолжают с сохранённого
  `state/step`. Инвариант: `state`/`step` сдвигаются и сохраняются ТОЛЬКО при успехе →
  resume повторяет незавершённый
  этап, не рестартит. Гонку пауза→быстрое продолжение гасит `pipelineGen[chatID]`
  (старый Task с устаревшим gen состояние не трогает). При старте `normalizeTaskRuns`
  переводит «висящие» running → paused. Вторичные вызовы памяти/фактов на этапах НЕ
  запускаются. UI — `pipelineBar` (полоса этапов) над лентой + быстрый сегмент-
  переключатель режима `pipelineModeBar` ПРЯМО НАД полем ввода (Выкл|Авто|План, один
  клик) + секция в `ChatSettingsView`. В сравнении FSM НЕТ.
- **Инварианты (ограничения)** — валидируемые правила, которым ОБЯЗАН соответствовать
  ответ модели (Invariant.swift): стек/запрет(noBanned)/maxDeps/архитектура/бюджет/
  техрешения/бизнес-правила. ХРАНЯТСЯ ОТДЕЛЬНО ОТ ДИАЛОГА — `InvariantStore`→
  `invariants.json` (НЕ в chats.json!); привязка через поля `scope`(global/project/chat)+
  `ownerID` внутри инварианта. Эффективный набор чата = глобальные + инварианты его
  проекта + инварианты чата (`vm.effectiveInvariants(for:)`). Инжектятся в КАЖДЫЙ
  промпт FSM через `PipelinePrompts.buildPrompt(... invariants:)` (блок `[INVARIANTS]`:
  «обязательны, явно учитывай, НЕ предлагай нарушающие решения; если запрос юзера
  требует нарушения — ОТКАЖИСЬ, выведи маркер `НАРУШЕН ИНВАРИАНТ`, предложи альтернативу»).
  Валидация КАЖДОГО ответа в `runStateMachine` (метод в `GenerationSettings.
  invariantValidation`: off/code/llm/both): **code** — вхождение `banned`-терминов
  (`InvariantValidator.codeViolations`) + маркер-самопометка; **llm** — доп. запрос
  `client.checkInvariants`. Нарушение МОДЕЛИ (запрещённое вошло в ответ) → retry того же
  этапа/шага с нарушениями в промпте (`TaskContext.invariantRetries/invariantViolations`,
  лимит `maxInvariantRetries=2`). КОНФЛИКТ С ЮЗЕРОМ (маркер `modelFlaggedConflict`) →
  НЕ retry, баннер `Chat.invariantConflict` (runtime). Защита у каждого инварианта:
  `enforcement` prompt/code/both. UI: кнопка-щит → `InvariantsPanelView`/`InvariantEditorView`
  (секции по скоупам + шаблоны `Invariant.templates()`); метод валидации — секция в
  `ChatSettingsView`; бейдж «⚠N» в `pipelineBar`. В сравнении инвариантов НЕТ.
- **Вкладки сайдбара: Чаты | Проекты** (cowork) — `ContentView` держит `mode`
  (SidebarMode) + сегмент-переключатель в шапке сайдбара. Чаты-вкладка = обычные
  чаты (`vm.looseChats`, projectID==nil). Проекты-вкладка = список проектов,
  каждый — `DisclosureGroup` со своими ДИАЛОГАМИ (`vm.chats(in:)`), общая память
  проекта (cowork). `detail` един для обоих режимов — по `selectedChatID`. Тулбар
  сайдбара: одна контекст-зависимая `+` (новый чат / новый проект) + `Menu` (⋯) с
  ключами и сравнением — ≤2 элемента, чтобы ничего не пропадало на узкой ширине.
- **Память — три уровня, рабочая = ПРОЕКТ** — ОТДЕЛЬНЫЙ от стратегий слой,
  инжектится в системный промпт через `PromptBuilder.systemPrompt(... memory:)`:
  1) **краткосрочная** — заметки на диалог (`MemoryItem` в `Chat.memory`, в chats.json);
  2) **рабочая = Проект** — `Project {title, brief(=инструкции), entries:[ProjectEntry]}`
     в `projects.json`; проект создаётся ЧЕЛОВЕКОМ (`ProjectCreateView`: только
     НАЗВАНИЕ + опц. ИНСТРУКЦИИ, без ИИ-предложений) и сразу заводит первый диалог
     (`vm.newChat(inProject:)` — у проектных чатов дефолты injectChatMemory +
     autoProjectSections); секции (`ProjectEntry` — ПОЛНЫЙ текст ответа/заметки)
     дополняют агенты; у проекта НЕСКОЛЬКО диалогов через `Chat.projectID`;
  3) **долговременная** — профиль пользователя (`MemoryItem` в глобальном
     `MemoryStore`→memory.json, во ВСЕ чаты).
  `MemoryContext.assemble` собирает КОМПАКТНЫЙ блок под бюджет
  (settings.memoryTokenBudget; pinned не выкидываются): профиль + (инструкции
  проекта + оглавление секций + тела под бюджет) + краткосрочная. «Собрать»
  (`client.assembleProject`, vm.assembleProject → vm.assemblyResult) — отдельный
  поток, читает ПОЛНЫЕ тела секций; в инжект они целиком не идут.
  UI: профиль/заметки — `MemoryPanelView` (кнопка «мозг» в чате); проект
  (инструкции + секции + «Собрать») — `ProjectPanelView` (вкладка «Проекты» /
  кнопка «папка» в шапке проектного чата). Явное «В проект» (полная секция) / «В
  память» (короткая) на сообщении. Автосекции (settings.autoProjectSections):
  полный ответ агента → секция (заголовок — `client.sectionTitle`). Ассистент
  памяти (`client.suggestMemory`; settings.memoryAssistEnabled + autoMemory — ВКЛ
  ПО УМОЛЧАНИЮ): после обмена сам пишет профиль/предпочтения → долговременная и
  ДЕТАЛИ диалога (решения, числа, форматы, технологии) → краткосрочная. «Замок» от
  затопления долговременной — и в промпте, и в `parseSuggestions` (decision/note →
  shortTerm; profile/preference → longTerm; knowledge в longTerm только если про
  пользователя). ВАЖНО: `Project`, не `Task` (конфликт со Swift Concurrency
  `Task{}`). Системный промпт НЕ форсирует краткость; в проекте
  `PromptBuilder(inProject:)` просит развёрнутые секции. В сравнении — ТОЛЬКО
  долговременная, read-only (`MemoryContext.assembleLongTermOnly`).
- **Миграция chats.json/projects.json** — у Chat, GenerationSettings, Project,
  ProjectEntry, MemoryItem РУЧНЫЕ init(from:) в extension с decodeIfPresent+дефолтами.
  Новые поля добавлять ТОЛЬКО так (поле + CodingKeys + init(from:)), иначе старый
  файл уедет в .corrupt.json. Спецслучаи: `Chat.projectID` имеет JSON-ключ
  `= "taskID"` (читает старые файлы прозрачно); `Project.init(from:)` мигрирует
  старый `WorkTask.items`→`entries` (LegacyKeys.items); `ProjectStore.load`
  читает старый tasks.json, если нет projects.json; `MemoryScope.working` оставлен
  ради декода старых «working»-сниппетов (в пикерах скрыт). MemoryScope/MemoryKind
  декодируются снисходительно. Ловушка: запуск СТАРОГО бинарника перезапишет файл
  без новых полей.
- **Профили ответа** (НЕ путать с «профилем» в долговременной памяти!) —
  `ResponseProfile` в `profiles.json` (`ProfileStore`, сид при первом запуске):
  свободнотекстовые поля стиль/формат/ограничения/язык/доп.инструкции →
  `systemDirective` → инжект в `PromptBuilder.systemPrompt(... profile:)` («соблюдай
  строго»). Активный — `Chat.profileID`; создаётся/выбирается/правится/удаляется в
  настройках чата ⚙︎ (секция «Профиль ответа», `ProfileEditorView`). Только ТЕКСТ
  в промпт — токены/температуру НЕ трогает (это GenerationSettings). В сравнении нет.
- **Мультипровайдер** — добавить провайдера = новый case в `Provider` +
  endpoints/keyFileName/envVar; UI подхватит сам через `allCases`.
- **Ключи API — никогда в коде/git.** Лежат в `~/.config/manager-assistant/<p>.key`
  или env (`DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`). Перед коммитом сканируй
  staged-файлы: `git grep -I --cached -e 'sk-'` (плейсхолдеры «sk-...» в доках — ок).
- **История** — `~/Library/Application Support/ManagerAssistant/chats.json`
  (компактный JSON; runtime-поля isLoading/errorText не сериализуются). Память —
  рядом: `memory.json` (долговременная) и `projects.json` (проекты/рабочая;
  однократная миграция из старого `tasks.json` при первом запуске — старый файл
  не удаляется, остаётся бэкапом); все с дебаунс-автосохранением и
  .corrupt.json-фолбэком при повреждении.
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
- Зависимость MarkdownUI ещё в Package.swift, но в рендере НЕ используется:
  ответы агента рисует `MarkdownText` одним `Text` (сплошное выделение). Можно убрать.

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
