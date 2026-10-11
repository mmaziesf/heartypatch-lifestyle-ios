#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import HPLCore
import HPLPipeline

// MARK: Today

struct NoteCard: View {
    let note: StoredNote
    var insights: InsightsModel

    private var rec: Recommendation { note.recommendation }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(NoteCopy.kindLabel(rec.kind)).font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if let badge = NoteCopy.statusBadge(note.status) {
                    Text(badge).font(.caption2.bold()).foregroundStyle(.tint)
                }
            }
            Text(rec.title).font(.headline)
            Text(rec.body).font(.subheadline)
            if let e = rec.experiment {
                Label(NoteCopy.proposal(e), systemImage: "flask").font(.caption).foregroundStyle(.secondary)
            }
            if note.status == .new { actions }
            NavigationLink("Why am I seeing this?") { EvidenceView(note: note) }
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if insights.canStartExperiment(note), let e = rec.experiment {
                Button("Start \(e.durationDays)-day experiment") { insights.startExperiment(from: note) }
                    .buttonStyle(.borderedProminent)
            } else if rec.kind != .clinicianPrompt {
                Button("Got it") { insights.accept(note) }.buttonStyle(.bordered)
            }
            Button("Dismiss", role: .destructive) { insights.dismiss(note) }.buttonStyle(.bordered)
            Menu {
                if rec.kind != .clinicianPrompt { Button("Snooze until tomorrow") { insights.snooze(note) } }
                Button("Helpful") { insights.feedback(note, .helpful) }
                Button("Not helpful") { insights.feedback(note, .notHelpful) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }
}

/// "Why am I seeing this?" (§9.2): the exact summary values the note used, how it was written, and the disclaimer.
struct EvidenceView: View {
    let note: StoredNote
    private var rec: Recommendation { note.recommendation }

    var body: some View {
        List {
            Section {
                Text(rec.title).font(.headline)
                Text(rec.body)
            }
            Section("Based on these values from \(note.day.description)") {
                ForEach(rec.evidence, id: \.self) { e in
                    let label = FieldLabels.label(for: e.fieldPath)
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(label.name, value: e.value.display + (label.unit.map { " \($0)" } ?? ""))
                        Text(e.fieldPath).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            if let e = rec.experiment {
                Section("Experiment idea") {
                    LabeledContent("Change", value: e.intervention)
                    LabeledContent("Length", value: "\(e.durationDays) days")
                    LabeledContent("Compared on", value: FieldLabels.label(for: e.metricFieldPath).name)
                    Text("Compares the \(e.durationDays) days before you start with the \(e.durationDays) days of the experiment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("How this note was written") {
                LabeledContent("Written by", value: NoteCopy.engine(rec.generator))
                LabeledContent("Version", value: rec.generator.promptVersion)
                Text(NoteCopy.guardExplanation(rec)).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(Disclaimer.text).font(.footnote)
            } header: { Text(Disclaimer.title) }
        }
        .navigationTitle("Why this note")
    }
}

struct ExperimentCard: View {
    let experiment: Experiment
    var insights: InsightsModel

    var body: some View {
        let p = insights.progress(experiment)
        VStack(alignment: .leading, spacing: 8) {
            Text("EXPERIMENT · DAY \(p.day) OF \(p.of)").font(.caption2.bold()).foregroundStyle(.secondary)
            Text(experiment.intervention).font(.headline)
            ProgressView(value: Double(p.day), total: Double(p.of))
            Text(ExperimentCopy.progressLine(experiment, p))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(p.today == true ? "Did it ✓" : "Did it today") { insights.checkIn(experiment, did: true) }
                    .buttonStyle(.borderedProminent).disabled(p.today == true)
                Button(p.today == false ? "Skipped ✓" : "Skipped today") { insights.checkIn(experiment, did: false) }
                    .buttonStyle(.bordered).disabled(p.today == false)
                Spacer()
                Menu { Button("Stop experiment", role: .destructive) { insights.stop(experiment) } } label: { Image(systemName: "ellipsis.circle") }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Insights tab

struct InsightsView: View {
    @Bindable var insights: InsightsModel
    @State private var exporting = false
    @State private var exportDocument: JSONExportDocument?

    var body: some View {
        List {
            if let notice = insights.notice {
                Section { Label(notice, systemImage: "info.circle").font(.footnote) }
            }
            if insights.isExample {
                Section { Label("Showing example notes. Connect Apple Health to build your own history.", systemImage: "flask")
                    .font(.footnote).foregroundStyle(.orange) }
            }
            experimentsSection
            Section {
                Picker("Show", selection: $insights.filter) {
                    ForEach(InsightsModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if insights.historyByDay.isEmpty {
                Section { Text("No notes here yet.").foregroundStyle(.secondary) }
            }
            ForEach(insights.historyByDay) { group in
                Section(group.day.description) {
                    ForEach(group.notes) { note in
                        NavigationLink { EvidenceView(note: note) } label: { HistoryRow(note: note) }
                    }
                }
            }
            Section { Text(Disclaimer.footer).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Insights")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export JSON", systemImage: "square.and.arrow.up") {
                    if let data = try? insights.exportJSON() { exportDocument = JSONExportDocument(data: data); exporting = true }
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "hpl-insights-\(insights.todayDay.description)") { _ in exportDocument = nil }
    }

    @ViewBuilder private var experimentsSection: some View {
        if let active = insights.activeExperiment {
            Section("Running") { ExperimentCard(experiment: active, insights: insights) }
        }
        if !insights.pastExperiments.isEmpty {
            Section("Finished experiments") {
                ForEach(insights.pastExperiments) { ExperimentResultRow(experiment: $0) }
            }
        }
    }
}

struct HistoryRow: View {
    let note: StoredNote
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(NoteCopy.kindLabel(note.recommendation.kind)).font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(NoteCopy.statusBadge(note.status) ?? "New").font(.caption2).foregroundStyle(.secondary)
            }
            Text(note.recommendation.title).font(.subheadline)
        }
    }
}

struct ExperimentResultRow: View {
    let experiment: Experiment
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(experiment.intervention).font(.headline)
            Text("\(experiment.startDay.description) → \(experiment.endedOn?.description ?? "…") · \(experiment.status.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
            if let r = experiment.result { Text(r.summary).font(.subheadline) }
        }
    }
}

struct JSONExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
