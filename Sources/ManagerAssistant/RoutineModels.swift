// RoutineModels.swift — DTO агента рутин (VPS). Зеркалят серверный контракт
// (agent/src/domain/types.ts). Все типы декодируются СНИСХОДИТЕЛЬНО (decodeIfPresent +
// дефолты, unknown-значения enum → .unknown), чтобы новые поля/статусы сервера не
// роняли декод — тот же принцип, что у Chat/GenerationSettings (см. CLAUDE.md).
//
// JSON-ключи сервера уже в camelCase и совпадают с именами свойств, поэтому
// CodingKeys не переопределяем; используем дефолтные стратегии JSONEncoder/Decoder.

import Foundation

// MARK: - Перечисления (снисходительный декод: неизвестное → .unknown)

enum AgentProvider: String, Codable, CaseIterable {
    case deepseek, openrouter, unknown
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = AgentProvider(rawValue: raw) ?? .unknown
    }
}

enum RoutineSinkKind: String, Codable {
    case vpsLocal = "vps_local"
    case unknown
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = RoutineSinkKind(rawValue: raw) ?? .unknown
    }
}

enum RunTrigger: String, Codable {
    case schedule, manual, catchup, unknown
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = RunTrigger(rawValue: raw) ?? .unknown
    }
}

enum RunStatus: String, Codable {
    case running, ok, error, timeout
    case skippedOverlap = "skipped_overlap"
    case missed
    case unknown
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = RunStatus(rawValue: raw) ?? .unknown
    }

    /// Человекочитаемый бейдж для UI.
    var title: String {
        switch self {
        case .running: return "выполняется"
        case .ok: return "готово"
        case .error: return "ошибка"
        case .timeout: return "таймаут"
        case .skippedOverlap: return "пропущен (занят)"
        case .missed: return "пропущен слот"
        case .unknown: return "—"
        }
    }
}

// MARK: - Конфигурация места сохранения (sink)

// Сейчас встроено только локальное сохранение (история видна в приложении).
// Сохранение во внешние системы — через промпт рутины (у агента есть все MCP).
struct RoutineSinkConfig: Codable, Equatable {
    var kind: RoutineSinkKind = .vpsLocal

    enum CodingKeys: String, CodingKey { case kind }

    init(kind: RoutineSinkKind = .vpsLocal) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(RoutineSinkKind.self, forKey: .kind) ?? .vpsLocal
    }
}

// MARK: - Рутина

struct Routine: Codable, Identifiable, Equatable {
    var id: String = ""
    var name: String = ""
    var prompt: String = ""
    var cron: String = ""
    var timezone: String = "Europe/Moscow"
    var enabled: Bool = true
    var catchUpOnStart: Bool = false
    var model: String = ""
    var maxIterations: Int = 6
    var maxTokensBudget: Int = 20000
    var mode: String = "simple"          // "simple" | "pipeline"
    var swarm: Bool = true               // pipeline: рой подагентов волнами
    var maxParallelAgents: Int = 3       // pipeline+swarm: параллельность (2…6)
    var sinks: [RoutineSinkConfig] = [RoutineSinkConfig()]
    var lastRunAt: String? = nil
    var nextRunAt: String? = nil
    var cronHuman: String = ""
    var createdAt: String = ""
    var updatedAt: String = ""
    var rev: Int = 1

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, cron, timezone, enabled, catchUpOnStart, model
        case maxIterations, maxTokensBudget, mode, swarm, maxParallelAgents
        case sinks, lastRunAt, nextRunAt, cronHuman
        case createdAt, updatedAt, rev
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        cron = try c.decodeIfPresent(String.self, forKey: .cron) ?? ""
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "Europe/Moscow"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        catchUpOnStart = try c.decodeIfPresent(Bool.self, forKey: .catchUpOnStart) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 6
        maxTokensBudget = try c.decodeIfPresent(Int.self, forKey: .maxTokensBudget) ?? 20000
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "simple"
        swarm = try c.decodeIfPresent(Bool.self, forKey: .swarm) ?? true
        maxParallelAgents = try c.decodeIfPresent(Int.self, forKey: .maxParallelAgents) ?? 3
        sinks = try c.decodeIfPresent([RoutineSinkConfig].self, forKey: .sinks) ?? [RoutineSinkConfig()]
        lastRunAt = try c.decodeIfPresent(String.self, forKey: .lastRunAt)
        nextRunAt = try c.decodeIfPresent(String.self, forKey: .nextRunAt)
        cronHuman = try c.decodeIfPresent(String.self, forKey: .cronHuman) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 1
    }
}

