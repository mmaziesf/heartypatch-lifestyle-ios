import Foundation
import Observation
import HPLCore
import HPLBridge

/// Glasses-bridge wiring handed to the app.
public struct MealServices: Sendable {
    public let repository: any MealRepository
    public let secrets: any PairingSecretStore
    public init(repository: any MealRepository, secrets: any PairingSecretStore) { self.repository = repository; self.secrets = secrets }
}

/// Meals tab + glasses settings (§5.3, §8.4, §9.2). Platform-neutral so the flow is tested on Linux.
@MainActor @Observable
public final class MealsModel {
    public struct DayMeals: Identifiable, Equatable, Sendable {
        public var id: LocalDay { day }
        public var day: LocalDay
        public var meals: [MealLog]
    }

    public private(set) var pending: [MealLog] = []
    public private(set) var timeline: [DayMeals] = []
    public private(set) var state = BridgeState()
    public private(set) var notice: String?
    public private(set) var isImporting = false
    /// Shown once right after pairing (QR + link). Cleared when the sheet closes; the secret then lives only in the Keychain.
    public private(set) var newPairing: PairingPayload?
    public var onChange: (@MainActor () async -> Void)?

    private let services: MealServices?
    private let consents: any ConsentRepository
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(services: MealServices?, consents: any ConsentRepository, calendar: Calendar = .hplLocal(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.services = services; self.consents = consents; self.calendar = calendar; self.now = now
        reload()
    }

    public var isAvailable: Bool { services != nil }
    public var hasConsent: Bool { (try? consents.active(.glasses, version: GlassesConsent.version)) != nil }
    public var lastEventText: String {
        guard let at = state.lastEventAt else { return "No glasses events yet" }
        let mins = Int(now().timeIntervalSince(at) / 60)
        let ago = mins < 1 ? "just now" : mins < 60 ? "\(mins) min ago" : mins < 1440 ? "\(mins / 60) h ago" : "\(mins / 1440) d ago"
        return "Last event \(ago)" + (state.lastProducer.map { " from \($0)" } ?? "")
    }

    public func reload() {
        guard let repo = services?.repository else { return }
        _ = try? MealAssembler(repository: repo).closeStale(now: now())
        state = (try? repo.bridgeState()) ?? BridgeState()
        let all = (try? repo.meals()) ?? []
        pending = all.filter { $0.status == .pending }.sorted { $0.startedAt < $1.startedAt }
        let shown = all.filter { $0.status == .confirmed }
        timeline = Dictionary(grouping: shown) { LocalDay($0.startedAt, calendar: calendar) }
            .map { DayMeals(day: $0.key, meals: $0.value.sorted { $0.startedAt < $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    public func dismissNotice() { notice = nil }

    public func grantConsent() {
        do { try consents.save(Consent(scope: .glasses, version: GlassesConsent.version, grantedAt: now())) } catch { notice = "Could not save consent." }
    }

    // MARK: Review

    public func confirm(_ id: UUID) async { await update(id) { $0.status = .confirmed } }
    public func reject(_ id: UUID) async { await update(id) { $0.status = .rejected } }

    /// Edits the first item's name / kcal before confirming (the VLM's guess is only a starting point).
    public func edit(_ id: UUID, name: String, kcal: Double?) async {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty else { notice = "A meal needs a name."; return }
        await update(id) { m in
            if m.items.isEmpty { m.items = [MealItem(name: clean, kcalEst: kcal)] } else { m.items[0].name = clean; m.items[0].kcalEst = kcal }
        }
    }

    public func addManual(name: String, at date: Date, kcal: Double? = nil, tags: [MealTag] = []) async {
        guard let repo = services?.repository else { return }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty else { notice = "A meal needs a name."; return }
        let meal = MealLog(startedAt: date, endedAt: date, tz: calendar.timeZone.identifier, items: [MealItem(name: clean, kcalEst: kcal)],
                           tags: tags.map(\.rawValue), status: .confirmed, source: .manual, updatedAt: now())
        await persist { try repo.save(meal) }
    }

    public func delete(_ id: UUID) async {
        guard let repo = services?.repository else { return }
        await persist { try repo.deleteMeal(id: id) }
    }

    private func update(_ id: UUID, _ change: (inout MealLog) -> Void) async {
        guard let repo = services?.repository, var meal = (try? repo.meals())?.first(where: { $0.id == id }) else { return }
        change(&meal)
        meal.updatedAt = now()
        await persist { try repo.save(meal) }
    }

    private func persist(_ body: () throws -> Void) async {
        do { try body() } catch { notice = "Could not save the meal." }
        reload()
        await onChange?()
    }

    // MARK: Bridge

    public func importFile(_ data: Data) async {
        guard let services else { return }
        guard hasConsent else { notice = "Turn on glasses meals in Settings first."; return }
        isImporting = true
        defer { isImporting = false }
        let inbox = EventInbox(repository: services.repository, secrets: services.secrets, now: now)
        do {
            notice = MealsCopy.importSummary(try await inbox.importFile(data))
        } catch {
            notice = "Could not save imported events."
        }
        reload()
        await onChange?()
    }

    public func setPaused(_ paused: Bool) {
        guard let repo = services?.repository else { return }
        var s = (try? repo.bridgeState()) ?? BridgeState()
        s.paused = paused
        try? repo.save(s)
        reload()
    }

    public func pair(label: String) {
        guard let services else { return }
        guard hasConsent else { notice = "Turn on glasses meals first."; return }
        do {
            newPairing = try PairingManager(repository: services.repository, secrets: services.secrets)
                .pair(label: label.isEmpty ? "Glasses companion" : label, now: now())
        } catch {
            notice = "Could not store the pairing key."
        }
        reload()
    }

    public func finishPairing() { newPairing = nil }

    /// "ae21 6c2e" for a pairing row; compare with the code Glance shows after it pairs.
    public func codeText(for info: PairingInfo) -> String? {
        guard let services else { return nil }
        return PairingManager(repository: services.repository, secrets: services.secrets).code(for: info).map(PairingCode.display)
    }

    public func revoke(_ id: String) {
        guard let services else { return }
        do { try PairingManager(repository: services.repository, secrets: services.secrets).revoke(id: id) } catch { notice = "Could not remove the pairing." }
        reload()
    }
}

/// User-facing copy for the Meals tab. Describes what was imported; never what a meal means for health.
public enum MealsCopy {
    public static let emptyCopy = "Add a meal by hand, or import an .hplevent file from a paired glasses companion (Settings › Glasses meals)."

    public static func importSummary(_ r: EventInbox.Report) -> String {
        if r.rejected == [.paused] { return "The glasses bridge is paused. Nothing was imported." }
        var parts: [String] = []
        if r.applied > 0 { parts.append("\(r.applied) new event\(r.applied == 1 ? "" : "s") imported") }
        if r.duplicates > 0 { parts.append("\(r.duplicates) already imported") }
        if r.photosDropped > 0 { parts.append("\(r.photosDropped) photo\(r.photosDropped == 1 ? "" : "s") skipped (photos are off)") }
        let other = r.ignored - r.photosDropped
        if other > 0 { parts.append("\(other) not used by this version") }
        if !r.rejected.isEmpty { parts.append("\(r.rejected.count) rejected (\(reason(r.rejected[0])))") }
        return parts.isEmpty ? "The file had no events." : parts.joined(separator: " · ") + "."
    }

    public static func reason(_ r: EventInbox.Rejection) -> String {
        switch r {
        case .paused: "bridge paused"
        case .fileTooLarge, .tooManyLines, .bodyTooLarge: "file too large"
        case .malformedWrapper: "not a signed HPL event"
        case .unknownPairing: "not from a paired companion"
        case .badSignature: "signature check failed"
        case .stale: "older than 7 days"
        case .fromFuture: "timestamp in the future; check the clock"
        case .badEvent: "unreadable event"
        }
    }

    public static func processing(_ p: HPLEventV1.Producer.Processing?) -> String? {
        switch p {
        case .onDevice: "analyzed on your phone"
        case .cloud: "analyzed in the cloud"
        case nil: nil
        }
    }

    public static func detail(_ m: MealLog) -> String {
        var bits: [String] = []
        if m.items.count > 1 { bits.append("\(m.items.count) items") }
        if let k = m.kcalTotal { bits.append("about \(Int(k.rounded())) kcal (estimate)") }
        if m.source == .glasses { bits.append(["from \(m.producer ?? "glasses")", processing(m.processing)].compactMap { $0 }.joined(separator: ", ")) }
        if m.photosDropped > 0 { bits.append("photo skipped") }
        if m.isOpen { bits.append("still open") }
        return bits.joined(separator: " · ")
    }

    /// Local time of the meal in the zone it was eaten in (travel-safe), e.g. "7:42 PM".
    public static func time(_ m: MealLog, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = m.calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: m.startedAt)
    }

    public static func title(_ m: MealLog) -> String {
        m.items.first.map { m.items.count > 1 ? "\($0.name) +\(m.items.count - 1)" : $0.name } ?? "Meal (no items yet)"
    }
}
