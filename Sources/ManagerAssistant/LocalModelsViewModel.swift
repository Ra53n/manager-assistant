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
    /// Куда качаем (локальная Ollama или VPS) — для подписи прогресса и refresh.
    @Published var pullingTarget: Provider? = nil
    @Published var pullProgress: PullProgress? = nil
    @Published var errorText: String? = nil

    /// Дёргается после pull/delete, чтобы ChatViewModel перечитал список моделей.
    var onModelsChanged: (() -> Void)? = nil

    private let client = LocalModelsClient()
    private var pullTask: Task<Void, Never>? = nil

    /// Раннеры панели: локальные + Ollama на VPS (не локальная, но управляется
    /// той же панелью через защищённый прокси).
    static let panelProviders: [Provider] = Provider.allCases.filter(\.isLocal) + [.vps]

    // MARK: Обновление статусов и списков

    /// Обновляет все раннеры параллельно.
    func refreshAll() {
        for provider in Self.panelProviders { refresh(provider) }
    }

    func refresh(_ provider: Provider) {
        status[provider] = .checking
        Task { [weak self] in
            guard let self else { return }
            switch provider {
            case .ollama: await self.refreshOllama()
            case .lmstudio: await self.refreshLMStudio()
            case .llamacpp: await self.refreshLlamaCpp()
            case .vps: await self.refreshVps()
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

    /// Текст ошибки кривого токена VPS — константа, чтобы успешный refresh мог
    /// снять именно её, не затирая чужие ошибки (например, упавшего pull).
    private static let vpsTokenErrorText = "VPS отвечает, но токен не подходит (401) — проверь «API-ключи»."

    /// Ollama на VPS через защищённый прокси: /api/tags с bearer-токеном.
    /// «Не установлена» не детектится (удалённая машина) — только running/stopped;
    /// 401 — сервер жив, но токен кривой: показываем running + понятную ошибку.
    private func refreshVps() async {
        let base = LocalEndpoints.baseURL(for: .vps)
        guard !base.isEmpty else {
            // Адрес не настроен — секция честно молчит «недоступен», без ошибок.
            status[.vps] = .stopped
            installed[.vps] = []
            return
        }
        do {
            installed[.vps] = try await client.ollamaInstalled(
                baseURL: base, bearerToken: KeyStore.key(for: .vps), provider: .vps)
            status[.vps] = .running
            if errorText == Self.vpsTokenErrorText { errorText = nil }  // токен починили
        } catch let e as LocalModelsError {
            if case .badStatus(let code, _) = e, code == 401 {
                status[.vps] = .running
                errorText = Self.vpsTokenErrorText
            } else {
                status[.vps] = .stopped
            }
            installed[.vps] = []
        } catch {
            status[.vps] = .stopped
            installed[.vps] = []
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

    // MARK: Скачивание / удаление (Ollama локально и на VPS)

    /// Скачивает модель из реестра Ollama со стриминговым прогрессом.
    /// target: .ollama — локальный раннер (поднимем сервер сами), .vps — через
    /// защищённый прокси (качает сервер НА VPS, модель ложится там).
    func pull(_ name: String, on target: Provider = .ollama) {
        guard target == .ollama || target == .vps else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pullTask == nil else { return }
        pullingModel = trimmed
        pullingTarget = target
        pullProgress = PullProgress(status: "подготовка…")
        errorText = nil

        pullTask = Task { [weak self] in
            let onProgress: @Sendable (PullProgress) -> Void = { p in
                Task { @MainActor in self?.pullProgress = p }
            }
            do {
                let base = LocalEndpoints.baseURL(for: target)
                if target == .ollama {
                    // Сервер может быть не запущен — поднимем (модель качает ОН).
                    guard await OllamaLauncher.shared.ensureRunning(baseURL: base) else {
                        throw DeepSeekError.localUnavailable(.ollama)
                    }
                }
                let token = target == .vps ? KeyStore.key(for: .vps) : nil
                let client = LocalModelsClient()
                try await client.pullOllama(model: trimmed, baseURL: base, bearerToken: token, progress: onProgress)
                await MainActor.run {
                    guard let self else { return }
                    self.finishPull()
                    self.refresh(target)
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

    /// Удаляет модель Ollama — локальную или на VPS (подтверждение — на вью).
    func delete(_ model: InstalledLocalModel) {
        guard model.provider == .ollama || model.provider == .vps else { return }
        let target = model.provider
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.deleteOllama(
                    model: model.name,
                    baseURL: LocalEndpoints.baseURL(for: target),
                    bearerToken: target == .vps ? KeyStore.key(for: .vps) : nil)
                self.refresh(target)
                self.onModelsChanged?()
            } catch {
                self.errorText = Self.describe(error)
            }
        }
    }

    // MARK: Внутреннее

    private func finishPull() {
        pullingModel = nil
        pullingTarget = nil
        pullProgress = nil
        pullTask = nil
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