// MARK: - Запись прогона

struct RunUsage: Codable, Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var costUsd: Double? = nil

    init(promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0, costUsd: Double? = nil) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.totalTokens = totalTokens; self.costUsd = costUsd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
    }
}

struct RunToolCall: Codable, Equatable {
    var name: String = ""
    var ok: Bool = false
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
    }
}

struct RunSinkResult: Codable, Equatable, Identifiable {
    var kind: RoutineSinkKind = .unknown
    var status: String = ""
    var error: String? = nil
    var externalRef: String? = nil
    var id: String { "\(kind.rawValue)|\(externalRef ?? "")|\(status)" }
    enum CodingKeys: String, CodingKey { case kind, status, error, externalRef }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(RoutineSinkKind.self, forKey: .kind) ?? .unknown
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error)
        externalRef = try c.decodeIfPresent(String.self, forKey: .externalRef)
    }
}

/// Запись прогона. Используется и для списка (без `outputMarkdown`/`toolTranscript`),
/// и для полной записи — недостающие поля декодируются как дефолты.
struct RunRecord: Codable, Identifiable, Equatable {
    var id: String = ""
    var routineId: String = ""
    var trigger: RunTrigger = .unknown
    var status: RunStatus = .unknown
    var scheduledFor: String? = nil
    var startedAt: String = ""
    var finishedAt: String? = nil
    var outputMarkdown: String = ""
    var usage: RunUsage = RunUsage()
    var toolTranscript: [RunToolCall] = []
    var sinkResults: [RunSinkResult] = []
    var error: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, routineId, trigger, status, scheduledFor, startedAt, finishedAt
        case outputMarkdown, usage, toolTranscript, sinkResults, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        routineId = try c.decodeIfPresent(String.self, forKey: .routineId) ?? ""
        trigger = try c.decodeIfPresent(RunTrigger.self, forKey: .trigger) ?? .unknown
        status = try c.decodeIfPresent(RunStatus.self, forKey: .status) ?? .unknown
        scheduledFor = try c.decodeIfPresent(String.self, forKey: .scheduledFor)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        outputMarkdown = try c.decodeIfPresent(String.self, forKey: .outputMarkdown) ?? ""
        usage = try c.decodeIfPresent(RunUsage.self, forKey: .usage) ?? RunUsage()
        toolTranscript = try c.decodeIfPresent([RunToolCall].self, forKey: .toolTranscript) ?? []
        sinkResults = try c.decodeIfPresent([RunSinkResult].self, forKey: .sinkResults) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Страница истории прогонов (cursor-пагинация).
struct RunPage: Codable {
    var items: [RunRecord] = []
    var nextCursor: String? = nil
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([RunRecord].self, forKey: .items) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
    enum CodingKeys: String, CodingKey { case items, nextCursor }
}

struct RoutinesList: Codable {
    var items: [Routine] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Routine].self, forKey: .items) ?? []
    }
    enum CodingKeys: String, CodingKey { case items }
}

// MARK: - Настройки агента (публичное, с маской секретов)

