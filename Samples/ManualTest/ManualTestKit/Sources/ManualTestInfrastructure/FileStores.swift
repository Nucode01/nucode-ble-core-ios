import Foundation
import ManualTestDomain

// MARK: 파일 저장소. 파일 보호는 끈다: 재부팅 뒤 첫 잠금 해제 전 복원 재실행(점검 9)에서도 등록을 읽고 기록을 써야 한다

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

enum StoreFiles {
    /// Application Support/ManualTest. 없으면 보호 없는 폴더로 만든다
    static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "ManualTest", directoryHint: .isDirectory)
    }

    static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
    }

    static var attributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.none]
        #else
        nil
        #endif
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .noFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

/// JSON Lines. 한 줄에 `LogEntry` 하나. 깨진 줄은 건너뛴다
public final class FileEventLogStore: EventLogStore {
    let url: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        url = (directory ?? StoreFiles.defaultDirectory()).appending(path: "events.jsonl")
    }

    public func load() throws -> [LogEntry] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let decoder = JSONDecoder()
            return try String(decoding: Data(contentsOf: url), as: UTF8.self)
                .split(separator: "\n")
                .compactMap { try? decoder.decode(LogEntry.self, from: Data($0.utf8)) }
        }
    }

    public func append(_ entry: LogEntry) throws {
        var line = try JSONEncoder().encode(entry)
        line.append(0x0A)
        try lock.withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                try StoreFiles.ensureDirectory(url.deletingLastPathComponent())
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: StoreFiles.attributes) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    public func clear() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// 점검표 결과 JSON. 키는 항목 번호 문자열
public struct FileChecklistStore: ChecklistStore {
    let url: URL

    public init(directory: URL? = nil) {
        url = (directory ?? StoreFiles.defaultDirectory()).appending(path: "checklist.json")
    }

    public func load() throws -> [Int: ChecklistResult] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let raw = try JSONDecoder().decode([String: ChecklistResult].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    public func save(_ results: [Int: ChecklistResult]) throws {
        let raw = Dictionary(uniqueKeysWithValues: results.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try StoreFiles.writeAtomically(encoder.encode(raw), to: url)
    }
}

/// 앱 시작 등록 JSON. nil 이면 파일을 지운다
public struct FileRegistrationStore: RegistrationStore {
    let url: URL

    public init(directory: URL? = nil) {
        url = (directory ?? StoreFiles.defaultDirectory()).appending(path: "registration.json")
    }

    public func load() throws -> DeviceRegistration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DeviceRegistration.self, from: Data(contentsOf: url))
    }

    public func save(_ registration: DeviceRegistration?) throws {
        guard let registration else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try StoreFiles.writeAtomically(JSONEncoder().encode(registration), to: url)
    }
}
