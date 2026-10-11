import Foundation
import Testing
@testable import HPLCore

@Suite struct DataWipeTests {
    @Test func directoryTargetEmptiesButKeepsTheDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hpl-wipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.pdf"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("nested/b.hplevent"))
        let t = DirectoryWipeTarget(name: "files", directory: dir)
        #expect(try await t.remaining() == 2)
        let report = await DataWiper(targets: [t]).wipeAll()
        #expect(report.verified && report.items == [.init(name: "files", remaining: 0, error: nil)])
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func missingDirectoryCountsAsClean() async throws {
        let t = DirectoryWipeTarget(name: "inbox", directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(await DataWiper(targets: [t]).wipeAll().verified)
    }

    @Test func oneFailingTargetDoesNotStopTheOthersAndIsReported() async throws {
        struct Boom: Error {}
        let box = Box()
        let failing = ClosureWipeTarget(name: "keychain", wipe: { throw Boom() }, remaining: { 1 })
        let unverifiable = ClosureWipeTarget(name: "prefs", wipe: {}, remaining: { throw Boom() })
        let fine = ClosureWipeTarget(name: "db", wipe: { box.clear() }, remaining: { box.count })
        let report = await DataWiper(targets: [failing, unverifiable, fine]).wipeAll(now: Date(timeIntervalSince1970: 0))
        #expect(!report.verified)
        #expect(report.items.map(\.isClean) == [false, false, true])
        #expect(report.items[0].error == "wipe failed" && report.items[1].error == "could not verify" && box.isEmpty)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 3
    var count: Int { lock.withLock { n } }
    var isEmpty: Bool { lock.withLock { n <= 0 } }
    func clear() { lock.withLock { n = 0 } }
}
