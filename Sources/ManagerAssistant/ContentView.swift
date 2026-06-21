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

/// Вкладки сайдбара: обычные чаты vs проекты (cowork).
enum SidebarMode: String, CaseIterable, Identifiable {
    case chats, projects
    var id: String { rawValue }
    var label: String { self == .chats ? "Чаты" : "Проекты" }
}

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var showingKeys = false
    @State private var showingComparison = false
    @State private var mode: SidebarMode = .chats
    @State private var showingCreateProject = false
    @State private var panelProjectID: UUID?              // открытая панель проекта
    @State private var expanded: Set<UUID> = []           // раскрытые проекты

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingKeys) {
            ProviderKeysView(vm: vm)
        }
        .sheet(isPresented: $showingComparison) {
            ComparisonView(vm: vm)
        }
        .sheet(isPresented: $showingCreateProject) {
            ProjectCreateView { title, instructions in
                let pid = vm.newProject(title: title, brief: instructions)
                vm.newChat(inProject: pid)
                mode = .projects
                expanded.insert(pid)
            }
        }
        .sheet(item: Binding(get: { panelProjectID.map { IDBox(id: $0) } },
                             set: { panelProjectID = $0?.id })) { box in
            ProjectPanelView(vm: vm, projectID: box.id)
        }
    }

    // MARK: - Боковая навигация: переключатель Чаты | Проекты + список

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(SidebarMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            Group {
                if mode == .chats { chatsList } else { projectsList }
            }
        }
        .frame(minWidth: 220)
        .navigationTitle(mode.label)
        .toolbar {
            // Меню «прочее» — чтобы не плодить иконки в тулбаре.
            ToolbarItem {
                Menu {
                    Button { showingKeys = true } label: { Label("API-ключи", systemImage: "key") }
                    Button { showingComparison = true } label: { Label("Сравнение моделей", systemImage: "rectangle.split.3x1") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Ключи, сравнение моделей")
            }
            // Одна заметная «+», контекст-зависимая.
            ToolbarItem {
                Button {
                    if mode == .chats { vm.newChat() } else { showingCreateProject = true }
                } label: {
                    Label(mode == .chats ? "Новый чат" : "Новый проект",
                          systemImage: mode == .chats ? "square.and.pencil" : "folder.badge.plus")
                }
                .help(mode == .chats ? "Новый чат" : "Новый проект")
            }
        }
    }

    // Список обычных чатов (без проекта).
    private var chatsList: some View {
        List(selection: $vm.selectedChatID) {
            if vm.looseChats.isEmpty {
                Text("Чатов пока нет. Нажми «+».")
                    .font(.callout).foregroundColor(.secondary)
            }
            ForEach(vm.looseChats) { chat in chatRow(chat) }
        }
    }

    // Список проектов: каждый — раскрывающийся, со своими диалогами (cowork).
    private var projectsList: some View {
        List(selection: $vm.selectedChatID) {
            if vm.projects.filter({ !$0.archived }).isEmpty {
                Text("Проектов пока нет. Нажми «+», задай название — и пиши.")
                    .font(.callout).foregroundColor(.secondary)
            }
            ForEach(vm.projects.filter { !$0.archived }) { project in
                projectRow(project)
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(project.id) },
            set: { v in if v { expanded.insert(project.id) } else { expanded.remove(project.id) } }
        )) {
            ForEach(vm.chats(in: project.id)) { chat in chatRow(chat) }
            Button {
                vm.newChat(inProject: project.id)
                expanded.insert(project.id)
            } label: {
                Label("Новый диалог", systemImage: "plus.bubble")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundColor(.secondary)
                Text(project.title).lineLimit(1)
                Spacer()
                Button { panelProjectID = project.id } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Память и инструкции проекта")
            }
            .contextMenu {
                Button { vm.newChat(inProject: project.id); expanded.insert(project.id) } label: {
                    Label("Новый диалог", systemImage: "plus.bubble")
                }
                Button { panelProjectID = project.id } label: { Label("Открыть проект", systemImage: "folder") }
                Button(role: .destructive) { vm.deleteProject(id: project.id) } label: {
                    Label("Удалить проект", systemImage: "trash")
                }
            }
        }
    }

    private func chatRow(_ chat: Chat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left").foregroundColor(.secondary)
            Text(chat.title).lineLimit(1)
            Spacer()
            if chat.isLoading { ProgressView().controlSize(.mini) }
        }
        .tag(chat.id)
        .contextMenu {
            Button(role: .destructive) { vm.deleteChat(chat.id) } label: {
                Label("Удалить чат", systemImage: "trash")
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
                Image(systemName: mode == .chats ? "bubble.left.and.bubble.right" : "folder")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(mode == .chats ? "Нет выбранного чата" : "Выбери проект и диалог")
                    .foregroundColor(.secondary)
                Button(mode == .chats ? "Создать чат" : "Создать проект") {
                    if mode == .chats { vm.newChat() } else { showingCreateProject = true }
                }
            }
            .frame(minWidth: 480, minHeight: 600)
        }
    }
}

/// Обёртка UUID для .sheet(item:).
private struct IDBox: Identifiable { let id: UUID }

/// Область одного чата: список сообщений + поле ввода.
struct ChatDetailView: View {
    @ObservedObject var vm: ChatViewModel
    @State private var showingSettings = false
    @State private var showingFacts = false
    @State private var showingMemory = false
    @State private var showingProjectPanel = false
    @State private var showingInvariants = false
    /// Черновик записи памяти (сохранение из сообщения / добавление вручную).
    @State private var memoryDraft: MemoryDraft?
    /// Черновик секции проекта (сохранение сообщения «В проект»).
    @State private var projectDraft: ProjectEntryDraft?
    /// Измеренная высота текста в поле ввода — чтобы поле росло до предела,
    /// а дальше включался скролл колесом (см. inputBar).
    @State private var inputContentHeight: CGFloat = ChatDetailView.inputMinHeight

    /// Высота поля ввода: от одной строки до ~5–6, дальше — скролл.
    static let inputMinHeight: CGFloat = 22
    static let inputMaxHeight: CGFloat = 120

    private var messages: [ChatMessage] { vm.selectedChat?.messages ?? [] }
    private var isLoading: Bool { vm.selectedChat?.isLoading ?? false }
    private var errorText: String? { vm.selectedChat?.errorText }
    private var branchingActive: Bool { vm.selectedChat?.settings.contextStrategy == .branching }
    private var factsActive: Bool { vm.selectedChat?.settings.contextStrategy == .stickyFacts }

