// RagVectorIndex.swift — форматы хранения векторного индекса (JSON и flat-бинарный).
//
// «Индекс» тут — плотная матрица векторов в порядке чанков (строка i ↔ chunk.ordinal i).
// Бэкенды различаются только ФОРМАТОМ на диске; поиск top-K одинаков для всех и живёт
// в Vector.topK (brute-force косинус — семантика FAISS IndexFlatL2). Так честно: у нас
// нет C++-FAISS, зато есть тот же алгоритм без внешних зависимостей.
//
//   • JSONVectorIndex — [[Float]] через JSONEncoder (как остальные сторы приложения).
//   • FlatVectorIndex — компактный бинарный файл (magic+version+count+dim + Float32 LE).
//   • SQLiteVectorIndex — в отдельном файле RagSQLiteIndex.swift (импортирует C-API).
//
// Роутинг бэкендов и запись каталога индекса — в RagStore. Здесь только save/load.

import Foundation

/// Ошибки чтения/записи индекса (понятные для UI).
enum VectorIndexError: LocalizedError {
    case badFormat(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badFormat(let s): return "Повреждённый формат индекса: \(s)"
        case .io(let s):        return "Ошибка ввода-вывода индекса: \(s)"
        }
    }
}

/// Формат хранения векторного индекса. Каждый бэкенд знает имя своего файла в каталоге
/// rag/<id>/ и умеет атомарно сохранить/загрузить матрицу векторов.
protocol VectorIndexStore {
    var backend: IndexBackend { get }
    /// Имя файла индекса внутри каталога индекса.
    var fileName: String { get }
    func save(_ vectors: [[Float]], to dir: URL) throws
    func load(from dir: URL) throws -> [[Float]]
}

// MARK: - JSON

/// Векторы как JSON-массив массивов. Самый простой и «родной» приложению формат.
struct JSONVectorIndex: VectorIndexStore {
    let backend: IndexBackend = .json
    let fileName = "vectors.json"

    func save(_ vectors: [[Float]], to dir: URL) throws {
        let data = try JSONEncoder().encode(vectors)
        try RagFileIO.writeAtomic(data, to: dir.appendingPathComponent(fileName))
    }

    func load(from dir: URL) throws -> [[Float]] {
        let url = dir.appendingPathComponent(fileName)
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([[Float]].self, from: data)
        } catch let e as DecodingError {
            throw VectorIndexError.badFormat("\(e)")
        } catch {
            throw VectorIndexError.io(error.localizedDescription)
        }
    }
}

// MARK: - Flat (бинарный, аналог FAISS IndexFlatL2)

/// Компактный бинарный формат: заголовок «RAGF» + version(UInt32) + count(UInt32) +
/// dim(UInt32), затем count·dim значений Float32 (little-endian). Плотная матрица —
/// один непрерывный блок, как в FAISS IndexFlatL2. Все целые/дробные — LE, чтобы файл
/// был переносим независимо от порядка байт платформы.
struct FlatVectorIndex: VectorIndexStore {
    let backend: IndexBackend = .flat
    let fileName = "vectors.flat"

    private static let magic: [UInt8] = Array("RAGF".utf8)
    private static let headerSize = 16   // 4 magic + 4 version + 4 count + 4 dim

    func save(_ vectors: [[Float]], to dir: URL) throws {
        let count = vectors.count
        let dim = vectors.first?.count ?? 0
        var data = Data()
        data.append(contentsOf: Self.magic)
        RagFileIO.appendUInt32(&data, 1)                 // version
        RagFileIO.appendUInt32(&data, UInt32(count))
        RagFileIO.appendUInt32(&data, UInt32(dim))
        data.reserveCapacity(Self.headerSize + count * dim * 4)
        for v in vectors {
            for i in 0..<dim {
                RagFileIO.appendFloat32(&data, i < v.count ? v[i] : 0)
            }
        }
        try RagFileIO.writeAtomic(data, to: dir.appendingPathComponent(fileName))
    }

    func load(from dir: URL) throws -> [[Float]] {
        let url = dir.appendingPathComponent(fileName)
        let bytes: [UInt8]
        do { bytes = [UInt8](try Data(contentsOf: url)) }
        catch { throw VectorIndexError.io(error.localizedDescription) }

        guard bytes.count >= Self.headerSize else {
            throw VectorIndexError.badFormat("файл короче заголовка")
        }
        guard Array(bytes[0..<4]) == Self.magic else {
            throw VectorIndexError.badFormat("неверная сигнатура")
        }
        let count = Int(RagFileIO.readUInt32(bytes, 8))
        let dim = Int(RagFileIO.readUInt32(bytes, 12))
        let expected = Self.headerSize + count * dim * 4
        guard bytes.count >= expected else {
            throw VectorIndexError.badFormat("ожидалось \(expected) байт, есть \(bytes.count)")
        }

        var result: [[Float]] = []
        result.reserveCapacity(count)
        var offset = Self.headerSize
        for _ in 0..<count {
            var v = [Float](repeating: 0, count: dim)
            for i in 0..<dim {
                v[i] = RagFileIO.readFloat32(bytes, offset)
                offset += 4
            }
            result.append(v)
        }
        return result
    }
}

// MARK: - Низкоуровневый ввод-вывод (общий для форматов)

/// Атомарная запись + LE-сериализация примитивов. Отдельно, чтобы FlatVectorIndex и
/// SQLiteVectorIndex не дублировали побайтовую логику.
enum RagFileIO {
    static func writeAtomic(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw VectorIndexError.io(error.localizedDescription)
        }
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func appendFloat32(_ data: inout Data, _ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    static func readFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: readUInt32(b, o))
    }
}
