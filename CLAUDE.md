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
- **Интерактивная пауза (как Claude Code)** — на активном прогоне ввод в поле НЕ
  стартует новый запуск, а роутится в `send()`: (1) `status==.awaitingInput` →
  `answerClarification`; (2) распознан запрос смены стадии (`PipelinePrompts.
  parseStateChangeRequest` — глагол перехода + метка этапа) → `requestStateChange`;
  (3) иначе → `interject`. **Уточнение** (`interject`): текст копится в
  `TaskContext.guidance` (инжектится блоком `[УКАЗАНИЯ ПОЛЬЗОВАТЕЛЯ]` в КАЖДЫЙ
  последующий промпт), агент дорабатывает ТЕКУЩУЮ стадию — НЕ возвращается в
  планирование. На паузе/ошибке — сразу `running`+`startPipeline` (доработка);
  на ходу (`.running`) — только очередь (запрос не рвём, учтётся след. проходом);
  на `.awaitingPlan` — в `planFeedback`+`replan`. **Вопрос агента**: модель выводит
  блок `ASK_USER`/`QUESTION:`/`OPTION:` (клауза `askUserClause` в роли планировщика/
  исполнителя); `runStateMachine` ПЕРЕД switch ловит его `parseQuestion` → ставит
  `pendingQuestion`+`status=.awaitingInput` и ВЫХОДИТ БЕЗ перехода; `answerClarification`
  кладёт «Вопрос/Ответ» в `guidance`, снимает `pendingQuestion`, продолжает ТУ ЖЕ
  стадию. UI — `clarificationBar` (вопрос + кнопки-варианты). **Смена стадии**:
  `requestStateChange(to:)` — переход ТОЛЬКО если `TaskFSM.allows`, иначе рантайм-баннер
  `Chat.stateChangeError` со списком доступных (БЕЗ токенов). `from==target` — перезапуск
  стадии (НЕ `transitioned`, иначе precondition-краш). Сбросы полей по цели. UI — меню
  «→ этап» в `pipelineControls` (легальные активны, нелегальные серые) + `stateChangeErrorBar`.
  Новый статус `.awaitingInput`; `normalizeTaskRuns` его НЕ трогает (не `.running`).
