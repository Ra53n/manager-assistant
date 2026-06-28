// RoutineEditorView.swift — формы рутин: редактор, подключение к VPS, настройки
// агента. Карточки-секции (FormCard) + полноширинные bordered-инпуты (LTR).
// Никаких привязок к конкретному MCP: сохранение результата — локально (видно во
// вкладке «Рутины»); во внешние системы — через промпт (у агента есть все MCP).

import SwiftUI

/// Секция-карточка: заголовок + контейнер с фоном.
struct FormCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

/// Поле: подпись сверху + bordered-инпут на всю ширину (текст слева).
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity)
        }
    }
}

private func borderedField(_ text: Binding<String>, prompt: String, mono: Bool = false) -> some View {
    let field = TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
    return Group { if mono { field.font(.body.monospaced()) } else { field } }
}

private func borderedSecure(_ text: Binding<String>, prompt: String) -> some View {
    SecureField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
}

// MARK: - Редактор рутины (создание/правка)

struct RoutineEditorView: View {
    @ObservedObject var vm: RoutinesViewModel
    let routine: Routine?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var prompt: String
    @State private var cron: String
    @State private var timezone: String
    @State private var enabled: Bool
    @State private var catchUpOnStart: Bool
    @State private var model: String
    @State private var maxIterations: Int
    @State private var mode: String
    @State private var swarm: Bool
    @State private var maxParallelAgents: Int

    init(vm: RoutinesViewModel, routine: Routine?) {
        self.vm = vm
        self.routine = routine
        let r = routine
        _name = State(initialValue: r?.name ?? "")
        _prompt = State(initialValue: r?.prompt ?? "")
        _cron = State(initialValue: r?.cron ?? "0 9 * * *")
        _timezone = State(initialValue: r?.timezone ?? "Europe/Moscow")
        _enabled = State(initialValue: r?.enabled ?? true)
        _catchUpOnStart = State(initialValue: r?.catchUpOnStart ?? false)
        _model = State(initialValue: r?.model ?? "")
        _maxIterations = State(initialValue: r?.maxIterations ?? 6)
        // Новая рутина по умолчанию — pipeline (план→рой→проверка→ответ); существующую
        // читаем как есть (legacy/дайджест → simple).
        _mode = State(initialValue: r?.mode ?? "pipeline")
        _swarm = State(initialValue: r?.swarm ?? true)
        _maxParallelAgents = State(initialValue: r?.maxParallelAgents ?? 3)
    }

