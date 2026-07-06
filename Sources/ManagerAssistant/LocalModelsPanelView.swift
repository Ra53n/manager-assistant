// LocalModelsPanelView.swift — панель локальных моделей (по образцу RagPanelView).
//
// Открывается иконкой-компьютером в шапке чата. Три секции раннеров (Ollama /
// LM Studio / llama.cpp): статус-бейдж, адрес сервера, установленные модели;
// у Ollama дополнительно каталог популярных моделей + ручной ввод для
// скачивания (/api/pull со стриминговым прогрессом) и удаление.
// Выбор модели для чата — как обычно, в настройках чата (пикер моделей):
// модели запущенных раннеров появляются там автоматически.

import SwiftUI

struct LocalModelsPanelView: View {
    @ObservedObject var vm: LocalModelsViewModel
    @Environment(\.dismiss) private var dismiss

    /// Черновики адресов серверов (сохраняются в LocalEndpoints по «Проверить»).
    @State private var baseURLs: [Provider: String] = [:]
    /// Ручной ввод имени модели для скачивания.
    @State private var manualName = ""
    /// Модель, ожидающая подтверждения удаления.
    @State private var deleting: InstalledLocalModel?
    /// Выбранный тег на семейство каталога (по умолчанию — первый).
    @State private var selectedTags: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Локальные модели").font(.headline)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                pullProgressSection
                ForEach(LocalModelsViewModel.localProviders, id: \.self) { provider in
                    runnerSection(provider)
                }
                if vm.status[.ollama] == .running {
                    catalogSection
                }
                if let err = vm.errorText {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                Section {
                    Text("Локальные модели работают без интернета и бесплатны (стоимость в метриках не считается). Модели Ollama ставятся из этой панели; LM Studio и llama.cpp управляют моделями сами — здесь видно, что установлено, а для чата их сервер должен быть запущен.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 680)
        .onAppear {
            for p in LocalModelsViewModel.localProviders {
                baseURLs[p] = LocalEndpoints.baseURL(for: p)
            }
            vm.refreshAll()
        }
        .confirmationDialog(
            "Удалить модель «\(deleting?.name ?? "")»? Файлы будут стёрты с диска.",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Удалить", role: .destructive) {
                if let m = deleting { vm.delete(m) }
                deleting = nil
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        }
    }

    // MARK: Секция раннера

    @ViewBuilder
    private func runnerSection(_ provider: Provider) -> some View {
        Section(provider.displayName) {
            statusRow(provider)
            baseURLRow(provider)
            modelsRows(provider)
        }
    }

    @ViewBuilder
    private func statusRow(_ provider: Provider) -> some View {
        let status = vm.status[provider] ?? .checking
        HStack(spacing: 8) {
            switch status {
            case .checking:
                Label("проверка…", systemImage: "clock").font(.caption).foregroundColor(.secondary)
            case .running:
                Label("работает", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
            case .stopped:
                Label("не запущен", systemImage: "pause.circle").font(.caption).foregroundColor(.secondary)
            case .notInstalled:
                Label("не установлен", systemImage: "xmark.circle.fill").font(.caption).foregroundColor(.orange)
            }
            Spacer()
            if provider == .ollama && status == .stopped {
                Button("Запустить") { vm.startOllamaIfNeeded() }.buttonStyle(.borderless)
            }
            if status == .notInstalled, let url = provider.runnerInstallURL {
                Link("Скачать…", destination: url).font(.caption)
            }
            Button {
                vm.refresh(provider)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Проверить статус и обновить список моделей")
        }
        if status == .notInstalled {
            Text(provider.runnerInstallHint).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func baseURLRow(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: Binding(
                    get: { baseURLs[provider] ?? "" },
                    set: { baseURLs[provider] = $0 }
                ),
                prompt: Text(LocalEndpoints.defaultBaseURL(for: provider))
            )
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            Button("Проверить") {
                LocalEndpoints.setBaseURL(baseURLs[provider] ?? "", for: provider)
                baseURLs[provider] = LocalEndpoints.baseURL(for: provider)
                vm.refresh(provider)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func modelsRows(_ provider: Provider) -> some View {
        let models = vm.installed[provider] ?? []
        if models.isEmpty {
            if vm.status[provider] == .running {
                Text("Моделей пока нет.").font(.caption).foregroundColor(.secondary)
            }
        } else {
            ForEach(models) { model in
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .foregroundColor(model.chattable ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name).font(.system(.body, design: .monospaced))
                        HStack(spacing: 6) {
                            if let size = model.sizeBytes {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                            if let quant = model.quantization { Text(quant) }
                        }
                        .font(.caption).foregroundColor(.secondary)
                        if !model.chattable {
                            Text("найдена на диске; для чата запустите сервер в LM Studio")
                                .font(.caption2).foregroundColor(.orange)
                        }
                    }
                    Spacer()
                    if provider == .ollama {
                        Button { deleting = model } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundColor(.secondary)
                            .help("Удалить модель с диска")
                    }
                }
            }
        }
    }

    // MARK: Каталог Ollama

    private var installedOllamaNames: Set<String> {
        Set((vm.installed[.ollama] ?? []).map(\.name))
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section("Каталог (Ollama)") {
            ForEach(LocalCatalog.entries) { entry in
                catalogRow(entry)
            }
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $manualName,
                    prompt: Text("Любая модель реестра, напр. qwen2.5:3b")
                )
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                Button("Скачать") { vm.pull(manualName); manualName = "" }
                    .buttonStyle(.borderless)
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty || vm.pullingModel != nil)
            }
            Text("Полный список — на ollama.com/library.").font(.caption2).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: LocalCatalogEntry) -> some View {
        let tag = selectedTags[entry.family] ?? entry.tags.first ?? ""
        let fullName = entry.fullName(tag: tag)
        let isInstalled = installedOllamaNames.contains(fullName)
            || installedOllamaNames.contains("\(fullName):latest")
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.family).font(.system(.body, design: .monospaced))
                Text(entry.summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { tag },
                set: { selectedTags[entry.family] = $0 }
            )) {
                ForEach(entry.tags, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 84)
            if isInstalled {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    .help("Уже установлена")
            } else {
                Button("Скачать") { vm.pull(fullName) }
                    .buttonStyle(.borderless)
                    .disabled(vm.pullingModel != nil)
            }
        }
    }

    // MARK: Прогресс скачивания

    @ViewBuilder
    private var pullProgressSection: some View {
        if let name = vm.pullingModel {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Скачивание \(name)").font(.caption).fontWeight(.medium)
                        Spacer()
                        Button("Отменить") { vm.cancelPull() }.buttonStyle(.borderless)
                    }
                    if let p = vm.pullProgress {
                        if let fraction = p.fraction {
                            ProgressView(value: fraction)
                            HStack {
                                Text(p.status).font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                if let total = p.total, let done = p.completed {
                                    Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        } else {
                            ProgressView()
                            Text(p.status).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
