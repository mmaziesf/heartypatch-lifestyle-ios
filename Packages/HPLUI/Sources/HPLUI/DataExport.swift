import Foundation
import HPLCore
import HPLCloud

/// `hpl.export_all.v1`: everything this app stores about you, as one JSON file you keep (Settings › Export all data).
/// Built on device; the file goes wherever you save or share it. Report files and pairing secrets are not included.
public struct AllDataExport: Encodable, Sendable {
    public static let schemaID = "hpl.export_all.v1"

    public struct Panel: Encodable, Sendable {
        public var panel: LabPanel
        public var results: [LabResult]
    }

    public var schema = Self.schemaID
    public var exportedAt: Date
    public var note = "Exported from HP Lifestyle on this device. Not medical advice. Lab values are as printed on your reports."
    public var consents: [Consent]
    public var healthAggregates: [HealthAggregate]
    public var labDocuments: [SourceDocument]
    public var labPanels: [Panel]
    public var meals: [MealLog]
    public var notes: [StoredNote]
    public var experiments: [Experiment]
    public var cloudEgress: [EgressRecord]

    enum CodingKeys: String, CodingKey {
        case schema, exportedAt = "exported_at", note, consents, healthAggregates = "health_aggregates", labDocuments = "lab_documents"
        case labPanels = "lab_panels", meals, notes, experiments, cloudEgress = "cloud_egress"
    }

    public struct Sources: Sendable {
        public var consents: any ConsentRepository
        public var aggregates: (any HealthAggregateRepository)?
        public var labs: (any LabRepository)?
        public var meals: (any MealRepository)?
        public var insights: (any InsightsRepository)?
        public var egress: (any EgressLog)?
    }

    /// Aggregates from 2000-01-01 through `now`'s day (HealthKit backfill is 90 days, so this is everything stored).
    public static func make(_ s: Sources, now: Date, calendar: Calendar) throws -> AllDataExport {
        let today = LocalDay(now, calendar: calendar)
        let panels = try (s.labs?.panels() ?? []).sorted { $0.collectedOn > $1.collectedOn }
        return AllDataExport(
            exportedAt: now, consents: try s.consents.all(),
            healthAggregates: try s.aggregates?.aggregates(from: LocalDay(year: 2000, month: 1, day: 1), through: today) ?? [],
            labDocuments: try s.labs?.documents() ?? [],
            labPanels: try panels.map { Panel(panel: $0, results: try s.labs?.results(panelID: $0.id) ?? []) },
            meals: try s.meals?.meals() ?? [], notes: try s.insights?.notes() ?? [], experiments: try s.insights?.experiments() ?? [],
            cloudEgress: try s.egress?.all() ?? [])
    }

    public func encoded() throws -> Data {
        let e = HPLJSON.encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }
}