    private let presets: [(String, String)] = [
        ("Каждый день 09:00", "0 9 * * *"),
        ("По будням 09:00", "0 9 * * 1-5"),
        ("Каждый час", "0 * * * *"),
        ("Каждые 15 мин", "*/15 * * * *"),
        ("Пн 10:00", "0 10 * * 1"),
    ]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && !cron.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(routine == nil ? "Новая рутина" : "Изменить рутину").font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FormCard("Основное") {
                        LabeledField(label: "Имя") {
                            borderedField($name, prompt: "Например, утренняя сводка")
                        }
                        LabeledField(label: "Промпт — что делать агенту") {
                            TextEditor(text: $prompt)
                                .frame(minHeight: 84)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                        Toggle("Включена", isOn: $enabled)
                    }

                    FormCard("Расписание") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(presets, id: \.1) { p in
                                    Button(p.0) { cron = p.1 }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                        LabeledField(label: "cron-выражение") {
                            borderedField($cron, prompt: "0 9 * * *", mono: true)
                        }
                        LabeledField(label: "Таймзона (IANA)") {
                            borderedField($timezone, prompt: "Europe/Moscow")
                        }
                        Text("Формат: минуты часы день месяц день_недели. Сверху — пресеты.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    FormCard("Сохранение результата") {
                        Label("Результат всегда сохраняется на VPS и виден во вкладке «Рутины».",
                              systemImage: "internaldrive").font(.callout)
                        Text("Чтобы сохранить во внешнюю систему (например, создать задачу в YouGile) — попроси об этом прямо в промпте: у агента есть все твои MCP-инструменты.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    FormCard("Режим исполнения") {
                        Picker("Режим", selection: $mode) {
                            Text("Действие (процедура за один проход)").tag("action")
                            Text("Пайплайн (план → рой → проверка → ответ)").tag("pipeline")
                            Text("Простой (дайджест)").tag("simple")
                        }
                        .pickerStyle(.radioGroup)
                        if mode == "pipeline" {
                            Text("Цель декомпозируется на план, шаги выполняются агентами, затем результат проверяется и собирается в итог. Подходит для исследований/целей, выигрывающих от декомпозиции и распараллеливания.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Рой агентов (параллельные шаги волнами)", isOn: $swarm)
                            if swarm {
                                Stepper("Параллельных агентов: \(maxParallelAgents)", value: $maxParallelAgents, in: 2...6)
                            }
                        } else if mode == "action" {
                            Text("Один проход агента с инструментами, который доводит ПРОЦЕДУРУ до конца (не обрывается рано и не повторяет шаги). Подходит, когда промпт рутины — это весь цикл работы (например, разбор колонки YouGile).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Один агентный проход «собери данные и оформи итог» — быстро и дёшево, для дайджестов. Для процедур-действий используй «Действие».")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    FormCard("Дополнительно") {
                        LabeledField(label: "Модель (пусто = из настроек агента)") {
                            borderedField($model, prompt: "deepseek-chat")
                        }
                        if mode == "action" {
                            Text("Лимит итераций инструментов — автоматический (до завершения процедуры).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Stepper(mode == "pipeline"
                                    ? "Макс. итераций инструментов на шаг: \(maxIterations)"
                                    : "Макс. итераций инструментов: \(maxIterations)",
                                    value: $maxIterations, in: 1...20)
                        }
                        Toggle("Догонять пропущенный слот при старте", isOn: $catchUpOnStart)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Сохранить") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || vm.isWorking)
            }
            .padding()
        }
        .frame(width: 580, height: 660)
    }

    private func save() {
        Task {
            let ok: Bool
            if let r = routine {
                ok = await vm.update(id: r.id, UpdateRoutineRequest(
                    rev: r.rev, name: name, prompt: prompt, cron: cron, timezone: timezone,
                    enabled: enabled, catchUpOnStart: catchUpOnStart, model: model,
                    maxIterations: maxIterations, mode: mode, swarm: swarm,
                    maxParallelAgents: maxParallelAgents))
            } else {
                ok = await vm.create(CreateRoutineRequest(
                    name: name, prompt: prompt, cron: cron, timezone: timezone, enabled: enabled,
                    catchUpOnStart: catchUpOnStart, model: model, maxIterations: maxIterations,
                    mode: mode, swarm: swarm, maxParallelAgents: maxParallelAgents))
            }
            if ok { dismiss() }
        }
    }
}

// MARK: - Подключение к VPS (один понятный шаг)

struct ConnectionSettingsView: View {
    @ObservedObject var vm: RoutinesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var url: String = KeyStore.agentURL
    @State private var token: String = KeyStore.agentToken

    private var isTesting: Bool {
        if case .testing = vm.connectionState { return true } else { return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Подключение к VPS").font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FormCard {
                        LabeledField(label: "Адрес агента на VPS") {
                            borderedField($url, prompt: "https://vps.example")
                        }
                        Text("Корневой адрес (без /agent). Путь /agent добавляется автоматически.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledField(label: "Токен доступа") {
                            borderedSecure($token, prompt: "AGENT_API_TOKEN с VPS")
                        }
                        Text("Печатается скриптом деплоя. Хранится локально в ~/.config/manager-assistant/, не в git.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    statusRow
                }
                .padding()
            }

            Divider()
            HStack {
                if vm.isConfigured {
                    Button("Отключиться", role: .destructive) {
                        vm.disconnect(); url = ""; token = ""
                    }
                }
                Spacer()
                Button(action: connect) {
                    if isTesting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Проверяю…") }
                    } else {
                        Text("Подключиться")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || token.isEmpty || isTesting)
            }
            .padding()
        }
        .frame(width: 540, height: 470)
    }

    @ViewBuilder private var statusRow: some View {
        switch vm.connectionState {
        case .idle:
            Label("Заполни адрес и токен, затем нажми «Подключиться».", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Проверяю подключение…") }
                .font(.callout)
        case .ok(let host):
            Label("Подключено к \(host)", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .font(.callout).foregroundStyle(.red)
        }
    }

    private func connect() {
        Task {
            let ok = await vm.connect(url: url, token: token)
            if ok {
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            }
        }
    }
}

// MARK: - Настройки агента (server-side): провайдер/модель/таймзона/LLM-ключ

struct AgentSettingsView: View {
    @ObservedObject var vm: RoutinesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider: AgentProvider = .deepseek
    @State private var model: String = ""
    @State private var timezone: String = "Europe/Moscow"
    @State private var llmKey: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Настройки агента").font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FormCard("LLM") {
                        LabeledField(label: "Провайдер") {
                            Picker("", selection: $provider) {
                                Text("DeepSeek").tag(AgentProvider.deepseek)
                                Text("OpenRouter").tag(AgentProvider.openrouter)
                            }.labelsHidden().pickerStyle(.menu)
                        }
                        LabeledField(label: "Модель") {
                            borderedField($model, prompt: "deepseek-chat")
                        }
                        LabeledField(label: "API-ключ") {
                            borderedSecure($llmKey, prompt: keyPlaceholder(vm.settings?.hasLlmKey ?? false, vm.settings?.llmKeyHint ?? ""))
                        }
                        Text("Ключ хранится на VPS, не в git. Оставь пустым, чтобы не менять.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    FormCard("Расписание") {
                        LabeledField(label: "Таймзона по умолчанию") {
                            borderedField($timezone, prompt: "Europe/Moscow")
                        }
                    }
                    FormCard("MCP-инструменты") {
                        Label("Список MCP-серверов берётся из приложения (кнопка-гаечный ключ) и синхронизируется на агент автоматически.",
                              systemImage: "wrench.and.screwdriver").font(.callout)
                        Text("Агент использует те же серверы, что и чат. Менять доску/инструменты можно прямо в промпте рутины.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Сохранить") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(vm.isWorking)
            }
            .padding()
        }
        .frame(width: 560, height: 480)
        .task {
            if vm.settings == nil { await vm.loadSettings() }
            applyFromSettings()
        }
    }

    private func applyFromSettings() {
        guard !loaded, let s = vm.settings else { return }
        provider = s.provider == .unknown ? .deepseek : s.provider
        model = s.defaultModel
        timezone = s.defaultTimezone
        loaded = true
    }

    private func save() {
        var req = UpdateAgentSettingsRequest()
        req.provider = provider == .unknown ? nil : provider.rawValue
        req.defaultModel = model
        req.defaultTimezone = timezone
        if !llmKey.trimmingCharacters(in: .whitespaces).isEmpty { req.llmApiKey = llmKey }
        Task {
            await vm.saveSettings(req)
            if vm.errorText == nil { dismiss() }
        }
    }

    private func keyPlaceholder(_ has: Bool, _ hint: String) -> String {
        has ? "Ключ задан (\(hint)) — оставь пустым" : "Вставь ключ"
    }
}
