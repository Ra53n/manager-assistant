// LocalModels.swift — локальные LLM-модели: чистые типы, парсеры и каталог.
//
// Всё в этом файле офлайн-тестируемо (LocalModelsTests): никакой сети и
// FileManager — только структуры данных и функции над Data/строками/путями.
// HTTP-обвязка — в LocalModelsClient.swift, состояние UI — в LocalModelsViewModel.

import Foundation

// MARK: - Установленные модели

/// Модель, найденная у локального раннера (Ollama /api/tags, LM Studio или
/// llama.cpp /v1/models, либо сканом каталога LM Studio на диске).
struct InstalledLocalModel: Identifiable, Hashable {
    var name: String            // id для чата: "llama3.1:8b" / "qwen2.5-7b-instruct"
    var sizeBytes: Int64?       // nil — размер неизвестен (/v1/models его не отдаёт)
    var quantization: String?   // "Q4_K_M" из details Ollama
    var parameterSize: String?  // "8.0B" / "494.03M" из details Ollama — «мощность»
    var provider: Provider
    /// false — найдена только сканом диска LM Studio: имя каталога (publisher/repo)
    /// НЕ совпадает с id, который отдаст /v1/models, поэтому в чат её не подставить.
    var chattable: Bool = true

    var id: String { "\(provider.rawValue)|\(name)" }

    /// Компактная строка метаданных для пикера/панели: «4,7 ГБ · Q4_K_M · 8B».
    /// nil — если о модели вообще ничего не известно (голый id из /v1/models).
    var detailLine: String? {
        var parts: [String] = []
        if let size = sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let quant = quantization, !quant.isEmpty { parts.append(quant) }
        if let params = parameterSize, !params.isEmpty { parts.append(params) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Прогресс скачивания (/api/pull)

/// Одна строка стрима Ollama /api/pull.
struct PullProgress: Equatable {
    var status: String = ""     // "pulling manifest", "downloading …", "success"
    var total: Int64? = nil
    var completed: Int64? = nil
    var errorText: String? = nil

    /// Доля 0…1; nil, когда total неизвестен (этапы манифеста/верификации).
    var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var isSuccess: Bool { status == "success" }
}

// MARK: - Парсеры

enum LocalModelsParsing {
    // Ollama GET /api/tags → {"models":[{"name":…,"size":…,
    //   "details":{"quantization_level":…,"parameter_size":…}}]}
    private struct OllamaTags: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let quantization_level: String?
                let parameter_size: String?
            }
            let name: String
            let size: Int64?
            let details: Details?
        }
        let models: [Model]?
    }

    /// Список установленных моделей Ollama (имя обязательно, остальное — как есть).
    /// provider параметризован: тот же /api/tags отдаёт и Ollama на VPS (.vps) —
    /// без этого удаление/обновление целились бы в локальный раннер.
    static func parseOllamaTags(_ data: Data, provider: Provider = .ollama) throws -> [InstalledLocalModel] {
        let decoded = try JSONDecoder().decode(OllamaTags.self, from: data)
        return (decoded.models ?? []).map { m in
            InstalledLocalModel(
                name: m.name,
                sizeBytes: m.size,
                quantization: m.details?.quantization_level,
                parameterSize: m.details?.parameter_size,
                provider: provider
            )
        }
    }

    // /v1/models (LM Studio, llama.cpp) → {"data":[{"id":…}]}.
    // Свой мини-DTO: ModelsResponse из DeepSeekClient приватный и тянет pricing.
    private struct OpenAIModels: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]?
    }

    /// Модели OpenAI-совместимого /v1/models.
    static func parseOpenAIModels(_ data: Data, provider: Provider) throws -> [InstalledLocalModel] {
        let decoded = try JSONDecoder().decode(OpenAIModels.self, from: data)
        return (decoded.data ?? []).map { InstalledLocalModel(name: $0.id, provider: provider) }
    }

    /// Одна JSON-строка стрима /api/pull → прогресс; мусор/пустая строка → nil.
    /// {"error": …} возвращается как PullProgress с errorText (клиент бросит ошибку).
    static func parsePullLine(_ line: String) -> PullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        struct Line: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        if decoded.status == nil && decoded.error == nil { return nil }
        return PullProgress(
            status: decoded.status ?? "",
            total: decoded.total,
            completed: decoded.completed,
            errorText: decoded.error
        )
    }

    /// Скан каталога моделей LM Studio по СПИСКУ относительных путей (чистая
    /// функция — FileManager снаружи). Раскладка: <root>/<publisher>/<repo>/<file>.gguf
    /// (сплит-модели — несколько .gguf глубже). Имя = "publisher/repo", размеры
    /// частей суммируются, скрытые файлы пропускаются, дедуп по имени.
    static func scanLMStudioModels(paths: [(path: String, sizeBytes: Int64)]) -> [InstalledLocalModel] {
        var sizes: [String: Int64] = [:]   // "publisher/repo" → суммарный размер
        var order: [String] = []           // стабильный порядок первого появления
        for entry in paths {
            let components = entry.path.split(separator: "/").map(String.init)
            guard components.count >= 3 else { continue }               // нужен publisher/repo/файл
            guard let file = components.last,
                  file.lowercased().hasSuffix(".gguf"),
                  !file.hasPrefix(".") else { continue }                 // только .gguf, без скрытых
            guard !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            let name = components[0] + "/" + components[1]
            if sizes[name] == nil { order.append(name) }
            sizes[name, default: 0] += entry.sizeBytes
        }
        return order.map { name in
            InstalledLocalModel(
                name: name,
                sizeBytes: sizes[name],
                quantization: nil,
                provider: .lmstudio,
                chattable: false
            )
        }
    }
}

