// LocalModelsTests.swift — чистая логика локальных моделей (офлайн, без сети).
//
// Покрывает: парсеры ответов Ollama//v1/models, разбор строк стрима /api/pull,
// скан каталога LM Studio по синтетическим путям, целостность каталога,
// снисходительный декод Provider и нормализацию LocalEndpoints.

import XCTest
@testable import ManagerAssistant

final class LocalModelsTests: XCTestCase {

    // MARK: /api/tags

    func testParseOllamaTags() throws {
        let json = """
        {"models":[
          {"name":"llama3.1:8b","size":4661224676,"details":{"quantization_level":"Q4_K_M","parameter_size":"8.0B"}},
          {"name":"nomic-embed-text:latest","size":274302450,"details":{}}
        ]}
        """.data(using: .utf8)!
        let models = try LocalModelsParsing.parseOllamaTags(json)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "llama3.1:8b")
        XCTAssertEqual(models[0].sizeBytes, 4_661_224_676)
        XCTAssertEqual(models[0].quantization, "Q4_K_M")
        XCTAssertEqual(models[0].parameterSize, "8.0B")
        XCTAssertEqual(models[0].provider, .ollama)
        XCTAssertTrue(models[0].chattable)
        XCTAssertNil(models[1].quantization)
        // Подпись пикера: вес · квант · параметры; у голого id подписи нет.
        XCTAssertEqual(models[0].detailLine?.contains("Q4_K_M"), true)
        XCTAssertEqual(models[0].detailLine?.contains("8.0B"), true)
        XCTAssertNil(InstalledLocalModel(name: "x", provider: .llamacpp).detailLine)
    }

    func testParseOllamaTagsTolerant() throws {
        // Минимальный ответ: только имена; и вовсе пустой объект.
        let minimal = #"{"models":[{"name":"x"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try LocalModelsParsing.parseOllamaTags(minimal).first?.name, "x")
        let empty = #"{}"#.data(using: .utf8)!
        XCTAssertEqual(try LocalModelsParsing.parseOllamaTags(empty).count, 0)
    }

    // MARK: /v1/models

    func testParseOpenAIModels() throws {
        let json = #"{"object":"list","data":[{"id":"qwen2.5-7b-instruct","object":"model"},{"id":"phi-4"}]}"#
            .data(using: .utf8)!
        let models = try LocalModelsParsing.parseOpenAIModels(json, provider: .lmstudio)
        XCTAssertEqual(models.map(\.name), ["qwen2.5-7b-instruct", "phi-4"])
        XCTAssertTrue(models.allSatisfy { $0.provider == .lmstudio && $0.chattable })

        let empty = #"{"data":[]}"#.data(using: .utf8)!
        XCTAssertEqual(try LocalModelsParsing.parseOpenAIModels(empty, provider: .llamacpp).count, 0)
    }

    // MARK: строки стрима /api/pull

    func testParsePullLineProgress() {
        let p = LocalModelsParsing.parsePullLine(
            #"{"status":"downloading sha256:abc","digest":"sha256:abc","total":1000,"completed":250}"#
        )
        XCTAssertEqual(p?.status, "downloading sha256:abc")
        XCTAssertEqual(p?.fraction, 0.25)
        XCTAssertEqual(p?.isSuccess, false)
    }

    func testParsePullLineSuccessAndClamp() {
        XCTAssertEqual(LocalModelsParsing.parsePullLine(#"{"status":"success"}"#)?.isSuccess, true)
        // completed > total (бывает на ретраях) — клампится в 1.
        let over = LocalModelsParsing.parsePullLine(#"{"status":"d","total":100,"completed":150}"#)
        XCTAssertEqual(over?.fraction, 1)
        // Без total — fraction нет (indeterminate).
        let noTotal = LocalModelsParsing.parsePullLine(#"{"status":"pulling manifest"}"#)
        XCTAssertNotNil(noTotal)
        XCTAssertNil(noTotal?.fraction)
    }

    func testParsePullLineErrorAndGarbage() {
        let err = LocalModelsParsing.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#)
        XCTAssertEqual(err?.errorText, "pull model manifest: file does not exist")
        XCTAssertNil(LocalModelsParsing.parsePullLine(""))
        XCTAssertNil(LocalModelsParsing.parsePullLine("   "))
        XCTAssertNil(LocalModelsParsing.parsePullLine("not json"))
        XCTAssertNil(LocalModelsParsing.parsePullLine(#"{"foo":"bar"}"#))
    }

    // MARK: скан каталога LM Studio

    func testScanLMStudioModels() {
        let paths: [(path: String, sizeBytes: Int64)] = [
            ("lmstudio-community/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m.gguf", 4_000),
            // Сплит-модель: две части одного репо суммируются в одну запись.
            ("bartowski/Big-Model-GGUF/big-model-00001-of-00002.gguf", 1_000),
            ("bartowski/Big-Model-GGUF/big-model-00002-of-00002.gguf", 2_000),
            // Мусор: не gguf, скрытые, слишком короткий путь.
            ("lmstudio-community/Qwen2.5-7B-Instruct-GGUF/README.md", 10),
            ("bartowski/Big-Model-GGUF/.DS_Store", 10),
            ("orphan.gguf", 10),
            (".hidden/repo/model.gguf", 10),
        ]
        let models = LocalModelsParsing.scanLMStudioModels(paths: paths)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "lmstudio-community/Qwen2.5-7B-Instruct-GGUF")
        XCTAssertEqual(models[0].sizeBytes, 4_000)
        XCTAssertEqual(models[1].name, "bartowski/Big-Model-GGUF")
        XCTAssertEqual(models[1].sizeBytes, 3_000)
        XCTAssertTrue(models.allSatisfy { $0.provider == .lmstudio && !$0.chattable })
    }

    // MARK: каталог

    func testCatalogIntegrity() {
        XCTAssertFalse(LocalCatalog.entries.isEmpty)
        let families = LocalCatalog.entries.map(\.family)
        XCTAssertEqual(families.count, Set(families).count, "семейства должны быть уникальны")
        for entry in LocalCatalog.entries {
            XCTAssertFalse(entry.tags.isEmpty, "\(entry.family): нет тегов")
            for tag in entry.tags {
                let full = entry.fullName(tag: tag.tag)
                XCTAssertFalse(full.contains(" "), "\(full): пробелы в имени")
                XCTAssertEqual(full, full.lowercased(), "\(full): имя реестра должно быть в нижнем регистре")
                XCTAssertGreaterThan(tag.approxGB, 0, "\(full): у каждого варианта должен быть примерный вес")
                XCTAssertEqual(entry.tagInfo(tag.tag), tag)
            }
        }
        // Метка «тяжёлая» и текст размера.
        let heavy = LocalCatalogTag(tag: "70b", approxGB: 40)
        XCTAssertTrue(heavy.isHeavy)
        XCTAssertFalse(LocalCatalogTag(tag: "8b", approxGB: 4.9).isHeavy)
        XCTAssertEqual(heavy.sizeText, "≈40,0 ГБ")
    }

    // MARK: Provider — снисходительный декод

    func testProviderLenientDecode() throws {
        let dec = JSONDecoder()
        for (raw, expected): (String, Provider) in
            [("deepseek", .deepseek), ("openrouter", .openrouter),
             ("ollama", .ollama), ("lmstudio", .lmstudio), ("llamacpp", .llamacpp)] {
            let decoded = try dec.decode(Provider.self, from: "\"\(raw)\"".data(using: .utf8)!)
            XCTAssertEqual(decoded, expected)
        }
        // Неизвестный провайдер из будущего файла → .deepseek, а не краш.
        XCTAssertEqual(try dec.decode(Provider.self, from: #""someday""#.data(using: .utf8)!), .deepseek)
    }

    func testGenerationSettingsWithLocalProvider() throws {
        // Настройки с локальным провайдером переживают round-trip,
        // а старый JSON без provider получает дефолт.
        var settings = GenerationSettings()
        settings.provider = .ollama
        settings.model = "llama3.1:8b"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: data)
        XCTAssertEqual(decoded.provider, .ollama)
        XCTAssertEqual(decoded.model, "llama3.1:8b")

        let old = #"{"model":"deepseek-chat"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(GenerationSettings.self, from: old).provider, .deepseek)
    }

    func testProviderFlags() {
        XCTAssertTrue(Provider.ollama.isLocal)
        XCTAssertTrue(Provider.lmstudio.isLocal)
        XCTAssertTrue(Provider.llamacpp.isLocal)
        XCTAssertFalse(Provider.deepseek.isLocal)
        XCTAssertFalse(Provider.openrouter.isLocal)
        for p in Provider.allCases {
            XCTAssertEqual(p.requiresKey, !p.isLocal)
        }
        // У локальных URL строятся от LocalEndpoints.
        XCTAssertTrue(Provider.ollama.chatURL.hasSuffix("/v1/chat/completions"))
        XCTAssertTrue(Provider.lmstudio.modelsURL.hasSuffix("/v1/models"))
    }

    // MARK: LocalEndpoints

    func testLocalEndpointsNormalizeAndDefaults() {
        XCTAssertEqual(LocalEndpoints.normalize("  http://127.0.0.1:11434/  "), "http://127.0.0.1:11434")
        XCTAssertEqual(LocalEndpoints.normalize("http://x//"), "http://x")
        XCTAssertEqual(LocalEndpoints.normalize("   "), "")
        XCTAssertEqual(LocalEndpoints.defaultBaseURL(for: .ollama), "http://127.0.0.1:11434")
        XCTAssertEqual(LocalEndpoints.defaultBaseURL(for: .lmstudio), "http://127.0.0.1:1234")
        XCTAssertEqual(LocalEndpoints.defaultBaseURL(for: .llamacpp), "http://127.0.0.1:8080")
        XCTAssertEqual(LocalEndpoints.defaultBaseURL(for: .deepseek), "")
    }
}
