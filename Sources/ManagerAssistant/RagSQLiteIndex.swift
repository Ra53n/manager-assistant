// RagSQLiteIndex.swift — векторный индекс в SQLite (нативно, без SwiftPM-зависимости).
//
// Использует системный модуль SQLite3 (`import SQLite3`) — он есть в macOS SDK
// (проверено: sqlite3.modulemap в SDK), поэтому в Package.swift ничего добавлять не
// нужно. Вынесено в отдельный файл, т.к. импортирует C-API и работает с указателями.
//
// Схема: таблица vectors(ordinal PK, dim, vec BLOB), где vec — вектор Float32 в LE
// (тот же формат сериализации, что у FlatVectorIndex — см. RagFileIO). Поиск top-K
// одинаков для всех бэкендов (Vector.topK по загруженной матрице): для локального
// корпуса читать все векторы дёшево, а логика хранения остаётся единообразной.

import Foundation
import SQLite3

/// SQLite-бэкенд векторного индекса. save() пересоздаёт БД целиком (индексация всегда
/// полная), load() читает векторы в порядке ordinal.
struct SQLiteVectorIndex: VectorIndexStore {
    let backend: IndexBackend = .sqlite
    let fileName = "vectors.sqlite"

    /// Деструктор SQLITE_TRANSIENT — просим SQLite скопировать переданный буфер.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func save(_ vectors: [[Float]], to dir: URL) throws {
        let url = dir.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Пересоздаём файл целиком — индексация всегда с нуля.
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw VectorIndexError.io("не удалось открыть БД: \(Self.lastError(db))")
        }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA journal_mode=OFF;")
        try exec(db, "CREATE TABLE vectors (ordinal INTEGER PRIMARY KEY, dim INTEGER, vec BLOB);")
        try exec(db, "BEGIN TRANSACTION;")

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO vectors (ordinal, dim, vec) VALUES (?, ?, ?);",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw VectorIndexError.io("prepare insert: \(Self.lastError(db))")
        }
        defer { sqlite3_finalize(stmt) }

        for (ordinal, v) in vectors.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(ordinal))
            sqlite3_bind_int(stmt, 2, Int32(v.count))
            var blob = Data()
            blob.reserveCapacity(v.count * 4)
            for f in v { RagFileIO.appendFloat32(&blob, f) }
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(blob.count), Self.transient)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VectorIndexError.io("insert ordinal \(ordinal): \(Self.lastError(db))")
            }
        }
        try exec(db, "COMMIT;")
    }

    func load(from dir: URL) throws -> [[Float]] {
        let url = dir.appendingPathComponent(fileName)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw VectorIndexError.io("не удалось открыть БД: \(Self.lastError(db))")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT dim, vec FROM vectors ORDER BY ordinal ASC;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw VectorIndexError.badFormat("prepare select: \(Self.lastError(db))")
        }
        defer { sqlite3_finalize(stmt) }

        var result: [[Float]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dim = Int(sqlite3_column_int(stmt, 0))
            guard let raw = sqlite3_column_blob(stmt, 1) else {
                result.append([Float](repeating: 0, count: dim)); continue
            }
            let byteCount = Int(sqlite3_column_bytes(stmt, 1))
            let bytes = [UInt8](UnsafeRawBufferPointer(start: raw, count: byteCount))
            var v = [Float](repeating: 0, count: dim)
            var offset = 0
            for i in 0..<dim where offset + 4 <= byteCount {
                v[i] = RagFileIO.readFloat32(bytes, offset)
                offset += 4
            }
            result.append(v)
        }
        return result
    }

    // MARK: Вспомогательное

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "неизвестная ошибка"
            sqlite3_free(err)
            throw VectorIndexError.io("\(sql) → \(message)")
        }
    }

    private static func lastError(_ db: OpaquePointer?) -> String {
        guard let db else { return "нет соединения" }
        return String(cString: sqlite3_errmsg(db))
    }
}
