import Foundation
import Testing
import HPLCore
@testable import HPLBridge

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

@Suite struct EventInboxTests {
    func load(_ path: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(path)) }

    @Test func acceptsDedupesAndIgnoresUnknown() async throws {
        let inbox = EventInbox()
        guard case .accepted(let e) = await inbox.ingest(try load("events/01-meal-start.synthetic.json")) else { Issue.record("accept"); return }
        #expect(e.type == .mealStart)
        #expect(await inbox.ingest(try load("events/01-meal-start.synthetic.json")) == .duplicate(eventID: e.eventID))
        #expect(await inbox.ingest(try load("events/06-unknown-type.synthetic.json")) == .ignoredUnknownType("future.thing"))
    }

    @Test func rejectsBadPayload() async throws {
        guard case .rejected = await EventInbox().ingest(try load("invalid/event-meal-start-bad-trigger.json")) else { Issue.record("reject"); return }
    }

    @Test func rejectsGarbage() async {
        guard case .rejected = await EventInbox().ingest(Data("{}".utf8)) else { Issue.record("reject"); return }
    }
}
