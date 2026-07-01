// RagPanelView.swift — UI управления локальным RAG (по образцу MCPServersPanelView).
//
// Панель (иконка-лупа в шапке чата) — список индексов + создание/переиндексация/
// удаление + «тестовый поиск» (проверить ретрив без чата). Редактор (RagIndexEditorView)
// — выбор файла/папки через NSOpenPanel, стратегия чанкинга, бэкенд индекса, эмбеддер
// (Ollama/локальный/хеш) и запуск индексации с прогресс-баром и отменой.
//
// Включение ретрива в конкретном чате — в настройках чата (⚙, секция «RAG»), а не тут:
// панель заведует ИНДЕКСАМИ (глобально), настройки — тем, какой индекс использовать в чате.

import SwiftUI
import AppKit

// MARK: - Панель списка индексов

struct RagPanelView: View {
    @ObservedObject var ragVM: RagViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var creatingNew = false
    @State private var editing: RagIndexMeta?

    // Тестовый поиск (проверка ретрива прямо из панели).
    @State private var testIndexID: UUID?
    @State private var testQuery = ""
    @State private var testHits: [RagRetrievalHit] = []
    @State private var testing = false

    private var readyIndexes: [RagIndexMeta] { ragVM.indexes.filter { $0.isReady } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("База знаний (RAG)").font(.headline)
                Spacer()
                Button { creatingNew = true } label: { Label("Новый", systemImage: "plus") }
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Section("Индексы") {
                    if ragVM.indexes.isEmpty {
                        Text("Пока нет индексов. Нажми «Новый», выбери файл или папку и запусти индексацию — без этого RAG не соберётся.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(ragVM.indexes) { meta in row(meta) }
                }

                if let err = ragVM.errorText {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                    }
                }

                if !readyIndexes.isEmpty {
                    testSearchSection
                }

                Section {
                    Text("Пайплайн индексации: разбиение на чанки → генерация эмбеддингов → сохранение индекса (JSON / flat / SQLite). У каждого чанка — метаданные (источник, файл, раздел, chunkID). Эмбеддинги: Ollama (локальный сервер) или Apple NaturalLanguage (офлайн). Файлы индекса лежат вне репозитория, в Application Support.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 660, height: 640)
        .sheet(isPresented: $creatingNew) { RagIndexEditorView(ragVM: ragVM, existing: nil) }
        .sheet(item: $editing) { m in RagIndexEditorView(ragVM: ragVM, existing: m) }
    }

    // Строка индекса: статус + имя + сводка конфига + прогресс/кнопки.
    @ViewBuilder
    private func row(_ meta: RagIndexMeta) -> some View {
        let isThisIndexing = ragVM.isIndexing && ragVM.indexingID == meta.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(dotColor(meta, indexing: isThisIndexing))
                    .frame(width: 9, height: 9).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.name.isEmpty ? "(без имени)" : meta.name).fontWeight(.medium)
                    Text(summary(meta)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    if !meta.isReady && !isThisIndexing {
                        Text("черновик — не проиндексирован").font(.caption2).foregroundColor(.orange)
                    }
                }
                Spacer()
                if isThisIndexing {
                    Button("Отмена") { ragVM.cancelIndexing() }.buttonStyle(.borderless)
                } else {
                    Button("Индексировать") { ragVM.startIndexing(meta.id) }
                        .buttonStyle(.borderless).disabled(ragVM.isIndexing)
                    Button("Править") { editing = meta }.buttonStyle(.borderless).disabled(ragVM.isIndexing)
                    Button { ragVM.deleteIndex(meta.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundColor(.secondary).disabled(ragVM.isIndexing)
                }
            }
            if isThisIndexing, let p = ragVM.progress {
                ProgressView(value: p.fraction)
                Text(p.currentFile.isEmpty ? p.phase.title : "\(p.phase.title) · \(p.currentFile)")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // Тестовый поиск: выбрать индекс, ввести запрос, увидеть top-K попаданий.
    private var testSearchSection: some View {
        Section("Тестовый поиск") {
            Picker("Индекс", selection: $testIndexID) {
                Text("—").tag(UUID?.none)
                ForEach(readyIndexes) { ix in Text(ix.name).tag(Optional(ix.id)) }
            }
            HStack(spacing: 8) {
                TextField("", text: $testQuery, prompt: Text("вопрос к базе знаний…"))
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await runTestSearch() }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Найти") }
                }
                .disabled(testing || testQuery.trimmingCharacters(in: .whitespaces).isEmpty || effectiveTestIndex == nil)
            }
            ForEach(Array(testHits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(hit.chunk.metadata.section.isEmpty
                             ? hit.chunk.metadata.title : hit.chunk.metadata.section)
                            .font(.caption).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.3f", hit.score))
                            .font(.caption2).foregroundColor(.secondary).monospacedDigit()
                    }
                    Text(hit.chunk.text).font(.caption2).foregroundColor(.secondary).lineLimit(3)
                }
                .padding(.vertical, 1)
            }
            if !testHits.isEmpty {
                Text("Показаны top-\(testHits.count) фрагментов по косинусной близости.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// Выбранный для теста индекс (или первый готовый по умолчанию).
    private var effectiveTestIndex: UUID? { testIndexID ?? readyIndexes.first?.id }

    private func runTestSearch() async {
        guard let id = effectiveTestIndex else { return }
        testing = true
        testHits = await ragVM.testSearch(indexID: id, query: testQuery, topK: 5)
        testing = false
    }

    private func summary(_ meta: RagIndexMeta) -> String {
        var parts = [meta.config.backend.title, meta.config.chunking.title, meta.config.embedder.title]
        if meta.isReady { parts.append("\(meta.chunkCount) чанков · dim \(meta.dimension)") }
        return parts.joined(separator: " · ")
    }

    private func dotColor(_ meta: RagIndexMeta, indexing: Bool) -> Color {
        if indexing { return .accentColor }
        return meta.isReady ? .green : .orange
    }
}

// MARK: - Редактор индекса (создание / правка + запуск индексации)

struct RagIndexEditorView: View {
    @ObservedObject var ragVM: RagViewModel
    let existing: RagIndexMeta?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var source: RagSource
    @State private var config: RagIndexConfig
    @State private var extsText: String
    /// ID индекса, который строится из этого редактора (для показа прогресса).
    @State private var currentID: UUID?

    init(ragVM: RagViewModel, existing: RagIndexMeta?) {
        self.ragVM = ragVM
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _source = State(initialValue: existing?.source ?? RagSource())
        _config = State(initialValue: existing?.config ?? RagIndexConfig())
        _extsText = State(initialValue: (existing?.config.fileExtensions ?? RagIndexConfig().fileExtensions)
            .joined(separator: ", "))
        _currentID = State(initialValue: existing?.id)
    }

    private var isIndexingThis: Bool { ragVM.isIndexing && ragVM.indexingID == currentID }
    private var canIndex: Bool { !source.rootPath.isEmpty && !ragVM.isIndexing }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "Новый индекс" : "Индекс: \(name)").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            Form {
                sourceSection
                chunkingSection
                backendSection
                embedderSection
                indexingSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 640)
        .onAppear { if config.embedder == .ollama { ragVM.checkOllama(baseURL: config.ollamaBaseURL) } }
    }

    // Источник: файл или папка (NSOpenPanel) + число файлов.
    private var sourceSection: some View {
        Section("Источник") {
            HStack {
                Button { pickSource() } label: { Label("Выбрать файл или папку", systemImage: "folder") }
                Spacer()
                if !source.rootPath.isEmpty {
                    Text(source.isDirectory ? "\(source.fileCount) файлов" : "файл")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if source.rootPath.isEmpty {
                Text("Если выбрать папку — проиндексируются все подходящие файлы внутри (рекурсивно).")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(source.rootPath).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            TextField("", text: $name, prompt: Text("Название индекса"))
                .textFieldStyle(.roundedBorder)
        }
    }

    // Стратегия чанкинга.
    private var chunkingSection: some View {
        Section("Стратегия чанкинга") {
            Picker("Стратегия", selection: $config.chunking) {
                ForEach(ChunkingKind.allCases) { k in Text(k.title).tag(k) }
            }
            if config.chunking == .fixed {
                Stepper(value: $config.chunkSize, in: RagIndexConfig.chunkSizeRange, step: 100) {
                    labelValue("Размер чанка", "\(config.chunkSize) симв.")
                }
                Stepper(value: $config.chunkOverlap, in: RagIndexConfig.chunkOverlapRange, step: 50) {
                    labelValue("Нахлёст", "\(config.chunkOverlap) симв.")
                }
                Text("Текст режется окнами фиксированного размера с нахлёстом (нахлёст сохраняет контекст на стыках).")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Stepper(value: $config.chunkSize, in: RagIndexConfig.chunkSizeRange, step: 100) {
                    labelValue("Потолок раздела", "\(config.chunkSize) симв.")
                }
                Text("Границы чанков — по структуре: Markdown-заголовки/разделы и файлы. Метаданные несут раздел (section). Слишком длинный раздел дорезается по «потолку».")
                    .font(.caption).foregroundColor(.secondary)
            }
            extensionsField
        }
    }

    private var extensionsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Расширения файлов (через запятую)").font(.caption).foregroundStyle(.secondary)
            TextField("", text: $extsText, prompt: Text("md, txt, markdown"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: extsText) { _ in config.fileExtensions = parseExts(extsText) }
        }
    }

    // Бэкенд индекса.
    private var backendSection: some View {
        Section("Хранилище индекса") {
            Picker("Бэкенд", selection: $config.backend) {
                ForEach(IndexBackend.allCases) { b in Text(b.title).tag(b) }
            }
            Text("JSON — как остальные данные приложения (по умолчанию). Flat — компактный бинарный аналог FAISS IndexFlatL2 без внешних зависимостей. SQLite — векторы в BLOB'ах. Поиск top-K одинаков для всех (косинусная близость).")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // Эмбеддер.
    private var embedderSection: some View {
        Section("Эмбеддер") {
            Picker("Источник эмбеддингов", selection: $config.embedder) {
                Text(EmbedderKind.ollama.title).tag(EmbedderKind.ollama)
                Text(EmbedderKind.local.title).tag(EmbedderKind.local)
                Text(EmbedderKind.hashing.title).tag(EmbedderKind.hashing)
            }
            .onChange(of: config.embedder) { k in
                if k == .ollama { ragVM.checkOllama(baseURL: config.ollamaBaseURL) }
            }
            if config.embedder == .ollama {
                TextField("", text: $config.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                TextField("", text: $config.embedModel, prompt: Text("nomic-embed-text"))
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    ollamaBadge
                    Spacer()
                    Button("Проверить") { ragVM.checkOllama(baseURL: config.ollamaBaseURL) }
                        .buttonStyle(.borderless)
                }
                Text("Сервер поднимается автоматически при индексации/поиске (и глушится при выходе) — постоянно ничего не крутится. Нужна лишь установленная Ollama и стянутая модель: `ollama pull nomic-embed-text` (для русского лучше `bge-m3`). Бейдж «не запущена» до первого использования — это нормально.")
                    .font(.caption).foregroundColor(.secondary)
            } else if config.embedder == .local {
                Text("On-device Apple NaturalLanguage: офлайн, без сервера и ключей. Качество ниже трансформерных эмбеддингов; язык определяется автоматически.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Детерминированный хеш bag-of-words: без сети и моделей. Слабое качество ретрива — как офлайн-фолбэк и для тестов.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var ollamaBadge: some View {
        Group {
            switch ragVM.ollamaAvailable {
            case .some(true):  Label("Ollama доступна", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            case .some(false): Label("Ollama не запущена", systemImage: "xmark.circle.fill").foregroundColor(.orange)
            case .none:        Label("проверка…", systemImage: "clock").foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }

    // Запуск индексации + прогресс.
    private var indexingSection: some View {
        Section {
            if isIndexingThis, let p = ragVM.progress {
                ProgressView(value: p.fraction)
                Text(p.currentFile.isEmpty ? p.phase.title : "\(p.phase.title) · \(p.currentFile)")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Button("Отмена") { ragVM.cancelIndexing() }
            } else {
                Button {
                    startIndexing()
                } label: {
                    Label(existing == nil ? "Проиндексировать" : "Переиндексировать",
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canIndex)
                if let id = currentID, let meta = ragVM.indexes.first(where: { $0.id == id }), meta.isReady {
                    Label("Готово: \(meta.chunkCount) чанков, размерность \(meta.dimension)", systemImage: "checkmark.seal")
                        .font(.caption).foregroundColor(.green)
                }
                if let err = ragVM.errorText {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: Действия

    private func startIndexing() {
        config.fileExtensions = parseExts(extsText)
        if let existing {
            // Правка существующего: обновляем конфиг/имя/источник, затем переиндексация.
            var meta = existing
            meta.name = name.isEmpty ? existing.name : name
            meta.source = source
            meta.config = config
            ragVM.updateIndex(meta)
            currentID = meta.id
            ragVM.startIndexing(meta.id)
        } else {
            let meta = ragVM.addIndex(name: name, source: source, config: config)
            currentID = meta.id
            ragVM.startIndexing(meta.id)
        }
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        source.rootPath = url.path
        source.isDirectory = isDir.boolValue
        // Сразу считаем число подходящих файлов для показа.
        source.fileCount = RagIndexer.enumerateFiles(source: source, extensions: parseExts(extsText)).count
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = url.lastPathComponent }
    }

    private func parseExts(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".", with: "") }
            .filter { !$0.isEmpty }
    }

    private func labelValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).monospacedDigit()
        }
    }
}
