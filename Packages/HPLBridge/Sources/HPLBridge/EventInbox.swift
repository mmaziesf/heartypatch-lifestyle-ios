import Foundation
import HPLCore

/// The Glasses Bridge inbox (architecture §8.2–8.4, docs/m5-glasses.md).
/// Input is an `.hplevent` file: JSON Lines of `hpl.signed_event.v1` wrappers, from the share sheet / Files import
/// (transport A). Every line is verified against its pairing's secret before its body is even decoded.
public actor EventInbox {
    public struct Policy: Sendable {
        public var maxFileBytes = 1_048_576
        public var maxLines = 1_000
        /// A file can sit in a share sheet or a synced folder for a while: accept signatures up to this old…
        public var maxAge: TimeInterval = 7 * 24 * 3600
        /// …but never from further in the future than normal clock skew (§8.2: 5 min).
        public var maxFutureSkew: TimeInterval = 5 * 60
        public init() {}
    }

    public enum Rejection: Sendable, Equatable {
        case paused, fileTooLarge, tooManyLines, malformedWrapper, bodyTooLarge, unknownPairing, badSignature, stale, fromFuture
        case badEvent(String)
    }

    public enum Outcome: Sendable, Equatable {
        case applied(eventID: String, type: String)
        case duplicate(eventID: String)
        case ignored(eventID: String, EventReceipt.Disposition)
        case rejected(line: Int, Rejection)
    }

    public struct Report: Sendable, Equatable {
        public var outcomes: [Outcome] = []
        public var applied: Int { outcomes.filter { if case .applied = $0 { true } else { false } }.count }
        public var duplicates: Int { outcomes.filter { if case .duplicate = $0 { true } else { false } }.count }
        public var ignored: Int { outcomes.filter { if case .ignored = $0 { true } else { false } }.count }
        public var rejected: [Rejection] { outcomes.compactMap { if case .rejected(_, let r) = $0 { r } else { nil } } }
        public var photosDropped: Int { outcomes.filter { if case .ignored(_, .droppedPhoto) = $0 { true } else { false } }.count }
    }

    let repository: any MealRepository
    let secrets: any PairingSecretStore
    let policy: Policy
    let now: @Sendable () -> Date

    public init(repository: any MealRepository, secrets: any PairingSecretStore, policy: Policy = Policy(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository; self.secrets = secrets; self.policy = policy; self.now = now
    }

    /// Imports one `.hplevent` file. Lines are verified first, then applied in `occurred_at` order so sessions assemble
    /// even if the producer wrote them out of order. Never throws for bad input; storage errors do throw.
    public func importFile(_ data: Data) throws -> Report {
        var report = Report()
        var state = try repository.bridgeState()
        guard !state.paused else { return Report(outcomes: [.rejected(line: 0, .paused)]) }
        guard data.count <= policy.maxFileBytes else { return Report(outcomes: [.rejected(line: 0, .fileTooLarge)]) }
        let lines = (String(bytes: data, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.enumerated().filter { !$0.element.isEmpty }
        guard lines.count <= policy.maxLines else { return Report(outcomes: [.rejected(line: 0, .tooManyLines)]) }

        var verified: [(event: HPLEventV1, pairing: String)] = []
        let pairings = Set(state.pairings.map(\.id))
        for (index, line) in lines {
            switch verify(line, knownPairings: pairings) {
            case .success(let v): verified.append(v)
            case .failure(let r): report.outcomes.append(.rejected(line: index + 1, r.rejection))
            }
        }

        let at = now()
        let assembler = MealAssembler(repository: repository)
        for (event, pairing) in verified.sorted(by: { ($0.event.occurredAt, $0.event.eventID) < ($1.event.occurredAt, $1.event.eventID) }) {
            if try repository.receipt(eventID: event.eventID) != nil {
                report.outcomes.append(.duplicate(eventID: event.eventID))
                continue
            }
            let disposition = try assembler.apply(event, now: at)
            try repository.save(EventReceipt(eventID: event.eventID, type: event.type.rawValue, occurredAt: event.occurredAt, receivedAt: at,
                                             pairingID: pairing, producer: event.producer.name, disposition: disposition))
            report.outcomes.append(disposition == .applied ? .applied(eventID: event.eventID, type: event.type.rawValue)
                                                           : .ignored(eventID: event.eventID, disposition))
            state.lastEventAt = max(state.lastEventAt ?? event.occurredAt, event.occurredAt)
            state.lastProducer = event.producer.name
        }
        try assembler.closeStale(now: at)
        if !verified.isEmpty { try repository.save(state) }
        return report
    }

    struct Failure: Error { let rejection: Rejection }

    private func verify(_ line: String, knownPairings: Set<String>) -> Result<(event: HPLEventV1, pairing: String), Failure> {
        guard let wrapper = try? JSONDecoder().decode(SignedEvent.self, from: Data(line.utf8)), wrapper.spec == SignedEvent.specID,
              PairingPayload.isValidID(wrapper.pairingID) else { return .failure(Failure(rejection: .malformedWrapper)) }
        guard wrapper.body.utf8.count <= SignedEvent.maxBodyBytes else { return .failure(Failure(rejection: .bodyTooLarge)) }
        guard knownPairings.contains(wrapper.pairingID), let secret = try? secrets.secret(for: wrapper.pairingID) else {
            return .failure(Failure(rejection: .unknownPairing))
        }
        guard wrapper.verifies(secret: secret) else { return .failure(Failure(rejection: .badSignature)) }
        let age = now().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(wrapper.ts)))
        if age > policy.maxAge { return .failure(Failure(rejection: .stale)) }
        if -age > policy.maxFutureSkew { return .failure(Failure(rejection: .fromFuture)) }
        do {
            let event = try HPLJSON.decoder.decode(HPLEventV1.self, from: Data(wrapper.body.utf8))
            _ = try event.typedPayload()
            if event.occurredAt.timeIntervalSince(now()) > policy.maxFutureSkew { return .failure(Failure(rejection: .fromFuture)) }
            if event.type.isSessionMeal, event.sessionID == nil { return .failure(Failure(rejection: .badEvent("missing session_id"))) }
            return .success((event, wrapper.pairingID))
        } catch {
            return .failure(Failure(rejection: .badEvent("decode")))
        }
    }
}

extension HPLEventV1.EventType {
    var isSessionMeal: Bool { [.mealStart, .mealItems, .mealPhoto, .mealEnd].contains(self) }
}
