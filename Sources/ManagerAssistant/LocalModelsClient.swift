// LocalModelsClient.swift — HTTP-обвязка локальных раннеров (Ollama/LM Studio/llama.cpp).
//
// Struct без полей (Sendable), как DeepSeekClient. Парсинг ответов — в
// LocalModelsParsing (LocalModels.swift), здесь только сеть и файловый скан
// каталога LM Studio. Никогда сам не запускает серверы — этим занимаются
// OllamaLauncher (для Ollama) и пользователь (LM Studio/llama.cpp).

import Foundation

enum LocalModelsError: LocalizedError {
    case badURL
    case badStatus(code: Int, message: String)
    case pullFailed(String)          // строка {"error":…} из стрима /api/pull
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Некорректный адрес локального сервера"
        case .badStatus(let code, let message): return "HTTP \(code): \(message)"
        case .pullFailed(let text): return "Не удалось скачать модель: \(text)"
        case .modelNotFound(let name): return "Модель «\(name)» не найдена"
        }
    }
}

struct LocalModelsClient {
    /// Быстрая проверка: отвечает ли раннер (GET {base}/v1/models, 2 с).
    /// БЕЗ запуска сервера — используется и в loadModels на старте приложения.
    static func isReachable(_ provider: Provider) async -> Bool {
        guard provider.isLocal,
              let url = URL(string: LocalEndpoints.baseURL(for: provider) + "/v1/models")
        else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Установленные модели Ollama с размерами/квантами: GET /api/tags.
    /// bearerToken — для Ollama за защищённым прокси (VPS); provider помечает
    /// модели (у .vps иначе удаление/обновление целились бы в локальный раннер).
    func ollamaInstalled(baseURL: String, bearerToken: String? = nil, provider: Provider = .ollama) async throws -> [InstalledLocalModel] {
        let data = try await get(baseURL + "/api/tags", bearerToken: bearerToken)
        return try LocalModelsParsing.parseOllamaTags(data, provider: provider)
    }

    /// Модели OpenAI-совместимого /v1/models (LM Studio, llama.cpp).
    func openAIModels(provider: Provider) async throws -> [InstalledLocalModel] {
        let data = try await get(LocalEndpoints.baseURL(for: provider) + "/v1/models")
        return try LocalModelsParsing.parseOpenAIModels(data, provider: provider)
    }

    /// Скачивание модели через Ollama: POST /api/pull, стрим JSON-строк прогресса.
    /// Отмена: отмена обёртывающего Task рвёт итерацию bytes.lines (CancellationError/
    /// URLError.cancelled) и сам HTTP; плюс явный checkCancellation на каждой строке.
    func pullOllama(
        model: String,
        baseURL: String,
        bearerToken: String? = nil,
        progress: @escaping @Sendable (PullProgress) -> Void
    ) async throws {
        guard let url = URL(string: baseURL + "/api/pull") else { throw LocalModelsError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Оба ключа: новые версии Ollama ждут "model", старые — "name"; лишний игнорируется.
        struct PullBody: Encodable { let model: String; let name: String; let stream: Bool }
        req.httpBody = try JSONEncoder().encode(PullBody(model: model, name: model, stream: true))
        // timeoutInterval — idle-таймаут МЕЖДУ байтами, не на всю загрузку:
        // многогигабайтный pull безопасен, а зависший CDN отвалится за 5 минут.
        req.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelsError.badStatus(code: -1, message: "нет HTTP-ответа")
        }
        guard (200...299).contains(http.statusCode) else {
            // Тело до статуса уже стрим — читаем немного ради текста ошибки.
            var text = ""
            for try await line in bytes.lines {
                text = line
                break
            }
            throw LocalModelsError.badStatus(code: http.statusCode, message: text.isEmpty ? "ошибка сервера" : text)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let p = LocalModelsParsing.parsePullLine(line) else { continue }
            if let err = p.errorText, !err.isEmpty {
                throw LocalModelsError.pullFailed(err)
            }
            progress(p)
        }
    }

    /// Удаление модели Ollama: DELETE /api/delete.
    func deleteOllama(model: String, baseURL: String, bearerToken: String? = nil) async throws {
        guard let url = URL(string: baseURL + "/api/delete") else { throw LocalModelsError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(["model": model, "name": model])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelsError.badStatus(code: -1, message: "нет HTTP-ответа")
        }
        if http.statusCode == 404 { throw LocalModelsError.modelNotFound(model) }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "неизвестная ошибка"
            throw LocalModelsError.badStatus(code: http.statusCode, message: text)
        }
    }

    /// Модели LM Studio на диске (видны, даже когда его сервер выключен):
    /// актуальный ~/.lmstudio/models и легаси ~/.cache/lm-studio/models.
    func lmStudioDiskModels() -> [InstalledLocalModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".lmstudio/models"),
            home.appendingPathComponent(".cache/lm-studio/models"),
        ]
        var entries: [(path: String, sizeBytes: Int64)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let relPath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                entries.append((path: relPath, sizeBytes: Int64(values.fileSize ?? 0)))
            }
        }
        return LocalModelsParsing.scanLMStudioModels(paths: entries)
    }

    // MARK: Вспомогательное

    private func get(_ urlString: String, bearerToken: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LocalModelsError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let token = bearerToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocalModelsError.badStatus(code: code, message: "не удалось получить список моделей")
        }
        return data
    }
}