- **Рой агентов (параллельные подагенты, как в Claude Code)** — `GenerationSettings.
  swarmEnabled` (ПО УМОЛЧАНИЮ ВКЛ) + `maxParallelAgents`(2…6). На `.planning` при swarm
  планировщик доп. выдаёт раздел `ЗАВИСИМОСТИ:` («3: 1,2»); `PipelinePrompts.parseDeps`→
  `TaskContext.stepDeps`, `computeWaves` (алгоритм Кана) → `TaskContext.waves` ([[Int]],
  группы шагов, выполнимых параллельно; цикл/мусор → последовательный фолбэк). На
  `.execution` оркестратор гонит `runWave(chatID:gen:)` ВОЛНА ЗА ВОЛНОЙ: подагенты шага
  через `client.runPhase` с УЗКИМ контекстом (`subAgentPrompt`: обзор плана + ТОЛЬКО
  выводы зависимостей из `stepResults`, НЕ весь `[DONE]` → экономия токенов) параллельно
  через `withThrowingTaskGroup`, чанки по `maxParallelAgents` (захват ТОЛЬКО value-типов:
  `client` — struct без полей, Sendable; НЕ `self`/`chats`/`ctx`). Коммит волны —
  АТОМАРНО после успеха ВСЕХ подагентов: `stepResults[idx]`, `done.append` по порядку,
  `addMessage(.execution,step:idx)`, `step=done.count`, `waveIndex++`, на последней волне
  → `validation`; `persistNow` после волны. Пауза/отмена в волне → `pauseAt` БЕЗ коммита →
  resume повторяет ВСЮ волну (идемпотентно). Инварианты — код-проверка по объединённому
  выводу волны (конфликт→обрыв; нарушение→retry всей волны в общем бюджете
  `invariantRetries`); LLM-проверку по подагентам не гоняем (дорого). `REPLAN` от подагента
  → шаг назад в планирование. Swarm ВЫКЛ → старый последовательный путь байт-в-байт
  (полный `[DONE]`, один `runPhase`/шаг). UI — бейдж «рой ×N» в `pipelineBar`, секция в
  `ChatSettingsView`. В сравнении роя НЕТ.
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
- **Локальный RAG (база знаний) — pipeline индексации + ретрив в чате** — ОТДЕЛЬНЫЙ от
  памяти слой: пользователь выбирает файл/папку → индексация (чанкинг → эмбеддинги →
  векторный индекс) → при вопросе достаются релевантные чанки и дописываются к `memory:`
  в `ChatViewModel.send()` (модель видит их как контекст). Всё в `Rag*.swift`, чистая
  логика тестируется офлайн (`RagTests.swift`).
  • **Слои**: `RagModels.swift` (Codable-типы `RagChunk`/`RagChunkMetadata`/`RagSource`/
    `RagIndexConfig`/`RagIndexMeta` + enum'ы `ChunkingKind`/`EmbedderKind`/`IndexBackend`;
    ручной `init(from:)`+дефолты, enum'ы декодируются снисходительно — как везде);
    `RagChunking.swift` (≥2 стратегии по ТЗ: `FixedSizeChunker` размер+нахлёст и
    `StructureChunker` по Markdown-заголовкам/разделам; чистые функции); `RagEmbedding.swift`
    (`protocol Embedder` + `Vector` cosine/L2/normalize + `HashingEmbedder` детерм./тесты +
    `NLLocalEmbedder` Apple NaturalLanguage офлайн + `OllamaEmbedder` HTTP `:11434`;
    `RemoteEmbedder` — шов); `RagVectorIndex.swift`/`RagSQLiteIndex.swift` (`protocol
    VectorIndexStore`: `JSONVectorIndex` дефолт, `FlatVectorIndex` бинарный аналог FAISS
    IndexFlatL2, `SQLiteVectorIndex` через `import SQLite3` — системный модуль, БЕЗ
    зависимости в Package.swift; поиск top-K общий — `Vector.topK`, brute-force косинус);
    `RagStore.swift` (реестр `rag-indexes.json` + каталоги `rag/<id>/chunks.json`+`vectors.*`
    в Application Support, `.corrupt.json`-фолбэк, ОТДЕЛЬНО от `$chats`-автосейва);
    `RagPipeline.swift` (`RagIndexer.build` — enumerate→chunk→embed(батчи)→save→commit,
    прогресс/отмена/краш-safety: `isReady=true` ТОЛЬКО после атомарной записи → недостроенный
    индекс переживает краш «черновиком» и ретривом не берётся); `RagRetriever.swift`
    (вопрос→embed→top-K→блок под бюджет `memoryTokenBudget/2`; ЛЮБАЯ ошибка → nil, ретрив
    НИКОГДА не роняет `send()`); `RagViewModel.swift` (`@MainActor`, тонкий клиент + async
    индексация, как `RoutinesViewModel`).
  • **Эмбеддер выбирается на индекс** (`RagIndexConfig.embedder`, дефолт `.ollama`): Ollama —
    лучшее качество (нужен `ollama serve` + `ollama pull nomic-embed-text`; для русского `bge-m3`;
    панель проверяет доступность `OllamaEmbedder.isAvailable`); `.local` (Apple NL) — офлайн без
    сервера; `.hashing` — детерминизм для тестов/фолбэк. Размерность и (для `.local`) язык
    пиннятся в `RagIndexMeta` на момент индексации — ретрив берёт ТОТ ЖЕ эмбеддер, иначе не
    совпадёт по размерности (guard → переиндексировать). Бэкенд хранилища — pluggable
    (`VectorIndexes.make`), дефолт JSON (консистентно с приложением). Настоящий C++-FAISS НЕ
    подключён (нет чистого SwiftPM-пакета) — `flat` честно называется «аналог IndexFlatL2».
  • **UI**: панель `RagPanelView`/`RagIndexEditorView` (иконка-лупа `text.magnifyingglass`
    в шапке чата; NSOpenPanel — единственный файл-пикер в проекте; стратегия/бэкенд/эмбеддер,
    `ProgressView`, health-бейдж Ollama, «тестовый поиск» без LLM). Включение ретрива — per-chat
    в `ChatSettingsView` (секция «RAG»: `ragEnabled`/`ragIndexID`/`ragTopK` в `GenerationSettings`).
    Владелец списка — `@StateObject ragVM` в `ContentView` (общий на приложение). Ретрив в `send()`
    ортогонален контекст-стратегиям (идёт в память, не в историю). В FSM/сравнении RAG нет (шов).
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
- **Агент рутин (VPS) — планировщик задач 24/7 + интеграция в приложение** —
  ОТДЕЛЬНЫЙ бэкенд в каталоге `agent/` (Node 20/TypeScript), независимый от сборки
  Swift (SwiftPM видит только `Sources/`/`Tests/`). Пользователь ставит **рутины**
  (как Routines в Claude Code): промпт + расписание (cron) → агент по крону выполняет
  промпт через LLM (DeepSeek), при необходимости собирает данные через **любые MCP-серверы,
  подключённые в приложении** (generic, БЕЗ привязки к конкретному MCP), агрегирует результат
  и сохраняет локально (история видна во вкладке «Рутины»).
  • **Топология**: сервис слушает `127.0.0.1:3100` под systemd (`manager-agent.service`),
    наружу — через **Caddy** `https://<your-vps-domain>/agent/*`; агент — **generic MCP-ХОСТ**:
    подключается (stdio, SDK `StdioClientTransport`) к MCP-серверам, СИНХРОНИЗИРОВАННЫМ из приложения
    (`runner/mcpHost.ts`: спавнит те же `npx mcp-remote …`-спеки, агрегирует инструменты, квалифицирует
    `<slug>__<tool>` — порт `MCPManager`). НЕ трогать VPN(Amnezia/docker)/x-ui/xray, `yougile-mcp.service`,
    маршрут `/mcp`. Всё добавочно.
  • **Источник истины по MCP — ПРИЛОЖЕНИЕ.** Список MCP-серверов ведётся в приложении (существующая
    панель MCP, `mcp-servers.json`); приложение пушит его на агент (`PUT /agent/mcp-servers`) при входе
    во вкладку/подключении (`RoutinesViewModel.syncMcpServers`). Никаких хардкод-привязок к YouGile в коде:
    смена доски/MCP = правка только промпта рутины. Сохранение во внешние системы — через промпт (у агента
    есть все эти инструменты); встроенный sink один — `vps_local`.
  • **Источник истины по рутинам — VPS** (SQLite, better-sqlite3: `routines`/`runs`/`settings`/`mcp_servers`).
    Приложение — тонкий клиент с in-memory кэшем; мутации идут на сервер с `rev` (оптимистическая блокировка,
    409 при устаревшем). Фича НЕ участвует в локальном автосохранении.
  • **Единственная панель конфигурации — приложение.** На VPS в `/etc/manager-agent.env`
    только bootstrap (`AGENT_API_TOKEN` + порт + путь к БД). Провайдер/LLM-ключ/модель/таймзона задаются
    из приложения (`PUT /agent/settings`), хранятся в БД; секрет (`llmApiKey`) на чтение МАСКИРУЕТСЯ
    (`hasLlmKey`/`llmKeyHint`, паттерн write-only; пустой секрет в PUT не затирает). MCP-секреты (токены в
    args/env) — в `mcp_servers`, наружу (`GET /agent/mcp-servers`) НЕ отдаются (только статус/число инструментов).
  • **Режим рутины `mode`: simple | action | pipeline** (поле рутины; дефолт новых из приложения —
    `pipeline`, миграция старых рутин в БД ставит `simple` → поведение не меняется; для "action"
    отдельной миграции НЕ нужно — колонка `mode` хранит произвольную строку, снисходительный декод).
    **simple** — один агентный tool-loop с «дайджестовым» `RUNNER_SYSTEM_PROMPT` (рано выводит итог;
    для рутин «собери данные и оформи»). **action** — ОДИН tool-loop, но с `ACTION_SYSTEM_PROMPT`
    «доводи процедуру до конца» (`maxTokensBudget=undefined`, `ACTION_MAX_ITERATIONS=50`, таймаут как у
    pipeline): для самодостаточных ПРОЦЕДУР, чей промпт = весь цикл работы (разбор колонки YouGile) —
    НЕ декомпозирует и НЕ дублирует шаги, в отличие от pipeline (e2e: 1 план + 1 отчёт в журнале по
    порядку; pipeline двоил/переставлял). **pipeline** — generic порт FSM-движка
    приложения в `runner/pipeline/`: planning → execution (рой подагентов волнами при `swarm`, иначе
    последовательно) → validation (вердикт; назад в execution до `MAX_EXECUTION_RETRIES=2`) → answer
    (финальный текст = дайджест). НЕ привязан к YouGile: задача = `routine.prompt`, инструменты — любые
    из McpHost. `pipeline/parsers.ts` — ЧИСТЫЙ порт `parsePlanSteps/parseDeps/computeWaves(Кан)/
    parseVerdict/stripMarkers` (1:1 с `Models.swift`, свои тесты); `pipeline/prompts.ts` — ролевые
    промпты этапов + `subAgentPrompt` (узкий контекст: план + ТОЛЬКО выводы зависимостей);
    `pipeline/orchestrator.ts` — `runPipeline` поверх `runToolLoop` (под-вызов на этап/подагента;
    `Promise.all` чанками по `maxParallelAgents`; `usage`/transcript суммируются; потолок переходов 60).
    Headless-исключения (не портированы): инварианты, пауза-на-плане, роутер реплик, блокирующий
    `ASK_USER`, крэш-resume промежуточного состояния. Бюджет pipeline — таймаут `pipelineTimeoutMs`
    (деф. 600с), per-step — `maxIterations`; токен-budget внутри фазы не форсит стоп.
  • **Серверная логика** (`agent/src/`): `runner/llm.ts` — порт `DeepSeekClient.runToolLoop`;
    `runner/mcpHost.ts` — generic мульти-MCP хост; `runner/runner.ts` — прогон (инструменты из хоста→
    tool-loop ИЛИ pipeline по `routine.mode`→persist, статусы running/ok/error/timeout/skipped_overlap/missed, таймаут, лимиты);
    `scheduler/scheduler.ts` — croner (таймзоны), overlap-guard, catch-up (опц.), примирение зависших
    running→error; `http/` — Fastify, bearer-auth, единый формат ошибок, идемпотентность trigger,
    cursor-пагинация; эндпоинты `…/settings`, `…/mcp-servers`, `…/routines*`, `…/runs*`, `…/chat/ask`.
  • **Приложение**: `RoutineModels.swift` (DTO, ленивый декод, unknown-enum→`.unknown`; `MCPServerDTO`/
    `McpServerStatusDTO`), `VPSAgentClient.swift` (struct; ЧИСТЫЕ static-построители запроса — тестируемы
    без сети; `get/putMcpServers`), `RoutinesViewModel.swift` (тонкий клиент + `syncMcpServers`),
    `RoutinesPanelView.swift` (вью-кирпичики: строка/детали/прогон) + `RoutineEditorView.swift`
    (редактор/«Подключение к VPS»/«Настройки агента»). **Вход — отдельная вкладка «Рутины»**
    (`SidebarMode.routines` в `ContentView`: сегмент «Чаты|Проекты|Рутины», сайдбар = список рутин,
    detail = `RoutineDetailPane` с историей и дайджестом на виду). Подключение (адрес+токен) — bootstrap
    в `KeyStore.agentURL`/`agentToken` (не в git).
  • **Тесты**: сервер — Vitest (`agent/test/`, без сети/LLM: заглушки + `:memory:` SQLite,
    Fastify `inject`); приложение — `RoutinesTests.swift` (round-trip DTO, unknown-fallback,
    маскирование, построители запроса). Запуск: `cd agent && npm test` и `swift test`.
  • **Деплой**: `agent/deploy/deploy.sh` (идемпотентно, по SSH от root) — выкладка в
    `/opt/manager-agent`, `npm ci --omit=dev`, systemd-юнит, маршрут Caddy (с бэкапом+validate),
    генерирует `AGENT_API_TOKEN` (вводится в приложении). БД переживает передеплой. Подробности +
    **грабли передеплоя** (рестарт ТОЛЬКО `systemctl restart --no-block`; флакающий scp по паролю — проверять
    перенос; `npx mcp-remote` нужен HOME/npm-кэш — уже в юните; ~15с старт) + end-to-end проверка —
    `agent/README.md`. Конкретные адрес/домен/токен инстанса в git НЕТ: см. `agent/deploy/instance.local.md`
    (gitignored) или локальную память. **Как расширять** (новый sink/endpoint/поле рутины) — в README; новые
    поля/статусы декодировать снисходительно С ОБЕИХ сторон.
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

# Тесты (юнит-тесты чистой логики FSM/роя/парсеров, таргет ManagerAssistantTests):
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # XCTest есть ТОЛЬКО в Xcode
swift test           # 120+ тестов; CommandLineTools НЕ годится (нет модуля XCTest)

# Агент рутин (отдельный бэкенд, Node 20) — свои сборка/тесты, независимы от SwiftPM:
cd agent && npm ci && npm run build && npm test   # Vitest, всё офлайн (55+ тестов)
```

- Полный Xcode установлен, но его лицензия может быть не принята — поэтому
  `DEVELOPER_DIR` для сборки указывает на Command Line Tools. ВАЖНО: `swift test`
  требует полный Xcode-тулчейн (XCTest нет в Command Line Tools) — для тестов ставь
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `swift build`/`run` под
  Command Line Tools тест-таргет игнорируют (компилируются только при `swift test`).
- Иконка генерируется скриптами в `icon/` → `Sources/ManagerAssistant/Resources/AppIcon.icns`
  (ресурс пакета: в рантайме ставится через `NSApp.applicationIconImage`).
- Зависимость MarkdownUI ещё в Package.swift, но в рендере НЕ используется:
  ответы агента рисует `MarkdownText` одним `Text` (сплошное выделение). Можно убрать.

## Проверка изменений (workflow)

1. `swift build` — без ошибок и предупреждений.
2. `swift test` (под Xcode-тулчейном, см. «Сборка и запуск») — все тесты зелёные.
   Покрывают ЧИСТУЮ логику: таблицу переходов TaskFSM, планировщик волн роя
   (parseDeps/computeWaves), парсеры PipelinePrompts (план/вердикт/ASK_USER/смена
   стадии/маркеры), миграцию Codable (новые поля + старый JSON без них), RAG
   (`RagTests`: обе стратегии чанкинга, cosine/top-K на HashingEmbedder, round-trip
   каждого бэкенда JSON/flat/SQLite, e2e `RagIndexer.build`). При правке
   FSM/роя/парсеров/RAG — гонять тесты.
3. `bash install.sh && open -a /Applications/ManagerAssistant.app` — поднять реальное приложение.
4. UI-проверки делались через computer-use (скриншоты): отправить сообщение,
   проверить фичу глазами. У пользователя поверх поля ввода бывает невидимый
   оверлей Wispr Flow — кликать по левому краю поля.
5. Перед коммитом: скан на ключи (см. выше).

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
