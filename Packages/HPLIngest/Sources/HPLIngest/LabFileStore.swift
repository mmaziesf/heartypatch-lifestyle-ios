import Foundation

/// Where imported report files live. The original is kept only inside the app's protected container (§5.2, §10).
public protocol LabFileStore: Sendable {
    func store(_ data: Data, name: String) throws
    func read(name: String) throws -> Data
    func delete(name: String) throws
}

/// `Application Support/HPL/Documents`, NSFileProtectionComplete on iOS, excluded from nothing (backup policy is M7).
public struct ProtectedLabFileStore: LabFileStore {
    public let directory: URL

    public init(directory: URL? = nil) throws {
        let fm = FileManager.default
        let dir = try directory ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HPL/Documents", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        #endif
        self.directory = dir
    }

    public func store(_ data: Data, name: String) throws {
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        #endif
    }

    public func read(name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    public func delete(name: String) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
}

public final class InMemoryLabFileStore: LabFileStore, @unchecked Sendable {
    private var files: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public var names: [String] { lock.lock(); defer { lock.unlock() }; return files.keys.sorted() }
    public func store(_ data: Data, name: String) throws { lock.lock(); defer { lock.unlock() }; files[name] = data }
    public func read(name: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let d = files[name] else { throw CocoaError(.fileNoSuchFile) }
        return d
    }
    public func delete(name: String) throws { lock.lock(); defer { lock.unlock() }; files[name] = nil }
}
