import Foundation

/// One place "Delete all" must clear (§10): the database, files, Keychain items, preferences, scheduled notifications.
/// `remaining()` re-reads after the wipe so the result is verified, not assumed.
public protocol WipeTarget: Sendable {
    var name: String { get }
    func wipe() async throws
    /// Items still present (0 = verified empty).
    func remaining() async throws -> Int
}

/// Ad-hoc target from closures (preferences, notifications, Keychain on Apple platforms).
public struct ClosureWipeTarget: WipeTarget {
    public let name: String
    let wipeBody: @Sendable () async throws -> Void
    let remainingBody: @Sendable () async throws -> Int
    public init(name: String, wipe: @escaping @Sendable () async throws -> Void, remaining: @escaping @Sendable () async throws -> Int) {
        self.name = name; wipeBody = wipe; remainingBody = remaining
    }
    public func wipe() async throws { try await wipeBody() }
    public func remaining() async throws -> Int { try await remainingBody() }
}

/// Removes everything inside a directory (the directory itself stays, keeping its file-protection class).
public struct DirectoryWipeTarget: WipeTarget {
    public let name: String
    public let directory: URL
    public init(name: String, directory: URL) { self.name = name; self.directory = directory }

    public func wipe() async throws {
        let fm = FileManager.default
        for url in contents() { try fm.removeItem(at: url) }
    }

    public func remaining() async throws -> Int { contents().count }

    private func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}

public struct WipeReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var name: String
        /// `nil` when the count couldn't be read.
        public var remaining: Int?
        public var error: String?
        public var isClean: Bool { remaining == 0 && error == nil }
    }

    public var at: Date
    public var items: [Item]
    /// Every target wiped without error and re-read as empty.
    public var verified: Bool { items.allSatisfy(\.isClean) }
}

/// Runs every target even if one fails, then verifies each. HealthKit itself is never touched (it isn't ours).
public struct DataWiper: Sendable {
    public let targets: [any WipeTarget]
    public init(targets: [any WipeTarget]) { self.targets = targets }

    public func wipeAll(now: Date = Date()) async -> WipeReport {
        var items: [WipeReport.Item] = []
        for t in targets {
            var failure: String?
            do { try await t.wipe() } catch { failure = "wipe failed" }
            let left = try? await t.remaining()
            items.append(.init(name: t.name, remaining: left, error: failure ?? (left == nil ? "could not verify" : nil)))
        }
        return WipeReport(at: now, items: items)
    }
}
