// ContentView.swift — весь UI приложения (SwiftUI).
//
// Структура вьюх в этом файле:
//   ContentView            — NavigationSplitView: сайдбар чатов + детальная область;
//                             листы: ProviderKeysView (🔑 в сайдбаре)
//   ChatDetailView          — один чат: сообщения, ошибка, поле ввода;
//                             тулбар: счётчик токенов чата + ⚙︎ настройки;
//                             листы: ChatSettingsView → ModelPickerView
//   ChatSettingsView         — параметры генерации текущего чата (модель,
//                             формат ответа, температура, top_p, max_tokens,
//                             стоп-последовательности; \n в стопах = перенос)
//   ModelPickerView          — выбор модели с поиском, группировка по провайдеру
//   ProviderKeysView         — поля API-ключей провайдеров (пишет в KeyStore)
//   MessageBubble            — пузырь сообщения: user = простой текст справа,
//                             assistant = Markdown слева; под ответом — строка
//                             метрик (время · ↑↓токены · $); копирование по
//                             наведению (в буфер уходит исходный Markdown)
//   SliderRow                — переиспользуемая строка «заголовок+слайдер»
//
// UI-ловушки, на которые уже наступали (не повторять):
//  - .roundedBorder у TextField на macOS делает поле однострочным — для
//    многострочного ввода нужен .plain + axis: .vertical + lineLimit(1...5);
//  - длинный текст в title TextField внутри Form(.grouped) переносится и
//    «едет» — подсказки передавать через prompt:, не через title;
//  - Label в .toolbar рендерится без текста — для текста использовать HStack.

import SwiftUI
import AppKit
import MarkdownUI

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var showingKeys = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingKeys) {
            ProviderKeysView(vm: vm)
        }
    }

    // MARK: - Боковая навигация по чатам

    private var sidebar: some View {
        List(selection: $vm.selectedChatID) {
            ForEach(vm.chats) { chat in
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .foregroundColor(.secondary)
                    Text(chat.title)
                        .lineLimit(1)
                    Spacer()
                    if chat.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
                .tag(chat.id)
                .contextMenu {
                    Button(role: .destructive) {
                        vm.deleteChat(chat.id)
                    } label: {
                        Label("Удалить чат", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: vm.deleteChats)
        }
        .navigationTitle("Чаты")
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button { showingKeys = true } label: {
                    Label("API-ключи", systemImage: "key")
                }
                .help("API-ключи провайдеров")
            }
            ToolbarItem {
                Button(action: vm.newChat) {
                    Label("Новый чат", systemImage: "square.and.pencil")
                }
                .help("Новый чат")
            }
        }
    }

    // MARK: - Детальная область

    @ViewBuilder
    private var detail: some View {
        if vm.selectedChat != nil {
            ChatDetailView(vm: vm)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Нет выбранного чата")
                    .foregroundColor(.secondary)
                Button("Создать чат", action: vm.newChat)
            }
            .frame(minWidth: 480, minHeight: 600)
        }
    }
}

/// Область одного чата: список сообщений + поле ввода.
struct ChatDetailView: View {
    @ObservedObject var vm: ChatViewModel
    @State private var showingSettings = false

    private var messages: [ChatMessage] { vm.selectedChat?.messages ?? [] }
    private var isLoading: Bool { vm.selectedChat?.isLoading ?? false }
    private var errorText: String? { vm.selectedChat?.errorText }

    /// Binding к настройкам выбранного чата.
    private var settingsBinding: Binding<GenerationSettings> {
        Binding(
            get: { vm.selectedChat?.settings ?? .default },
            set: { vm.updateSelectedSettings($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            errorBar
            truncationBar
            inputBar
        }
        .frame(minWidth: 480, minHeight: 600)
        .navigationTitle(vm.selectedChat?.title ?? "Чат")
        .toolbar {
            ToolbarItem(placement: .status) {
                if let chat = vm.selectedChat, chat.totalTokens > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.hexagongrid")
                        Text("\(chat.totalTokens.formatted()) токенов")
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .help("Токены в этом чате — запрос: \(chat.promptTokens.formatted()) · ответ: \(chat.completionTokens.formatted()) · всего: \(chat.totalTokens.formatted())")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Параметры генерации")
            }
        }
        .sheet(isPresented: $showingSettings) {
            ChatSettingsView(vm: vm, settings: settingsBinding)
        }
    }

    // MARK: - Список сообщений

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        Text("Напиши сообщение, чтобы начать диалог с \(vm.selectedChat?.settings.model ?? "моделью").")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    compactionBanner
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(vm.selectedChat?.settings.model ?? "Модель") печатает…")
                                .foregroundColor(.secondary)
                                .font(.callout)
                        }
                        .id("loading")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isLoading) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.selectedChatID) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    /// Плашка вверху ленты: сколько старых сообщений свёрнуто в саммари.
    /// Наведение показывает само саммари (полезно для отладки и доверия).
    @ViewBuilder
    private var compactionBanner: some View {
        if let chat = vm.selectedChat {
            if chat.isSummarizing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Сжимаю старые сообщения в саммари…")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if chat.summarizedUpTo > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text("\(chat.summarizedUpTo) сообщ. выше сжаты в саммари — модель видит их кратко")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(chat.summary)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Строка ошибки

    @ViewBuilder
    private var errorBar: some View {
        if let error = errorText {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Предупреждение об усечении контекста

    /// Жёлтый бар: история чата рискует не влезть в окно выбранной модели —
    /// провайдер (например, OpenRouter middle-out) молча вырежет середину.
    @ViewBuilder
    private var truncationBar: some View {
        if let chat = vm.selectedChat, let warning = vm.truncationWarning(for: chat) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "scissors")
                    .foregroundColor(.yellow)
                Text(warning)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.12))
        }
    }

    // MARK: - Поле ввода

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Сообщение…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)            // растёт до 5 строк, дальше — скролл
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                )
                .onSubmit(vm.send)

            Button(action: vm.send) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!vm.canSend)
        }
        .padding()
    }
}