// MARK: - Каталог популярных моделей (реестр Ollama)

/// Вариант размера модели в каталоге: тег реестра + примерный вес скачивания.
/// Тег («8b» = 8 млрд параметров) — это и есть «мощность»: больше параметров →
/// умнее, но тяжелее и медленнее. Веса — дефолтные кванты (Q4_K_M) реестра
/// Ollama, приблизительно.
struct LocalCatalogTag: Hashable {
    let tag: String         // "8b"
    let approxGB: Double    // ≈ вес скачивания в ГБ

    /// «≈4,7 ГБ» — для строки каталога.
    var sizeText: String { String(format: "≈%.1f ГБ", approxGB).replacingOccurrences(of: ".", with: ",") }
    /// Большая модель: перед скачиванием стоит подумать о месте на диске.
    var isHeavy: Bool { approxGB >= 15 }
}

/// Семейство моделей в курируемом каталоге; полное имя для pull = "family:tag".
struct LocalCatalogEntry: Identifiable, Hashable {
    let family: String          // "llama3.1"
    let summary: String         // короткое описание по-русски
    let tags: [LocalCatalogTag] // варианты размеров
    var id: String { family }

    func fullName(tag: String) -> String { "\(family):\(tag)" }
    func tagInfo(_ tag: String) -> LocalCatalogTag? { tags.first { $0.tag == tag } }
}

enum LocalCatalog {
    private static func t(_ tag: String, _ gb: Double) -> LocalCatalogTag {
        LocalCatalogTag(tag: tag, approxGB: gb)
    }

    static let entries: [LocalCatalogEntry] = [
        LocalCatalogEntry(family: "llama3.1", summary: "Meta, универсальная",
                          tags: [t("8b", 4.9), t("70b", 40)]),
        LocalCatalogEntry(family: "llama3.2", summary: "Meta, компактная",
                          tags: [t("1b", 1.3), t("3b", 2.0)]),
        LocalCatalogEntry(family: "qwen2.5", summary: "Alibaba, сильна в русском",
                          tags: [t("0.5b", 0.4), t("1.5b", 1.0), t("3b", 1.9), t("7b", 4.7),
                                 t("14b", 9.0), t("32b", 20), t("72b", 47)]),
        LocalCatalogEntry(family: "qwen2.5-coder", summary: "Alibaba, для кода",
                          tags: [t("1.5b", 1.0), t("7b", 4.7), t("32b", 20)]),
        LocalCatalogEntry(family: "gemma2", summary: "Google, сбалансированная",
                          tags: [t("2b", 1.6), t("9b", 5.4), t("27b", 16)]),
        LocalCatalogEntry(family: "mistral", summary: "Mistral AI, классика 7B",
                          tags: [t("7b", 4.1)]),
        LocalCatalogEntry(family: "deepseek-r1", summary: "DeepSeek, рассуждающая",
                          tags: [t("1.5b", 1.1), t("7b", 4.7), t("8b", 4.9), t("14b", 9.0),
                                 t("32b", 20), t("70b", 43)]),
        LocalCatalogEntry(family: "phi4", summary: "Microsoft, компактная и умная",
                          tags: [t("14b", 9.1)]),
        LocalCatalogEntry(family: "llava", summary: "мультимодальная (картинки)",
                          tags: [t("7b", 4.7), t("13b", 8.0)]),
    ]
}

// MARK: - Статус раннера

/// Состояние локального раннера для строки статуса в панели.
enum RunnerStatus: Equatable {
    case checking       // идёт проверка
    case running        // сервер отвечает
    case stopped        // раннер найден/установлен, но сервер не запущен
    case notInstalled   // раннер не найден на машине
}

extension Provider {
    /// Подсказка по установке раннера (для статуса «не установлен»).
    var runnerInstallHint: String {
        switch self {
        case .ollama: return "Скачайте Ollama с ollama.com/download и запустите — модели ставятся прямо из этой панели."
        case .lmstudio: return "Скачайте LM Studio с lmstudio.ai; модели ставятся в самом LM Studio, для чата включите его сервер (Developer → Start Server)."
        case .llamacpp: return "Соберите/установите llama.cpp и запустите llama-server с моделью GGUF."
        case .vps: return "Ollama на VPS недоступна: проверь адрес/токен в «API-ключи», а на сервере — bash agent/deploy/install-llm.sh (ставит Ollama и защищённый прокси)."
        case .deepseek, .openrouter: return ""
        }
    }

    var runnerInstallURL: URL? {
        switch self {
        case .ollama: return URL(string: "https://ollama.com/download")
        case .lmstudio: return URL(string: "https://lmstudio.ai")
        case .llamacpp: return URL(string: "https://github.com/ggml-org/llama.cpp")
        case .deepseek, .openrouter, .vps: return nil
        }
    }
}
