import Foundation
import HPLCore

/// In-memory labs for previews, tests, and Linux. Enforces the confirmed-only rule like the SwiftData store.
public final class InMemoryLabRepository: LabRepository, @unchecked Sendable {
    private var docs: [UUID: SourceDocument] = [:]
    private var panelRows: [UUID: LabPanel] = [:]
    private var resultRows: [UUID: [LabResult]] = [:]
    private let lock = NSLock()

    public init() {}

    public func document(sha256: String) throws -> SourceDocument? {
        lock.lock(); defer { lock.unlock() }
        return docs.values.first { $0.sha256 == sha256 }
    }

    public func documents() throws -> [SourceDocument] {
        lock.lock(); defer { lock.unlock() }
        return docs.values.sorted { $0.importedAt < $1.importedAt }
    }

    public func saveDocument(_ doc: SourceDocument) throws { lock.lock(); defer { lock.unlock() }; docs[doc.id] = doc }

    public func saveConfirmed(panel: LabPanel, results: [LabResult]) throws {
        guard results.allSatisfy(\.userConfirmed) else { throw LabRepositoryError.unconfirmedResult }
        lock.lock(); defer { lock.unlock() }
        panelRows[panel.id] = panel
        resultRows[panel.id] = results
        if let id = panel.sourceDocumentID { docs[id]?.status = .confirmed }
    }

    public func panels() throws -> [LabPanel] {
        lock.lock(); defer { lock.unlock() }
        return panelRows.values.sorted { $0.collectedOn > $1.collectedOn }
    }

    public func results(panelID: UUID) throws -> [LabResult] { lock.lock(); defer { lock.unlock() }; return resultRows[panelID] ?? [] }

    public func deleteAll() throws { lock.lock(); defer { lock.unlock() }; docs = [:]; panelRows = [:]; resultRows = [:] }
}