/// Лист настроек параметров генерации для текущего чата.
struct ChatSettingsView: View {
    @ObservedObject var vm: ChatViewModel
    @Binding var settings: GenerationSettings
    @Environment(\.dismiss) private var dismiss

    /// Стоп-последовательности редактируем как строку «через запятую».
    @State private var stopText: String = ""
    @State private var showingModelPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Параметры генерации")
                    .font(.headline)
                Spacer()
                Button("Сбросить") {
                    settings = .default
                    stopText = ""
                }
            }
            .padding()

            Divider()

            Form {
                Section("Модель") {
                    Button {
                        showingModelPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(settings.model)
                                Text(settings.provider.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Button {
                            vm.loadModels(force: true)
                        } label: {
                            Label("Обновить список", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        if vm.isLoadingModels {
                            ProgressView().controlSize(.small)
                        }
                        if let err = vm.modelsError {
                            Text(err).font(.caption).foregroundColor(.orange)
                        }
                    }
                    Text("Нажми на модель, чтобы выбрать с поиском. Список — из провайдеров с ключом (🔑 слева вверху).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Формат ответа") {
                    TextEditor(text: $settings.responseFormat)
                        .frame(minHeight: 56)
                        .font(.body)
                    Text("Как форматировать ответ (свободная инструкция). Напр.: «Маркированный список из 3 пунктов» или «верни строго JSON-объектом». Пусто — без требований к формату.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    SliderRow(
                        title: "Температура",
                        subtitle: "Креативность ответа. Выше — разнообразнее.",
                        value: $settings.temperature,
                        range: GenerationSettings.temperatureRange,
                        step: 0.1,
                        format: "%.1f"
                    )
                    SliderRow(
                        title: "Top P",
                        subtitle: "Nucleus sampling. 1.0 — без ограничения.",
                        value: $settings.topP,
                        range: GenerationSettings.topPRange,
                        step: 0.05,
                        format: "%.2f"
                    )
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Макс. токенов")
                            Spacer()
                            Text("\(settings.maxTokens)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.maxTokens) },
                                set: { settings.maxTokens = Int($0) }
                            ),
                            in: Double(GenerationSettings.maxTokensRange.lowerBound)...Double(GenerationSettings.maxTokensRange.upperBound),
                            step: 256
                        )
                        Text("Максимальная длина ответа модели.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("История (сжатие контекста)") {
                    Toggle("Сжимать старые сообщения в саммари", isOn: $settings.compactionEnabled)
                    if settings.compactionEnabled {
                        Stepper(
                            value: $settings.historyWindow,
                            in: GenerationSettings.historyWindowRange,
                            step: 2
                        ) {
                            HStack {
                                Text("Без сжатия — последние")
                                Spacer()
                                Text("\(settings.historyWindow) сообщ.")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    Text("В запрос идёт саммари старой части диалога + последние N сообщений как есть. Сжатие выполняется фоном каждые N сообщений. Экономит токены в длинных чатах.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Стоп-последовательности") {
                    TextField("", text: $stopText, prompt: Text("через запятую, напр.: \\n, END"))
                        .onChange(of: stopText) { _ in
                            settings.stop = Self.parseStop(stopText)
                        }
                    Text("Генерация обрывается, как только модель напишет любую из этих строк (сама строка в ответ не попадает; до \(GenerationSettings.maxStopCount) штук). \\n — перенос строки.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Label(
                        "DeepSeek не поддерживает top_k, frequency_penalty и presence_penalty — они игнорируются API. У reasoning-моделей температура и top_p тоже не действуют.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
        .onAppear {
            stopText = Self.formatStop(settings.stop)
            vm.loadModels()
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerView(
                models: vm.availableModels,
                provider: $settings.provider,
                model: $settings.model
            )
        }
    }

    /// Парсит «a, b, c» в массив, превращая литералы \n и \t в реальные символы.
    static func parseStop(_ text: String) -> [String] {
        let items: [String] = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\\n", with: "\n")
                     .replacingOccurrences(of: "\\t", with: "\t") }
        return Array(items.prefix(GenerationSettings.maxStopCount))
    }

    /// Обратное преобразование для отображения в поле (реальные символы → \n, \t).
    static func formatStop(_ stops: [String]) -> String {
        stops.map { $0.replacingOccurrences(of: "\n", with: "\\n")
                      .replacingOccurrences(of: "\t", with: "\\t") }
             .joined(separator: ", ")
    }
}

/// Строка с заголовком, подзаголовком, текущим значением и слайдером.
struct SliderRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Лист выбора модели с поиском по всему списку (DeepSeek + OpenRouter).
struct ModelPickerView: View {
    let models: [ModelOption]
    @Binding var provider: Provider
    @Binding var model: String
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""

    private var filtered: [ModelOption] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.model.lowercased().contains(q) || $0.provider.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Выбор модели")
                    .font(.headline)
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            // Поле поиска.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("", text: $search, prompt: Text("Поиск модели…"))
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("Ничего не найдено")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Provider.allCases, id: \.self) { prov in
                        let opts = filtered.filter { $0.provider == prov }
                        if !opts.isEmpty {
                            Section("\(prov.displayName) (\(opts.count))") {
                                ForEach(opts) { opt in
                                    Button {
                                        provider = opt.provider
                                        model = opt.model
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(opt.model)
                                                .lineLimit(1)
                                            Spacer()
                                            if opt.provider == provider && opt.model == model {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.accentColor)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 560)
    }
}

/// Лист с API-ключами провайдеров (хранятся вне репозитория через KeyStore).
struct ProviderKeysView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var keys: [Provider: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("API-ключи провайдеров")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                ForEach(Provider.allCases, id: \.self) { provider in
                    Section(provider.displayName) {
                        TextField(
                            "",
                            text: Binding(
                                get: { keys[provider] ?? "" },
                                set: { keys[provider] = $0 }
                            ),
                            prompt: Text(provider.keyHint)
                        )
                        .font(.system(.body, design: .monospaced))
                        Text(provider.keyHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Label(
                        "Ключи сохраняются локально в ~/.config/manager-assistant/ и не попадают в git. Пустое поле — удалить ключ.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    for provider in Provider.allCases {
                        KeyStore.setKey(keys[provider] ?? "", for: provider)
                    }
                    vm.loadModels(force: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .onAppear {
            for provider in Provider.allCases {
                keys[provider] = KeyStore.key(for: provider)
            }
        }
    }
}

/// «Пузырь» одного сообщения: user — справа (обычный текст), assistant — слева (Markdown).
/// При наведении показывается кнопка «Копировать».
struct MessageBubble: View {
    let message: ChatMessage

    @State private var hovering = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 40) }
                bubble
                if !isUser { Spacer(minLength: 40) }
            }
            if !isUser, let metrics = message.metrics {
                Text(Self.metricsText(metrics))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .help(Self.metricsTooltip(metrics))
            }
            copyControl
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { hovering = $0 }
    }

    /// Содержимое пузыря: пользовательский текст — как есть, ответ агента — как Markdown.
    private var bubble: some View {
        Group {
            if isUser {
                Text(message.content)
            } else {
                Markdown(message.content)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUser ? Color.accentColor.opacity(0.9) : Color(nsColor: .windowBackgroundColor))
        .foregroundColor(isUser ? .white : .primary)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(isUser ? 0 : 0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Кнопка копирования (появляется при наведении, на короткое время — подтверждение).
    private var copyControl: some View {
        Button(action: copy) {
            Label(copied ? "Скопировано" : "Копировать",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(hovering || copied ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .padding(.horizontal, 4)
        .frame(height: 16)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// Короткая строка метрик под ответом: время · токены · стоимость.
    static func metricsText(_ m: MessageMetrics) -> String {
        var parts: [String] = [
            String(format: "%.1f с", m.duration),
            "↑\(m.promptTokens.formatted()) ↓\(m.completionTokens.formatted()) ток.",
        ]
        if let cost = m.totalCost {
            parts.append(formatCost(cost))
        }
        return parts.joined(separator: " · ")
    }

    /// Подробный тултип: разбивка стоимости запрос/ответ.
    static func metricsTooltip(_ m: MessageMetrics) -> String {
        var lines = [
            "Время ответа: \(String(format: "%.2f", m.duration)) с",
            "Токены: запрос \(m.promptTokens), ответ \(m.completionTokens), всего \(m.totalTokens)",
        ]
        if let p = m.promptCost, let c = m.completionCost {
            lines.append("Стоимость: запрос \(formatCost(p)) + ответ \(formatCost(c)) = \(formatCost(p + c))")
        } else {
            lines.append("Стоимость: цена модели неизвестна")
        }
        return lines.joined(separator: "\n")
    }

    static func formatCost(_ c: Double) -> String {
        if c <= 0 { return "$0" }
        if c < 0.01 { return String(format: "$%.6f", c) }
        return String(format: "$%.4f", c)
    }
}
