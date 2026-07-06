// LocalModelsViewModel.swift — состояние UI панели локальных моделей.
//
// Тонкий клиент по образцу RagViewModel (@MainActor, ObservableObject): сеть —
// в LocalModelsClient, парсинг — в LocalModelsParsing. Один экземпляр на
// приложение (создаётся в ContentView). Скачивание (pull) живёт в своём Task
// и переживает закрытие шита — при повторном открытии прогресс снова виден.

import Foundation
import SwiftUI

@MainActor
final class LocalModelsViewModel: ObservableObject {
    /// Статус каждого локального раннера по последней проверке.
    @Published var status: [Provider: RunnerStatus] = [:]
    /// Установленные модели по раннерам.
    @Published var installed: [Provider: [InstalledLocalModel]] = [:]
    /// Имя модели, которая сейчас скачивается (nil — ничего не качаем).
    @Published var pullingModel: String? = nil
    @Published var pullProgress: PullProgress? = nil
    @Published var errorText: String? = nil

    /// Дёргается после pull/delete, чтобы ChatViewModel перечитал список моделей.
    var onModelsChanged: (() -> Void)? = nil

    private let client = LocalModelsClient()
    private var pullTask: Task<Void, Never>? = nil

    static let localProviders: [Provider] = Provider.allCases.filter(\.isLocal)

    // MARK: Обновление статусов и списков

    /// Обновляет все три раннера параллельно.
    func refreshAll() {
        for provider in Self.localProviders { refresh(provider) }
    }

    func refresh(_ provider: Provider) {
        status[provider] = .checking
        Task { [weak self] in
            guard let self else { return }
            switch provider {
            case .ollama: await self.refreshOllama()
            case .lmstudio: await self.refreshLMStudio()
            case .llamacpp: await self.refreshLlamaCpp()
            default: break
            }
        }
    }

    private func refreshOllama() async {
        let base = LocalEndpoints.baseURL(for: .ollama)
        if await LocalModelsClient.isReachable(.ollama) {
            let models = (try? await client.ollamaInstalled(baseURL: base)) ?? []
            status[.ollama] = .running
            installed[.ollama] = models
        } else {
            status[.ollama] = OllamaLauncher.findBinary() == nil ? .notInstalled : .stopped
            installed[.ollama] = []
        }
    }

    private func refreshLMStudio() async {
        // Скан диска ВСЕГДА: модели видны, даже когда сервер LM Studio выключен.
        let diskModels = client.lmStudioDiskModels()
        if await LocalModelsClient.isReachable(.lmstudio) {
            let serverModels = (try? await client.openAIModels(provider: .lmstudio)) ?? []
            // Серверный список поверх дисковых; дедуп по совпадению имён
            // (каталог "publisher/repo" vs id сервера — сравнение lowercased,
            // "/"→"-", вхождение в обе стороны; неидеально, но ложный дубль
            // хуже пропущенного).
            let merged = serverModels + diskModels.filter { disk in
                let diskKey = disk.name.lowercased().replacingOccurrences(of: "/", with: "-")
                return !serverModels.contains { server in
                    let serverKey = server.name.lowercased()
                    return serverKey.contains(diskKey) || diskKey.contains(serverKey)
                }
            }
            status[.lmstudio] = .running
            installed[.lmstudio] = merged
        } else {
            let appInstalled = FileManager.default.fileExists(atPath: "/Applications/LM Studio.app")
                || FileManager.default.fileExists(
                    atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio").path)
            status[.lmstudio] = appInstalled ? .stopped : .notInstalled
            installed[.lmstudio] = diskModels
        }
    }

    private func refreshLlamaCpp() async {
        if await LocalModelsClient.isReachable(.llamacpp) {
            status[.llamacpp] = .running
            installed[.llamacpp] = (try? await client.openAIModels(provider: .llamacpp)) ?? []
        } else {
            // Установку CLI не детектим (бинарь может лежать где угодно).
            status[.llamacpp] = .stopped
            installed[.llamacpp] = []
        }
    }

    /// Кнопка «Запустить» для Ollama: ленивый запуск сервера + обновление списка.
    func startOllamaIfNeeded() {
        status[.ollama] = .checking
        Task { [weak self] in
            await OllamaLauncher.shared.ensureRunning(baseURL: LocalEndpoints.baseURL(for: .ollama))
            await self?.refreshOllama()
        }
    }

    // MARK: Скачивание / удаление (только Ollama)

    /// Скачивает модель из реестра Ollama со стриминговым прогрессом.
    func pull(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pullTask == nil else { return }
        pullingModel = trimmed
        pullProgress = PullProgress(status: "подготовка…")
        errorText = nil

        pullTask = Task { [weak self] in
            let onProgress: @Sendable (PullProgress) -> Void = { p in
                Task { @MainActor in self?.pullProgress = p }
            }
            do {
                let base = LocalEndpoints.baseURL(for: .ollama)
                // Сервер может быть не запущен — поднимем (модель качает ОН).
                guard await OllamaLauncher.shared.ensureRunning(baseURL: base) else {
                    throw DeepSeekError.localUnavailable(.ollama)
                }
                let client = LocalModelsClient()
                try await client.pullOllama(model: trimmed, baseURL: base, progress: onProgress)
                await MainActor.run {
                    guard let self else { return }
                    self.finishPull()
                    self.refresh(.ollama)
                    self.onModelsChanged?()
                }
            } catch is CancellationError {
                await MainActor.run { self?.finishPull() }   // отмена — не ошибка
            } catch let e as URLError where e.code == .cancelled {
                await MainActor.run { self?.finishPull() }
            } catch {
                await MainActor.run {
                    self?.errorText = Self.describe(error)
                    self?.finishPull()
                }
            }
        }
    }

    func cancelPull() { pullTask?.cancel() }

    /// Удаляет модель Ollama (подтверждение — на вью).
    func delete(_ model: InstalledLocalModel) {
        guard model.provider == .ollama else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.deleteOllama(model: model.name, baseURL: LocalEndpoints.baseURL(for: .ollama))
                self.refresh(.ollama)
                self.onModelsChanged?()
            } catch {
                self.errorText = Self.describe(error)
            }
        }
    }

    // MARK: Внутреннее

    private func finishPull() {
        pullingModel = nil
        pullProgress = nil
        pullTask = nil
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