    /// Binding к настройкам выбранного чата.
    private var settingsBinding: Binding<GenerationSettings> {
        Binding(
            get: { vm.selectedChat?.settings ?? .default },
            set: { vm.updateSelectedSettings($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            branchBar
            pipelineBar
            messagesList
            Divider()
            errorBar
            invariantConflictBar
            stateChangeErrorBar
            clarificationBar
            truncationBar
            pipelineModeBar
            inputBar
        }
        .frame(minWidth: 480, minHeight: 600)
        .navigationTitle(vm.selectedChat?.title ?? "Чат")
        .navigationSubtitle(attachedProject.map { "Проект: \($0.title)" } ?? "")
        .toolbar {
            ToolbarItem(placement: .status) {
                if let chat = vm.selectedChat, chat.totalTokens > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.hexagongrid")
                        Text("\(chat.totalTokens.formatted()) токенов")
                        if chat.totalCost > 0 {
                            Text("· \(MessageBubble.formatCost(chat.totalCost))")
                        }
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .help("Стоимость чата \(MessageBubble.formatCost(chat.totalCost)) (включая саммаризацию).\nТокены — запрос: \(chat.promptTokens.formatted()) · ответ: \(chat.completionTokens.formatted()) · всего: \(chat.totalTokens.formatted())")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if factsActive {
                    Button {
                        showingFacts = true
                    } label: {
                        Image(systemName: "key")
                    }
                    .help("Память фактов: показать и изменить")
                }
                if attachedProject != nil {
                    Button {
                        showingProjectPanel = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Проект: инструкции, секции, «Собрать»")
                }
                Button {
                    showingInvariants = true
                } label: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle((vm.selectedChat.map { vm.effectiveInvariants(for: $0).isEmpty } ?? true)
                                         ? Color.secondary : Color.accentColor)
                }
                .help("Инварианты: ограничения (стек/архитектура/бюджет/запреты/правила)")

                Button {
                    showingMemory = true
                } label: {
                    Image(systemName: "brain")
                        .foregroundStyle(vm.memorySuggestions.isEmpty ? Color.secondary : Color.accentColor)
                }
                .help(vm.memorySuggestions.isEmpty
                      ? "Память: профиль и заметки диалога"
                      : "Память: \(vm.memorySuggestions.count) подсказок ждут подтверждения")
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
        .sheet(isPresented: $showingFacts) {
            FactsEditorView(text: vm.selectedChat?.facts ?? "") { edited in
                if let id = vm.selectedChatID { vm.setFacts(chatID: id, edited) }
            }
        }
        .sheet(isPresented: $showingMemory) {
            MemoryPanelView(vm: vm)
        }
        .sheet(isPresented: $showingInvariants) {
            InvariantsPanelView(vm: vm)
        }
        .sheet(isPresented: $showingProjectPanel) {
            if let p = attachedProject {
                ProjectPanelView(vm: vm, projectID: p.id)
            }
        }
        .sheet(item: $memoryDraft) { draft in
            MemoryItemEditorView(item: draft.item, title: "Сохранить в память") { edited in
                vm.saveMemory(edited, chatID: vm.selectedChatID)
            }
        }
        .sheet(item: $projectDraft) { draft in
            ProjectEntryEditorView(entry: draft.entry, title: "Сохранить в проект") { edited in
                if let pid = draft.projectID {
                    vm.addEntry(projectID: pid, title: edited.title, body: edited.body,
                                kind: edited.kind, sourceChatID: vm.selectedChatID)
                }
            }
        }
    }

    /// Привязанный к выбранному чату проект (если есть).
    private var attachedProject: Project? {
        vm.selectedChat.flatMap { vm.project(for: $0) }
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
                    memorySuggestionBanner
                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            onBranch: branchingActive ? {
                                if let chatID = vm.selectedChatID {
                                    vm.makeBranchFrom(chatID: chatID, messageID: message.id)
                                }
                            } : nil,
                            onSaveToMemory: {
                                let kind: MemoryKind = message.role == .user ? .note : .knowledge
                                memoryDraft = MemoryDraft(item: MemoryItem(
                                    scope: kind.defaultScope,
                                    kind: kind,
                                    text: message.content,
                                    sourceChatID: vm.selectedChatID
                                ))
                            },
                            onSaveToProject: attachedProject.map { project in
                                {
                                    projectDraft = ProjectEntryDraft(
                                        entry: ProjectEntry(
                                            title: ProjectEntry.deriveTitle(from: message.content),
                                            body: message.content,
                                            kind: message.role == .user ? .note : .knowledge,
                                            sourceChatID: vm.selectedChatID),
                                        projectID: project.id, isNew: true)
                                }
                            }
                        )
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
        Group {
            if let chat = vm.selectedChat {
                let strat = chat.settings.contextStrategy
                let overhead = chat.summaryTokens > 0
                    ? "на стратегию ушло \(chat.summaryTokens.formatted()) ток." +
                      (chat.summaryCost > 0 ? " · \(MessageBubble.formatCost(chat.summaryCost))" : "")
                    : ""

                if chat.isUpdatingFacts {
                    bannerLine("Обновляю блок фактов…", system: nil, busy: true, sub: "", help: "")
                } else if strat == .stickyFacts, !chat.facts.isEmpty {
                    bannerLine("Память фактов активна — кнопка 🔑 в шапке, чтобы посмотреть/изменить",
                               system: "key", busy: false, sub: overhead, help: chat.facts)
                } else if strat == .slidingWindow, chat.messages.count > chat.settings.historyWindow {
                    bannerLine("Скользящее окно: модель видит только последние \(chat.settings.historyWindow) сообщ.",
                               system: "rectangle.lefthalf.inset.filled", busy: false, sub: "", help: "")
                }
            }
        }
    }

    /// Плашка: ассистент памяти предложил записи — открыть панель для подтверждения.
    @ViewBuilder
    private var memorySuggestionBanner: some View {
        if !vm.memorySuggestions.isEmpty {
            Button {
                showingMemory = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                    Text("Ассистент памяти предлагает \(vm.memorySuggestions.count) запис(и) — нажми, чтобы посмотреть и подтвердить")
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func bannerLine(_ text: String, system: String?, busy: Bool, sub: String, help: String) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                if let system { Image(systemName: system) }
                Text(text)
            }
            if !sub.isEmpty {
                Text(sub).font(.caption2)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .help(help)
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
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .foregroundColor(.primary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Баннер конфликта инвариантов

    /// Запрос пользователя нарушает инвариант — агент отказал и предложил альтернативу.
    @ViewBuilder
    private var invariantConflictBar: some View {
        if let chat = vm.selectedChat, let conflict = chat.invariantConflict {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Конфликт с инвариантом — решение, нарушающее ограничение, не предложено.")
                        .fontWeight(.medium)
                    Text(conflict).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    if let id = vm.selectedChatID { vm.clearInvariantConflict(chatID: id) }
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary.opacity(0.6))
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Баннер отказа в смене стадии (запрошенный переход запрещён таблицей)

    @ViewBuilder
    private var stateChangeErrorBar: some View {
        if let chat = vm.selectedChat, let err = chat.stateChangeError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundColor(.orange)
                Text(err)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    if let id = vm.selectedChatID { vm.clearStateChangeError(chatID: id) }
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary.opacity(0.6))
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    // MARK: - Уточняющий вопрос агента (с вариантами ответа, как AskUserQuestion)

    @ViewBuilder
    private var clarificationBar: some View {
        if let chat = vm.selectedChat, let run = chat.taskContext,
           run.status == .awaitingInput, let pq = run.pendingQuestion {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill")
                        .foregroundColor(.accentColor)
                    Text(pq.question)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(pq.options.enumerated()), id: \.offset) { _, opt in
                        Button {
                            vm.answerClarification(chatID: chat.id, answer: opt)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "circle")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                                Text(opt)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("Выбери вариант или ответь своим текстом в поле ниже.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10))
        }
    }

    // MARK: - Ветвление: панель веток над лентой

    @ViewBuilder
    private var branchBar: some View {
        if let chat = vm.selectedChat,
           chat.settings.contextStrategy == .branching,
           !chat.branchLeaves.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.secondary)
                ForEach(chat.branchLeaves) { b in
                    let active = b.id == chat.activeLeafID
                    HStack(spacing: 2) {
                        Button(b.name) {
                            vm.switchBranch(chatID: chat.id, branchID: b.id)
                        }
                        .buttonStyle(.borderless)
                        .fontWeight(active ? .semibold : .regular)
                        .foregroundColor(active ? .accentColor : .secondary)
                        if !active {
                            Button {
                                vm.mergeBranch(chatID: chat.id, sourceBranchID: b.id)
                            } label: {
                                Image(systemName: "arrow.triangle.merge")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary.opacity(0.6))
                            .help("Влить ветку «\(b.name)» в активную")
                        }
                        Button {
                            vm.deleteBranch(chatID: chat.id, branchID: b.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary.opacity(0.5))
                        .help("Удалить ветку «\(b.name)»")
                    }
                    .padding(.trailing, 4)
                }
                Spacer()
                Text("ветка отсюда — наведи на сообщение")
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.06))
        }
    }

    // MARK: - Полоса состояния конечного автомата задачи (FSM)

    /// Над лентой: этапы (план → выполнение → проверка → ответ) с подсветкой
    /// текущего + кнопки управления (пауза/продолжить/принять план/…).
    @ViewBuilder
    private var pipelineBar: some View {
        if let chat = vm.selectedChat, let run = chat.taskContext {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "list.number")
                        .foregroundColor(.secondary)
                    ForEach(Array(TaskState.allCases.enumerated()), id: \.element) { idx, st in
                        stateChip(st, run: run)
                        if idx < TaskState.allCases.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.4))
                        }
                    }
                    // Прогресс шагов внутри Выполнения.
                    if run.state == .execution, run.total > 0 {
                        Text("шаг \(min(run.step + 1, run.total))/\(run.total)")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .help("Текущий шаг плана")
                    }
                    // Рой: индикатор параллельной волны (несколько подагентов разом).
                    if run.state == .execution, chat.settings.swarmEnabled,
                       run.waveIndex < run.waves.count, run.waves[run.waveIndex].count > 1 {
                        Text("рой ×\(run.waves[run.waveIndex].count)")
                            .font(.caption2)
                            .foregroundColor(.purple)
                            .help("Параллельно работают \(run.waves[run.waveIndex].count) подагентов (волна \(run.waveIndex + 1)/\(run.waves.count))")
                    }
                    if run.executionRetries > 0 {
                        Text("↻\(run.executionRetries)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("Возвратов «Проверка → Выполнение»: \(run.executionRetries)")
                    }
                    if run.planRetries > 0 {
                        Text("⤺\(run.planRetries)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("Возвратов «Выполнение → Планирование»: \(run.planRetries)")
                    }
                    if run.invariantRetries > 0 {
                        Text("⚠\(run.invariantRetries)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("Перегенераций из-за нарушения инвариантов: \(run.invariantRetries)")
                    }
                    Spacer()
                    pipelineControls(chat: chat, run: run)
                }
                if run.status == .failed, let err = run.errorText {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.06))
        }
    }

    private enum PhaseChipState { case done, current, upcoming }

    private func stateChipState(_ s: TaskState, run: TaskContext) -> PhaseChipState {
        let order = TaskState.allCases
        guard let pi = order.firstIndex(of: s),
              let ci = order.firstIndex(of: run.state) else { return .upcoming }
        // Финиш: обычный — state=.answer (всё done); обрыв по конфликту инварианта —
        // done ТОЛЬКО до места обрыва (видно, что дальше по шагам не пошли).
        if run.status == .finished { return pi <= ci ? .done : .upcoming }
        if pi < ci { return .done }
        if pi == ci { return .current }
        return .upcoming
    }

    @ViewBuilder
    private func stateChip(_ s: TaskState, run: TaskContext) -> some View {
        let cs = stateChipState(s, run: run)
        HStack(spacing: 3) {
            if cs == .done {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if cs == .current, run.status == .running {
                ProgressView().controlSize(.mini)
            }
            Text(s.label)
                .fontWeight(cs == .current ? .semibold : .regular)
                .foregroundColor(cs == .current ? .accentColor
                                 : (cs == .done ? .primary : .secondary))
        }
    }

    @ViewBuilder
    private func pipelineControls(chat: Chat, run: TaskContext) -> some View {
        HStack(spacing: 10) {
            switch run.status {
            case .running:
                Button { vm.pausePipeline(chatID: chat.id) } label: {
                    Label("Пауза", systemImage: "pause.fill")
                }
                .buttonStyle(.borderless)
            case .awaitingPlan:
                Button { vm.approvePlan(chatID: chat.id) } label: {
                    Label("Принять план", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                Button { vm.replan(chatID: chat.id) } label: {
                    Label("Заново", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Перепланировать заново")
            case .awaitingInput:
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.circle.fill").foregroundColor(.accentColor)
                    Text("Ждёт ответа").foregroundColor(.accentColor)
                }
                .help("Агент задал вопрос — выбери вариант ниже или ответь в поле ввода")
            case .paused:
                Button { vm.resumePipeline(chatID: chat.id) } label: {
                    Label("Продолжить", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            case .failed:
                Button { vm.resumePipeline(chatID: chat.id) } label: {
                    Label("Повторить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.orange)
            case .finished:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Готово").foregroundColor(.green)
                }
            }
            // Ручной шаг назад «Выполнение → Планирование» (легальный переход по таблице).
            if run.state == .execution, run.status == .running || run.status == .paused,
               run.planRetries < TaskContext.maxPlanRetries {
                Button { vm.requestReplan(chatID: chat.id) } label: {
                    Label("Перепланировать", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Шаг назад: вернуться к планированию")
            }
            // Меню «→ этап»: запросить смену стадии. Легальные по таблице переходы —
            // активны, нелегальные — серые (то же можно текстом: «вернись к проверке»).
            if run.status != .finished {
                Menu {
                    ForEach(TaskState.allCases.filter { $0 != run.state }) { st in
                        Button {
                            vm.requestStateChange(chatID: chat.id, to: st)
                        } label: {
                            Text(TaskFSM.allows(run.state, to: st)
                                 ? "В «\(st.label)»" : "В «\(st.label)» — недоступно")
                        }
                        .disabled(!TaskFSM.allows(run.state, to: st))
                    }
                } label: {
                    Label("этап", systemImage: "arrow.triangle.swap")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Сменить стадию, если это разрешено таблицей переходов")
            }
            Button { vm.cancelRun(chatID: chat.id) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary.opacity(0.5))
            .help("Сбросить задачу (история в ленте останется)")
        }
    }

    // MARK: - Предупреждение об усечении контекста

    /// Жёлтый бар: история чата рискует не влезть в окно выбранной модели —
    /// провайдер (например, OpenRouter middle-out) молча вырежет середину.
    @ViewBuilder
    private var truncationBar: some View {
        if let chat = vm.selectedChat, let warning = vm.truncationWarning(for: chat) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "scissors")
                    .foregroundColor(.yellow)
                Text(warning)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.12))
        }
    }

    // MARK: - Быстрый переключатель режима задачи (FSM) — над полем ввода

    /// Сегмент Обычный | Авто | План прямо над полем ввода, чтобы режим можно было
    /// переключать в один клик, не заходя в настройки чата.
    private var pipelineModeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.number")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Режим задачи")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Режим задачи", selection: settingsBinding.pipelineMode) {
                ForEach(PipelineMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Обычный — обычный чат без конвейера. Авто — этапы план → выполнение → проверка → ответ подряд. План — стоп после планирования (нужно «Принять план»).")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Поле ввода

    /// Плейсхолдер поля ввода: при активном прогоне FSM подсказывает, что сообщение —
    /// уточнение/ответ/смена стадии, а не новый запуск.
    private var inputPlaceholder: String {
        guard let run = vm.selectedChat?.taskContext, run.status != .finished else { return "Сообщение…" }
        switch run.status {
        case .awaitingInput: return "Ответь на вопрос или выбери вариант выше…"
        case .awaitingPlan:  return "Правки к плану…"
        default:             return "Уточнение к текущему этапу (или «вернись к проверке»)…"
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Поле в ScrollView: TextField растёт без ограничения, контейнер
            // ограничивает высоту до inputMaxHeight и даёт скролл колесом мыши.
            // (TextField с lineLimit обрезал, но колёсиком не скроллился — только
            // переходом курсора по тексту.)
            ScrollView(.vertical) {
                TextField(inputPlaceholder, text: $vm.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: InputHeightKey.self, value: geo.size.height)
                        }
                    )
                    .onSubmit(vm.send)
            }
            .frame(height: min(max(Self.inputMinHeight, inputContentHeight), Self.inputMaxHeight))
            // Пока текст влезает — скролл выключен (нет лишнего «отскока»).
            .scrollDisabled(inputContentHeight <= Self.inputMaxHeight)
            .onPreferenceChange(InputHeightKey.self) { inputContentHeight = $0 }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )

            // Круглая кнопка отправки — единый размер, акцентный цвет, гасится когда нечего слать.
            Button(action: vm.send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(vm.canSend ? Color.accentColor : Color.secondary.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!vm.canSend)
            .help("Отправить сообщение")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Высота содержимого поля ввода (для авто-роста до предела и скролла дальше).
private struct InputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Лист настроек параметров генерации для текущего чата.
struct ChatSettingsView: View {
    @ObservedObject var vm: ChatViewModel
    @Binding var settings: GenerationSettings
    /// В режиме сравнения модель выбирается в шапке колонки — секцию прячем.
    var showModelSection: Bool = true
    /// Ветвление — структурная стратегия, в сравнении недоступна.
    var allowBranching: Bool = true
    /// Память кратко-/рабочая — на чат; в сравнении прячем (там только глобальная).
    var showMemorySection: Bool = true
    /// Профиль ответа — на чат; в сравнении прячем.
    var showProfileSection: Bool = true
    @Environment(\.dismiss) private var dismiss

    /// Стоп-последовательности редактируем как строку «через запятую».
    @State private var stopText: String = ""
    @State private var showingModelPicker = false
    /// Открытый редактор профиля (создание/правка).
    @State private var editingProfile: ResponseProfile?

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
                if showModelSection {
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
                }

                if showProfileSection {
                Section("Профиль ответа") {
                    Picker("Профиль", selection: profileBinding) {
                        Text("Без профиля").tag(UUID?.none)
                        ForEach(vm.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    HStack(spacing: 12) {
                        Button { editingProfile = ResponseProfile() } label: {
                            Label("Новый", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        if let p = currentProfile {
                            Button { editingProfile = p } label: { Label("Редактировать", systemImage: "pencil") }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) { vm.deleteProfile(id: p.id) } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("Пресет стиля/формата/ограничений ответа. Переключается на каждый чат; на токены/температуру не влияет (это отдельные параметры).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                }

                Section("Формат ответа") {
                    TextEditor(text: $settings.responseFormat)
                        .frame(minHeight: 56)
                        .font(.body)
                    Text("Разовая правка формата поверх профиля. Напр.: «верни строго JSON». Пусто — без доп. требований.")
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

                Section("Управление контекстом") {
                    Picker("Стратегия", selection: $settings.contextStrategy) {
                        ForEach(allowBranching ? ContextStrategy.allCases : ContextStrategy.sendStrategies) { strat in
                            Text(strat.label).tag(strat)
                        }
                    }
                    if settings.contextStrategy.usesWindow {
                        Stepper(
                            value: $settings.historyWindow,
                            in: GenerationSettings.historyWindowRange,
                            step: 2
                        ) {
                            HStack {
                                Text("Окно N — последние")
                                Spacer()
                                Text("\(settings.historyWindow) сообщ.")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    Text(settings.contextStrategy.hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Режим задачи (FSM)") {
                    Picker("Режим", selection: $settings.pipelineMode) {
                        ForEach(PipelineMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Text("Обычный — обычный чат без конвейера. Авто — задача проходит этапы план → выполнение → проверка → ответ автоматически (каждый этап — отдельный запрос; последний этап «Ответ» — это сам ответ на задачу). План — после планирования останавливается на «Принять план», как в Claude Code. Проверка при «не выполнено» возвращает к выполнению (до \(TaskContext.maxExecutionRetries) раз). Паузу/продолжение можно жать в любой момент. На паузе можно дослать уточнение (агент доработает текущий этап) или попросить сменить стадию («→ этап» / текстом).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Рой агентов (параллельное выполнение)") {
                    Toggle("Распараллеливать независимые шаги", isOn: $settings.swarmEnabled)
                    if settings.swarmEnabled {
                        Stepper(value: $settings.maxParallelAgents,
                                in: GenerationSettings.maxParallelAgentsRange) {
                            HStack {
                                Text("Макс. подагентов в волне")
                                Spacer()
                                Text("\(settings.maxParallelAgents)")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    Text("На этапе «Выполнение» независимые шаги плана выполняются параллельно подагентами со своим узким контекстом (только их зависимости) — быстрее и экономнее по токенам. Зависимые шаги идут по порядку (планировщик указывает зависимости, шаги раскладываются по волнам). Выкл — последовательное выполнение с полным контекстом, как раньше.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Инварианты — проверка ответа") {
                    Picker("Метод валидации", selection: $settings.invariantValidation) {
                        ForEach(InvariantValidationMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Text("Сами ограничения — кнопка «щит» в шапке (стек/архитектура/бюджет/запреты/правила). Выкл — инварианты только в промпте. Код — проверка по вхождению запрещённых слов + маркер модели. LLM — доп. запрос-проверяющий. Оба — и то, и другое. Валидируется каждый ответ; при нарушении модели — перегенерация (до \(TaskContext.maxInvariantRetries) раз).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if showMemorySection {
                Section("Память") {
                    Toggle("Долговременная память (глобально, во всех чатах)", isOn: $settings.injectLongTermMemory)
                    Toggle("Память этого чата (проект + краткосрочная)", isOn: $settings.injectChatMemory)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Бюджет памяти")
                            Spacer()
                            Text("\(settings.memoryTokenBudget) ток.")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.memoryTokenBudget) },
                                set: { settings.memoryTokenBudget = Int($0) }
                            ),
                            in: Double(GenerationSettings.memoryTokenBudgetRange.lowerBound)...Double(GenerationSettings.memoryTokenBudgetRange.upperBound),
                            step: 100
                        )
                        Text("Сколько токенов максимум занимает блок памяти в промпте. Закреплённые записи включаются всегда.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Ассистент памяти (разбирать диалог фоном)", isOn: $settings.memoryAssistEnabled)
                    if settings.memoryAssistEnabled {
                        Toggle("Автозапись: ИИ сам пишет важное в память", isOn: $settings.autoMemory)
                        Text(settings.autoMemory
                             ? "Вкл: ассистент сам сохраняет, что счёл важным."
                             : "Выкл: ассистент ПРЕДЛАГАЕТ записи — ты подтверждаешь (кнопка «Память» в шапке).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Выкл: фоновых вызовов нет. Память пополняется только вручную (кнопки «В память» / «В проект» на сообщении или панель «Память»).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Автосекции в проект: полные ответы агента → секции", isOn: $settings.autoProjectSections)
                    Text(settings.autoProjectSections
                         ? "Вкл: содержательный ответ целиком добавляется секцией в привязанный проект (нужен проект)."
                         : "Выкл: ответы попадают в проект только вручную кнопкой «В проект».")
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
        .frame(width: 480, height: 560)
        .onAppear {
            stopText = Self.formatStop(settings.stop)
            vm.loadModels()
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerView(
                models: vm.availableModels,
                current: ModelOption(provider: settings.provider, model: settings.model),
                onSelect: { settings.provider = $0.provider; settings.model = $0.model }
            )
        }
        .sheet(item: $editingProfile) { p in
            ProfileEditorView(profile: p) { edited in
                if vm.profiles.contains(where: { $0.id == edited.id }) {
                    vm.updateProfile(edited)
                } else {
                    // Новый профиль — добавляем и сразу делаем активным для чата.
                    vm.profiles.insert(edited, at: 0)
                    if let cid = vm.selectedChatID { vm.setChatProfile(chatID: cid, profileID: edited.id) }
                }
            }
        }
    }

    /// Активный профиль выбранного чата (для секции «Профиль ответа»).
    private var currentProfile: ResponseProfile? {
        vm.selectedChat.flatMap { vm.profile(for: $0) }
    }

    /// Привязка профиля к выбранному чату.
    private var profileBinding: Binding<UUID?> {
        Binding(
            get: { vm.selectedChat?.profileID },
            set: { newID in if let cid = vm.selectedChatID { vm.setChatProfile(chatID: cid, profileID: newID) } }
        )
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

/// Редактор «Профиля ответа»: название + стиль/тон, формат, длина-и-ограничения,
/// язык, доп. инструкции (все поля свободные; токены/температуру не задаёт).
struct ProfileEditorView: View {
    @State var profile: ResponseProfile
    let onSave: (ResponseProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isEmptyName: Bool {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Профиль ответа").font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") { onSave(profile); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmptyName)
            }
            .padding()

            Divider()

            Form {
                Section("Название") {
                    TextField("", text: $profile.name, prompt: Text("название профиля"))
                }
                field("Стиль и тон", $profile.style, "напр.: дружелюбный и неформальный; строгий технический")
                field("Формат ответа", $profile.format, "напр.: маркированные пункты; таблица; строго JSON")
                field("Длина и ограничения", $profile.constraints, "напр.: коротко, до 3 пунктов; без жаргона; не давай советов")
                Section("Язык ответа") {
                    TextField("", text: $profile.language, prompt: Text("напр.: русский; как спрашивают"))
                }
                field("Доп. инструкции", $profile.extra, "любые дополнительные правила для ответов этого профиля")
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 660)
    }

    @ViewBuilder
    private func field(_ title: String, _ text: Binding<String>, _ hint: String) -> some View {
        Section(title) {
            TextEditor(text: text).frame(minHeight: 48).font(.body)
            Text(hint).font(.caption).foregroundColor(.secondary)
        }
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
    let current: ModelOption?
    let onSelect: (ModelOption) -> Void
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
                                        onSelect(opt)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(opt.model)
                                                .lineLimit(1)
                                            Spacer()
                                            if opt == current {
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

/// Просмотр и редактирование блока «факты» (стратегия Sticky Facts).
struct FactsEditorView: View {
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Память фактов")
                    .font(.headline)
                Spacer()
                Button("Очистить") { text = "" }
                Button("Сохранить") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if text.isEmpty {
                Text("Пока фактов нет — они появятся после первых сообщений в режиме «Факты + окно».")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(8)

            Divider()

            Label("Факты обновляются автоматически после каждого обмена. Твои правки сохранятся, но следующее автообновление может их переписать.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Память (UI)

/// Обёртка записи памяти для .sheet(item:) (черновик/редактирование).
struct MemoryDraft: Identifiable {
    let id = UUID()
    var item: MemoryItem
}

/// Редактор одной записи памяти: уровень, тип, текст, теги, закрепление.
struct MemoryItemEditorView: View {
    @State var item: MemoryItem
    var title: String = "Запись памяти"
    let onSave: (MemoryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tagsText = ""

    private var isEmpty: Bool {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    item.tags = tagsText.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEmpty)
            }
            .padding()

            Divider()

            Form {
                Section {
                    // Рабочая память живёт в проекте (секции) — здесь только
                    // долговременная и краткосрочная.
                    Picker("Уровень памяти", selection: $item.scope) {
                        ForEach([MemoryScope.longTerm, .shortTerm]) { s in Text(s.label).tag(s) }
                    }
                    Text(item.scope.hint).font(.caption).foregroundColor(.secondary)
                    Picker("Тип", selection: $item.kind) {
                        ForEach(MemoryKind.allCases) { k in Text(k.label).tag(k) }
                    }
                }
                Section("Текст") {
                    TextEditor(text: $item.text)
                        .frame(minHeight: 100)
                        .font(.body)
                }
                Section {
                    TextField("", text: $tagsText, prompt: Text("теги через запятую (необязательно)"))
                    Toggle("Закрепить (всегда подставлять в промпт)", isOn: $item.pinned)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 470, height: 480)
        .onAppear { tagsText = item.tags.joined(separator: ", ") }
    }
}

/// Обёртка секции проекта для .sheet(item:) (черновик/редактирование).
struct ProjectEntryDraft: Identifiable {
    let id = UUID()
    var entry: ProjectEntry
    var projectID: UUID?
    var isNew: Bool
}

/// Панель ПРОФИЛЯ (кнопка «мозг» в чате): долговременная + краткосрочная память +
/// подсказки ассистента. Рабочая память (проект) — отдельно, во вкладке «Проекты».
struct MemoryPanelView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editTarget: MemoryDraft?

    private var chat: Chat? { vm.selectedChat }
    private var chatID: UUID? { vm.selectedChatID }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Память").font(.headline)
                Spacer()
                if chat?.messages.isEmpty == false {
                    Button {
                        if let cid = chatID { vm.requestMemorySuggestions(chatID: cid) }
                    } label: {
                        Label("Предложить в профиль", systemImage: "sparkles")
                    }
                    .help("ИИ разберёт диалог и предложит записи в долговременный профиль")
                }
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                suggestionsSection
                scopeSection(title: "Долговременная — профиль (во всех чатах)",
                             icon: "brain", items: vm.memory, addScope: .longTerm, addKind: .knowledge)
                scopeSection(title: "Краткосрочная — текущий диалог",
                             icon: "bubble.left", items: chat?.memory ?? [], addScope: .shortTerm, addKind: .note)
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 600)
        .sheet(item: $editTarget) { draft in
            MemoryItemEditorView(item: draft.item) { edited in
                if vm.memorySuggestions.contains(where: { $0.id == edited.id }) {
                    vm.confirmSuggestion(edited, chatID: chatID)
                } else {
                    vm.updateMemory(edited, chatID: chatID)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if !vm.memorySuggestions.isEmpty {
            Section {
                ForEach(vm.memorySuggestions) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.text).font(.callout)
                        HStack(spacing: 10) {
                            Text("\(s.scope.label) · \(s.kind.label)")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Button("Править") { editTarget = MemoryDraft(item: s) }
                                .buttonStyle(.borderless)
                            Button("В память") { vm.confirmSuggestion(s, chatID: chatID) }
                                .buttonStyle(.borderless)
                            Button("Скрыть") { vm.dismissSuggestion(id: s.id) }
                                .buttonStyle(.borderless)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Скрыть все подсказки") { vm.clearSuggestions() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
            } header: {
                Label("Подсказки ассистента памяти", systemImage: "sparkles")
            }
        }
    }

    @ViewBuilder
    private func scopeSection(title: String, icon: String, items: [MemoryItem],
                              addScope: MemoryScope, addKind: MemoryKind) -> some View {
        Section {
            if items.isEmpty {
                Text("Пусто").font(.caption).foregroundColor(.secondary)
            }
            ForEach(items) { item in itemRow(item) }
            Button {
                editTarget = MemoryDraft(item: MemoryItem(scope: addScope, kind: addKind, sourceChatID: chatID))
            } label: {
                Label("Добавить запись", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Label(title, systemImage: icon)
        }
    }

    private func itemRow(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { vm.togglePin(id: item.id, chatID: chatID) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .foregroundColor(item.pinned ? .accentColor : .secondary)
            .help(item.pinned ? "Открепить" : "Закрепить (всегда в промпте)")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.callout).lineLimit(3)
                HStack(spacing: 6) {
                    Text(item.kind.label)
                    if !item.tags.isEmpty { Text("#" + item.tags.joined(separator: " #")) }
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button { editTarget = MemoryDraft(item: item) } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) { vm.deleteMemory(id: item.id, chatID: chatID) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
    }
}

/// Панель ПРОЕКТА (вкладка «Проекты»): инструкции + полнотекстовые секции +
/// «Собрать». Память проекта общая для всех его диалогов (cowork).
struct ProjectPanelView: View {
    @ObservedObject var vm: ChatViewModel
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var entryTarget: ProjectEntryDraft?

    private var project: Project? { vm.projects.first { $0.id == projectID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(project?.title ?? "Проект").font(.headline)
                Spacer()
                if let p = project {
                    Button { vm.assembleProject(projectID: p.id) } label: {
                        Label("Собрать", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(p.entries.isEmpty || vm.isAssembling)
                    .help("Сшить полные секции проекта в итоговый документ")
                    if vm.isAssembling { ProgressView().controlSize(.small) }
                }
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("Название проекта") {
                    TextField("", text: titleBinding, prompt: Text("название"))
                }
                Section {
                    TextEditor(text: instructionsBinding).frame(minHeight: 60).font(.body)
                } header: {
                    Label("Инструкции проекта", systemImage: "text.alignleft")
                } footer: {
                    Text("Учитываются в каждом ответе диалогов этого проекта. Можно оставить пустым.")
                        .font(.caption)
                }
                if let p = project { sectionsSection(p) }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 700)
        .sheet(item: $entryTarget) { draft in
            ProjectEntryEditorView(entry: draft.entry) { edited in
                if draft.isNew {
                    vm.addEntry(projectID: projectID, title: edited.title, body: edited.body, kind: edited.kind)
                } else {
                    vm.updateEntry(edited, projectID: projectID)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { vm.assemblyResult != nil },
            set: { if !$0 { vm.assemblyResult = nil } }
        )) {
            AssemblyResultView(text: vm.assemblyResult ?? "") { result in
                vm.addEntry(projectID: projectID, title: "Итог проекта", body: result, kind: .knowledge)
            }
        }
    }

    @ViewBuilder
    private func sectionsSection(_ p: Project) -> some View {
        Section {
            if p.entries.isEmpty {
                Text("Секций пока нет. Они появятся, когда агент будет вести проект (автосекции) или по кнопке «В проект» на сообщении.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(p.entries) { entry in entryRow(entry) }
            Button {
                entryTarget = ProjectEntryDraft(entry: ProjectEntry(kind: .knowledge), projectID: projectID, isNew: true)
            } label: {
                Label("Добавить секцию", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Label("Секции проекта", systemImage: "doc.plaintext")
        }
    }

    private func entryRow(_ entry: ProjectEntry) -> some View {
        DisclosureGroup {
            Text(MarkdownText.attributed(entry.body))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            HStack(spacing: 12) {
                Button { entryTarget = ProjectEntryDraft(entry: entry, projectID: projectID, isNew: false) } label: {
                    Label("Править", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) { vm.deleteEntry(id: entry.id, projectID: projectID) } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                Spacer()
            }
            .font(.caption2)
        } label: {
            HStack(spacing: 8) {
                Button { vm.toggleEntryPin(id: entry.id, projectID: projectID) } label: {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .foregroundColor(entry.pinned ? .accentColor : .secondary)
                Text(entry.title.isEmpty ? "(без названия)" : entry.title)
                    .font(.callout).lineLimit(1)
            }
        }
    }

    private var titleBinding: Binding<String> {
        Binding(get: { project?.title ?? "" }, set: { vm.updateProject(id: projectID, title: $0) })
    }
    private var instructionsBinding: Binding<String> {
        Binding(get: { project?.brief ?? "" }, set: { vm.updateProject(id: projectID, brief: $0) })
    }
}

/// Редактор секции проекта: заголовок + тип + закрепление + ПОЛНЫЙ текст.
struct ProjectEntryEditorView: View {
    @State var entry: ProjectEntry
    var title: String = "Секция проекта"
    let onSave: (ProjectEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isEmpty: Bool { entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    if entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        entry.title = ProjectEntry.deriveTitle(from: entry.body)
                    }
                    onSave(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEmpty)
            }
            .padding()

            Divider()

            Form {
                Section("Заголовок секции") {
                    TextField("", text: $entry.title, prompt: Text("название секции"))
                    Picker("Тип", selection: $entry.kind) {
                        ForEach(MemoryKind.allCases) { k in Text(k.label).tag(k) }
                    }
                    Toggle("Закрепить (всегда подставлять в промпт)", isOn: $entry.pinned)
                }
                Section("Текст секции (полный)") {
                    TextEditor(text: $entry.body)
                        .frame(minHeight: 200)
                        .font(.body)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 580)
    }
}

// MARK: - Инварианты (ограничения) — панель и редактор

struct InvariantsPanelView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editTarget: Invariant?

    private var chat: Chat? { vm.selectedChat }
    private var hasProject: Bool { chat?.projectID != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Инварианты").font(.headline)
                Spacer()
                Menu {
                    ForEach(Invariant.templates()) { t in
                        Button("\(t.kind.title): \(t.name)") {
                            var inv = t
                            inv.id = UUID(); inv.scope = .global; inv.ownerID = nil
                            editTarget = inv
                        }
                    }
                } label: { Label("Шаблон", systemImage: "square.grid.2x2") }
                Button { editTarget = Invariant() } label: { Label("Новый", systemImage: "plus") }
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Form {
                scopeSection("Глобальные — во всех чатах", scope: .global)
                if hasProject { scopeSection("Проект — во всех чатах проекта", scope: .project) }
                scopeSection("Этот чат", scope: .chat)
                Section {
                    Text("Инварианты обязательны: агент учитывает их в рассуждениях и отказывается предлагать нарушающие решения. Метод проверки ответа — в ⚙ настройках чата (Выкл/Код/LLM/Оба). Хранятся отдельно от диалога (invariants.json).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 600)
        .sheet(item: $editTarget) { inv in
            InvariantEditorView(invariant: inv, hasProject: hasProject) { edited in
                var e = edited
                e.ownerID = ownerID(for: e.scope)
                if vm.invariants.contains(where: { $0.id == e.id }) { vm.updateInvariant(e) }
                else { vm.addInvariant(e) }
            }
        }
    }

    @ViewBuilder
    private func scopeSection(_ title: String, scope: InvariantScope) -> some View {
        let items = vm.invariants.filter { $0.scope == scope && ownerMatches($0, scope) }
        Section(title) {
            if items.isEmpty {
                Text("—").foregroundColor(.secondary).font(.caption)
            }
            ForEach(items) { inv in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: inv.enabled ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(inv.enabled ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inv.name.isEmpty ? inv.kind.title : inv.name).fontWeight(.medium)
                        Text(inv.description).font(.caption).foregroundColor(.secondary).lineLimit(3)
                        Text("\(inv.kind.title) · защита: \(inv.enforcement.label)")
                            .font(.caption2).foregroundColor(.secondary.opacity(0.8))
                    }
                    Spacer()
                    Button("Править") { editTarget = inv }.buttonStyle(.borderless)
                    Button { vm.removeInvariant(id: inv.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func ownerMatches(_ inv: Invariant, _ scope: InvariantScope) -> Bool {
        switch scope {
        case .global: return true
        case .project: return inv.ownerID == chat?.projectID
        case .chat: return inv.ownerID == chat?.id
        }
    }
    private func ownerID(for scope: InvariantScope) -> UUID? {
        switch scope {
        case .global: return nil
        case .project: return chat?.projectID
        case .chat: return chat?.id
        }
    }
}

struct InvariantEditorView: View {
    @State var invariant: Invariant
    var hasProject: Bool = false
    let onSave: (Invariant) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var allowedStr = ""
    @State private var bannedStr = ""

    private var needsBanned: Bool { [.stack, .noBanned, .custom].contains(invariant.kind) }
    private var needsNote: Bool { [.arch, .budget, .techDecision, .businessRule, .custom].contains(invariant.kind) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Инвариант").font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    invariant.allowed = parseList(allowedStr)
                    invariant.banned = parseList(bannedStr)
                    onSave(invariant); dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Form {
                Section("Тип и область") {
                    Picker("Тип", selection: $invariant.kind) {
                        ForEach(InvariantKind.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Область", selection: $invariant.scope) {
                        ForEach(InvariantScope.allCases) { sc in
                            if sc != .project || hasProject { Text(sc.label).tag(sc) }
                        }
                    }
                    Picker("Защита", selection: $invariant.enforcement) {
                        ForEach(InvariantEnforcement.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Включён", isOn: $invariant.enabled)
                }
                Section("Параметры") {
                    TextField("Название", text: $invariant.name, prompt: Text("StackOnly / NoRxJava / Auth=JWT"))
                    if invariant.kind == .stack {
                        TextField("Разрешено (через запятую)", text: $allowedStr, prompt: Text("Kotlin, Ktor"))
                    }
                    if needsBanned {
                        TextField("Запрещённые слова — код-проверка (через запятую)", text: $bannedStr,
                                  prompt: Text("Spring Boot, Java, RxJava"))
                    }
                    if invariant.kind == .maxDeps {
                        Stepper(value: $invariant.maxDeps, in: 1...50) {
                            HStack { Text("Максимум зависимостей"); Spacer()
                                Text("\(invariant.maxDeps)").foregroundColor(.secondary).monospacedDigit() }
                        }
                    }
                    if needsNote {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Описание правила").font(.caption).foregroundColor(.secondary)
                            TextEditor(text: $invariant.note).frame(minHeight: 80).font(.body)
                        }
                    }
                }
                Section("Как увидит агент") {
                    Text(invariant.description).font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            allowedStr = invariant.allowed.joined(separator: ", ")
            bannedStr = invariant.banned.joined(separator: ", ")
        }
    }

    private func parseList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Лист создания проекта: только название + необязательные инструкции.
/// Никакого «ИИ предлагает бриф» — назвал и сразу пишешь.
struct ProjectCreateView: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var instructions = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Новый проект").font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Создать") { onCreate(title, instructions); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            Divider()

            Form {
                Section("Название") {
                    TextField("", text: $title, prompt: Text("название проекта"))
                }
                Section {
                    TextEditor(text: $instructions).frame(minHeight: 100).font(.body)
                } header: {
                    Label("Инструкции проекта (необязательно)", systemImage: "text.alignleft")
                } footer: {
                    Text("Твой промпт для задачи — агент учитывает его в каждом ответе проекта. Можно оставить пустым и просто начать писать.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 480)
    }
}

/// Лист с итогом «Собрать»: полный текст, копирование, сохранение секцией.
struct AssemblyResultView: View {
    let text: String
    let onSaveAsSection: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Итог проекта").font(.headline)
                Spacer()
                Button(copied ? "Скопировано" : "Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                Button("Сохранить как секцию") { onSaveAsSection(text); dismiss() }
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(MarkdownText.attributed(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 660, height: 660)
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

/// Содержимое пузыря (текст/Markdown + фон). Equatable и зависит ТОЛЬКО от
/// содержимого и роли — поэтому при перерисовке родителя (hover-кнопки, copied,
/// загрузка соседних сообщений) SwiftUI НЕ пересоздаёт Markdown и не сбрасывает
/// активное выделение текста. Выделение ответов агента раньше слетало именно
/// из-за пересборки этого поддерева на каждое изменение hovering.
private struct BubbleContent: View, Equatable {
    let content: String
    let isUser: Bool

    static func == (a: BubbleContent, b: BubbleContent) -> Bool {
        a.content == b.content && a.isUser == b.isUser
    }

    var body: some View {
        Group {
            if isUser {
                Text(content)
            } else {
                // Один Text из styled-AttributedString → выделение сплошное по
                // всему ответу (MarkdownUI рисует блоки порознь и так не умеет).
                Text(MarkdownText.attributed(content))
                    .tint(.accentColor)
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
}

/// «Пузырь» одного сообщения: user — справа (обычный текст), assistant — слева (Markdown).
/// При наведении показывается кнопка «Копировать».
struct MessageBubble: View {
    let message: ChatMessage
    /// Действие «создать ветку диалога с этого места» (если доступно).
    var onBranch: (() -> Void)? = nil
    /// Действие «сохранить это сообщение в память» (если доступно).
    var onSaveToMemory: (() -> Void)? = nil
    /// Действие «сохранить это сообщение секцией в проект» (если чат привязан к проекту).
    var onSaveToProject: (() -> Void)? = nil

    @State private var hovering = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    /// Текст метки этапа; для «Выполнения» добавляет номер шага.
    private func stateBadge(state: TaskState, step: Int?, total: Int?) -> String {
        if state == .execution, let step, let total, total > 0 {
            return "\(state.label) · шаг \(step + 1)/\(total)"
        }
        return state.label
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            if !isUser, let state = message.state {
                // Метка этапа FSM; для «Выполнения» — с номером шага.
                Text(stateBadge(state: state, step: message.step, total: message.total))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 40) }
                // .equatable() — чтобы смена hovering/copied (кнопки под пузырём)
                // НЕ пересоздавала Markdown: иначе при появлении кнопок выделение
                // текста сбрасывается. Пузырь зависит только от содержимого.
                BubbleContent(content: message.content, isUser: isUser)
                    .equatable()
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

    /// Кнопки под пузырём (появляются при наведении): копировать + ветка.
    private var copyControl: some View {
        HStack(spacing: 10) {
            Button(action: copy) {
                Label(copied ? "Скопировано" : "Копировать",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            if let onBranch {
                Button(action: onBranch) {
                    Label("Ветка отсюда", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .help("Создать новый чат-ветку с историей до этого сообщения")
            }
            if let onSaveToProject {
                Button(action: onSaveToProject) {
                    Label("В проект", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Сохранить этот ответ ПОЛНОСТЬЮ секцией в привязанный проект")
            }
            if let onSaveToMemory {
                Button(action: onSaveToMemory) {
                    Label("В память", systemImage: "brain")
                }
                .buttonStyle(.borderless)
                .help("Сохранить как короткую запись (профиль/заметка)")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
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