struct AgentSettings: Codable, Equatable {
    var provider: AgentProvider = .deepseek
    var defaultModel: String = "deepseek-chat"
    var defaultTimezone: String = "Europe/Moscow"
    var hasLlmKey: Bool = false
    var llmKeyHint: String = ""
    var updatedAt: String = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case provider, defaultModel, defaultTimezone, hasLlmKey, llmKeyHint, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .deepseek
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? "deepseek-chat"
        defaultTimezone = try c.decodeIfPresent(String.self, forKey: .defaultTimezone) ?? "Europe/Moscow"
        hasLlmKey = try c.decodeIfPresent(Bool.self, forKey: .hasLlmKey) ?? false
        llmKeyHint = try c.decodeIfPresent(String.self, forKey: .llmKeyHint) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

// MARK: - MCP-серверы (синхронизируются из приложения на агент)

/// Конфиг MCP-сервера для отправки на агент (зеркалит MCPServer приложения).
struct MCPServerDTO: Encodable {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var enabled: Bool

    init(_ s: MCPServer) {
        id = s.id.uuidString
        name = s.name
        command = s.command
        args = s.args
        env = s.env
        enabled = s.enabled
    }
}

struct McpServersRequest: Encodable {
    var servers: [MCPServerDTO]
}

/// Статус MCP-сервера на агенте (БЕЗ секретов).
struct McpServerStatusDTO: Codable, Identifiable {
    var id: String = ""
    var name: String = ""
    var command: String = ""
    var enabled: Bool = true
    var connected: Bool = false
    var toolCount: Int = 0
    var error: String? = nil

    enum CodingKeys: String, CodingKey { case id, name, command, enabled, connected, toolCount, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

struct McpServersResponse: Codable {
    var items: [McpServerStatusDTO] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([McpServerStatusDTO].self, forKey: .items) ?? []
    }
    enum CodingKeys: String, CodingKey { case items }
}

struct AgentChatReply: Codable {
    var reply: String = ""
    var usage: RunUsage? = nil
    var toolTranscript: [RunToolCall] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        usage = try c.decodeIfPresent(RunUsage.self, forKey: .usage)
        toolTranscript = try c.decodeIfPresent([RunToolCall].self, forKey: .toolTranscript) ?? []
    }
    enum CodingKeys: String, CodingKey { case reply, usage, toolTranscript }
}

// MARK: - Тела запросов (Encodable; nil-поля синтезатор опускает через encodeIfPresent)

struct CreateRoutineRequest: Encodable {
    var name: String
    var prompt: String
    var cron: String
    var timezone: String? = nil
    var enabled: Bool? = nil
    var catchUpOnStart: Bool? = nil
    var model: String? = nil
    var maxIterations: Int? = nil
    var maxTokensBudget: Int? = nil
    var mode: String? = nil
    var swarm: Bool? = nil
    var maxParallelAgents: Int? = nil
}

struct UpdateRoutineRequest: Encodable {
    var rev: Int
    var name: String? = nil
    var prompt: String? = nil
    var cron: String? = nil
    var timezone: String? = nil
    var enabled: Bool? = nil
    var catchUpOnStart: Bool? = nil
    var model: String? = nil
    var maxIterations: Int? = nil
    var maxTokensBudget: Int? = nil
    var mode: String? = nil
    var swarm: Bool? = nil
    var maxParallelAgents: Int? = nil
}

struct EnableRequest: Encodable {
    var enabled: Bool
}

struct UpdateAgentSettingsRequest: Encodable {
    var provider: String? = nil
    var llmApiKey: String? = nil
    var defaultModel: String? = nil
    var defaultTimezone: String? = nil
}

struct AgentChatMessage: Encodable {
    var role: String
    var content: String
}

struct AskRequest: Encodable {
    var routineId: String
    var runId: String?
    var allowTools: Bool?
    var messages: [AgentChatMessage]
}

// MARK: - Единый формат ошибки сервера

struct AgentErrorResponse: Decodable {
    struct Body: Decodable { var code: String?; var message: String? }
    var error: Body
}
