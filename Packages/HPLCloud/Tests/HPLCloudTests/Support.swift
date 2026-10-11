import Foundation
import HPLCore
import HPLStore
@testable import HPLCloud

let la = Calendar.hplLocal(TimeZone(identifier: "America/Los_Angeles")!)
let anchor = LocalDay(string: "2026-10-10")!
let fixedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func consented() throws -> InMemoryConsentRepository {
    let r = InMemoryConsentRepository()
    try r.save(Consent(scope: .cloudAnalysis, version: CloudConsent.version, grantedAt: Date(timeIntervalSince1970: 0)))
    return r
}

func summary(_ day: LocalDay, sleep: Int? = 420, rhr: Double? = 55, steps: Int? = 8000, meals: [DailySummaryV1.Meal] = [],
             workouts: [DailySummaryV1.Workout] = [], labs: [DailySummaryV1.LabRecent] = [], profile: DailySummaryV1.Profile? = nil,
             bed: String? = "23:10", provenance: DailySummaryV1.Provenance = .device) -> DailySummaryV1 {
    DailySummaryV1(provenance: provenance, day: day.description, dayOfWeek: day.weekdayAbbrev(calendar: la), profile: profile,
                   sleep: .init(totalMin: sleep, bedLocal: bed, wakeLocal: "07:05"), heart: .init(restingHR: rhr, hrvSDNNOvernightMedian: 45),
                   activity: .init(steps: steps, activeKcal: 400, exerciseMin: 22), workouts: workouts, meals: meals, labsRecent: labs, completeness: 1)
}

func window(_ n: Int, _ make: (Int, LocalDay) -> DailySummaryV1) -> CloudWindow {
    CloudWindow(anchor: anchor, summaries: (0..<n).map { make($0, anchor.adding(days: -$0, calendar: la)) }, calendar: la)
}

/// Wraps a transport and records every body it is given.
final class RecordingTransport: CloudTransport, @unchecked Sendable {
    let id = "recording"
    let leavesDevice = true
    private let lock = NSLock()
    private var bodies: [Data] = []
    let respond: @Sendable (Data) throws -> Data
    init(respond: @escaping @Sendable (Data) throws -> Data = { body in
        let payload = try JSONDecoder().decode(CloudPayloadV1.self, from: body)
        return try JSONEncoder().encode(DemoCloudAnalyzer.analyze(payload))
    }) { self.respond = respond }
    var received: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    func post(_ body: Data, requestID: String) async throws -> Data {
        lock.withLock { bodies.append(body) }
        return try respond(body)
    }
}

struct Boom: Error {}
