import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
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
            inputBar
        }
        .frame(minWidth: 480, minHeight: 600)
        .navigationTitle(vm.selectedChat?.title ?? "Чат")
        .toolbar {
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
            ChatSettingsView(settings: settingsBinding)
        }
    }

    // MARK: - Список сообщений

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        Text("Напиши сообщение, чтобы начать диалог с DeepSeek.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("DeepSeek печатает…")
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

    // MARK: - Поле ввода

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Сообщение…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(vm.send)

            Button(action: vm.send) {
                Image(systemName: "paperplane.fill")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!vm.canSend)
        }
        .padding()
    }
}

/// Лист настроек параметров генерации для текущего чата.
struct ChatSettingsView: View {
    @Binding var settings: GenerationSettings
    @Environment(\.dismiss) private var dismiss

    /// Стоп-последовательности редактируем как строку «через запятую».
    @State private var stopText: String = ""

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
        .frame(width: 480, height: 520)
        .onAppear {
            stopText = Self.formatStop(settings.stop)
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

/// «Пузырь» одного сообщения: user — справа, assistant — слева.
struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.content)
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
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
