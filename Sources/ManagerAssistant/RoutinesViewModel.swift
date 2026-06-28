// RoutinesViewModel.swift — состояние UI рутин. Тонкий клиент: VPS — источник
// истины, здесь только in-memory кэш + вызовы VPSAgentClient. НЕ участвует в
// локальном автосохранении (chats.json и т.п.) — у фичи нет локальной истины.
//
// Подключение к VPS (адрес+токен) — bootstrap в KeyStore; всё остальное (провайдер/
// LLM-ключ/модель/таймзона/YouGile) живёт на сервере и правится через «Настройки агента».

import Foundation
import SwiftUI

/// Фаза подключения к VPS — для понятного UX (одна кнопка «Подключиться»).
enum ConnectionPhase: Equatable {
    case idle
    case testing
    case ok(host: String)
    case failed(String)
}

@MainActor
final class RoutinesViewModel: ObservableObject {
    private let client = VPSAgentClient()

    @Published var routines: [Routine] = []
    @Published var runs: [RunRecord] = []
    @Published var runsNextCursor: String? = nil
    @Published var settings: AgentSettings? = nil

    @Published var isLoading = false
    @Published var isWorking = false
    @Published var errorText: String? = nil
    @Published var connectionState: ConnectionPhase = .idle
    /// Статус MCP-серверов на агенте (синхронизированы из приложения).
    @Published var mcpServerStatuses: [McpServerStatusDTO] = []

    var isConfigured: Bool { client.isConfigured }
    var agentBaseURL: String { KeyStore.agentURL }
    var agentToken: String { KeyStore.agentToken }
    /// Хост для отображения в шапке («vps.example»).
    var connectedHost: String { URL(string: agentBaseURL)?.host ?? agentBaseURL }

    // MARK: Подключение (один понятный шаг: сохранить → проверить → перейти)

    func saveConnection(url: String, token: String) {
        KeyStore.setAgentURL(url)
        KeyStore.setAgentToken(token)
        objectWillChange.send()
    }

    /// Сохраняет адрес+токен, проверяет связь и грузит данные. Возвращает успех.
    @discardableResult
    func connect(url: String, token: String) async -> Bool {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !t.isEmpty else {
            connectionState = .failed("Укажи адрес и токен.")
            return false
        }
        saveConnection(url: u, token: t)
        connectionState = .testing
        errorText = nil
        do {
            _ = try await client.health()
            settings = try await client.getSettings()
            connectionState = .ok(host: URL(string: u)?.host ?? u)
            routines = (try? await client.listRoutines()) ?? []
            return true
        } catch {
            connectionState = .failed(describe(error))
            return false
        }
    }

    /// Сброс подключения (кнопка «Отключиться»).
    func disconnect() {
        KeyStore.setAgentURL("")
        KeyStore.setAgentToken("")
        routines = []
        runs = []
        settings = nil
        connectionState = .idle
        objectWillChange.send()
    }

    // MARK: Загрузка

    func refresh() async {
        guard isConfigured else { return }
        isLoading = true
        errorText = nil
        do {
            async let r = client.listRoutines()
            async let s = client.getSettings()
            routines = try await r
            settings = try await s
        } catch {
            handle(error)
        }
        isLoading = false
    }

    func loadSettings() async {
        guard isConfigured else { return }
        do { settings = try await client.getSettings() } catch { handle(error) }
    }

    // MARK: Мутации рутин

    @discardableResult
    func create(_ req: CreateRoutineRequest) async -> Bool {
        await work {
            let created = try await self.client.createRoutine(req)
            self.routines.insert(created, at: 0)
            return true
        } ?? false
    }

    @discardableResult
    func update(id: String, _ req: UpdateRoutineRequest) async -> Bool {
        await work {
            let updated = try await self.client.updateRoutine(id: id, req)
            self.replace(updated)
            return true
        } ?? false
    }

    func setEnabled(id: String, _ enabled: Bool) async {
        _ = await work {
            let updated = try await self.client.setEnabled(id: id, enabled)
            self.replace(updated)
            return true
        }
    }

    func delete(id: String) async {
        _ = await work {
            try await self.client.deleteRoutine(id: id)
            self.routines.removeAll { $0.id == id }
            self.runs.removeAll()
            return true
        }
    }

    func trigger(id: String) async {
        _ = await work {
            _ = try await self.client.trigger(id: id, idempotencyKey: UUID().uuidString)
            return true
        }
        await loadRuns(routineId: id, reset: true)
        await pollRuns(routineId: id)
    }

    // MARK: История прогонов

    func loadRuns(routineId: String, reset: Bool) async {
        guard isConfigured else { return }
        do {
            let page = try await client.listRuns(routineId: routineId, limit: 20,
                                                 cursor: reset ? nil : runsNextCursor)
            if reset { runs = page.items } else { runs.append(contentsOf: page.items) }
            runsNextCursor = page.nextCursor
        } catch {
            handle(error)
        }
    }

    func fullRun(_ runId: String) async -> RunRecord? {
        do { return try await client.getRun(runId: runId) } catch { handle(error); return nil }
    }

    // MARK: Настройки агента

    func saveSettings(_ req: UpdateAgentSettingsRequest) async {
        _ = await work {
            self.settings = try await self.client.putSettings(req)
            return true
        }
    }

    // MARK: MCP-серверы (источник правды — приложение, синхронизируем на агент)

    /// Отправляет список MCP-серверов приложения на агент и обновляет статусы.
    func syncMcpServers(_ servers: [MCPServer]) async {
        guard isConfigured else { return }
        do {
            mcpServerStatuses = try await client.putMcpServers(servers.map(MCPServerDTO.init))
        } catch {
            handle(error)
        }
    }

    func loadMcpServers() async {
        guard isConfigured else { return }
        if let items = try? await client.getMcpServers() { mcpServerStatuses = items }
    }

    // MARK: Диалог с агентом

    func ask(routineId: String, runId: String?, message: String,
             history: [AgentChatMessage]) async -> AgentChatReply? {
        do {
            let req = AskRequest(routineId: routineId, runId: runId, allowTools: true,
                                 messages: history + [AgentChatMessage(role: "user", content: message)])
            return try await client.ask(req)
        } catch {
            handle(error)
            return nil
        }
    }

    // MARK: Внутреннее

    /// Короткий поллинг истории, пока верхний прогон ещё «running».
    private func pollRuns(routineId: String) async {
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await loadRuns(routineId: routineId, reset: true)
            if runs.first?.status != .running { break }
        }
    }

    private func replace(_ routine: Routine) {
        if let i = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[i] = routine
        } else {
            routines.insert(routine, at: 0)
        }
    }

    /// Обёртка мутации: флаг isWorking + перехват/показ ошибки. Возвращает nil при ошибке.
    private func work<T>(_ body: @escaping () async throws -> T) async -> T? {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            return try await body()
        } catch {
            handle(error)
            // Конфликт версий: перечитываем рутины, чтобы кэш не расходился с сервером.
            if case VPSAgentError.conflict = error { await reloadRoutinesQuietly() }
            return nil
        }
    }

    private func reloadRoutinesQuietly() async {
        if let r = try? await client.listRoutines() { routines = r }
    }

    private func handle(_ error: Error) {
        errorText = describe(error)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
