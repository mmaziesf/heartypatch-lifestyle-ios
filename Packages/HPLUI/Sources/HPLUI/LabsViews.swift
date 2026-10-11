#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
import SwiftUI
import UniformTypeIdentifiers
import HPLCore
import HPLIngest

struct LabsView: View {
    static let emptyCopy = "Import a PDF or photo of a report. Reading happens on this iPhone, and you confirm every value before it's saved."
    var labs: LabsModel
    @State private var showImporter = false

    var body: some View {
        List {
            if let notice = labs.notice {
                Section { Label(notice, systemImage: "info.circle").font(.footnote) }
            }
            if labs.panels.isEmpty {
                ContentUnavailableView("No lab results yet", systemImage: "testtube.2",
                                       description: Text(Self.emptyCopy))
            }
            ForEach(labs.panels) { item in
                Section("Collected \(item.panel.collectedOn.description)") {
                    ForEach(item.results) { LabResultRow(result: $0) }
                }
            }
            Section {
                Text("Values are shown as printed on your report. HP Lifestyle doesn't interpret them.").font(.caption)
                Text(Disclaimer.footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Labs")
        .toolbar {
            Button { showImporter = true } label: { Label("Import", systemImage: "plus") }
                .disabled(!labs.isAvailable || labs.isImporting)
        }
        .overlay { if labs.isImporting { ProgressView("Reading report on device…") } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            Task { await importFile(url) }
        }
        .sheet(isPresented: Binding(get: { labs.review != nil }, set: { if !$0 { Task { await labs.cancelReview() } } })) {
            NavigationStack { LabReviewView(labs: labs) }.interactiveDismissDisabled()
        }
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
        await labs.importFile(data, kind: isPDF ? .pdf : .image, fileExtension: url.pathExtension.isEmpty ? "bin" : url.pathExtension)
    }
}

struct LabResultRow: View {
    let result: LabResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(result.analyteRaw)
                Spacer()
                Text(LabsModel.valueText(result.valueNumeric, result.valueText, unit: result.unitRaw)).bold()
            }
            Text(LabsModel.rangeText(low: result.refLow, high: result.refHigh, text: result.refText)).font(.caption).foregroundStyle(.secondary)
            if let flag = LabsModel.flagText(result.flagFromReport) { Text(flag).font(.caption) }
            if result.analyteCanonical == nil { Text("Not in dictionary: kept, but not used in daily notes").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct LabReviewView: View {
    var labs: LabsModel
    @State private var editing: ReviewRow?

    var body: some View {
        Form {
            if let review = labs.review {
                Section("Collection date") {
                    DatePicker("Collected", selection: Binding(
                        get: { review.collectedOn?.start(in: .hplLocal()) ?? Date() },
                        set: { labs.setCollectedOn($0) }), displayedComponents: .date)
                    if review.collectedOn == nil {
                        Text("No collection date found on the report. Set it before saving.").font(.caption).foregroundStyle(.orange)
                    } else if review.collectedOnFromReport {
                        Text("Found on the report. Change it if it's wrong.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Check each row against your report. Confirm, fix, or reject every one. \(review.pendingCount) left.")
                        .font(.footnote)
                    if review.identifierLinesDropped > 0 {
                        Text("\(review.identifierLinesDropped) identifier lines (name, date of birth, IDs…) were skipped and not stored.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(review.rows) { row in
                    Section { ReviewRowView(row: row, labs: labs, onEdit: { editing = row }) }
                }
            }
        }
        .navigationTitle("Confirm values")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Task { await labs.cancelReview() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await labs.saveReview() } }.disabled(!(labs.review?.canSave ?? false))
            }
        }
        .sheet(item: $editing) { row in NavigationStack { EditRowView(row: row, labs: labs) } }
    }
}

struct ReviewRowView: View {
    let row: ReviewRow
    var labs: LabsModel
    let onEdit: () -> Void

    var body: some View {
        let c = row.candidate
        VStack(alignment: .leading, spacing: 6) {
            Text("As printed (page \(c.page)): \(c.sourceText)").font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Text(c.analyte?.name ?? c.analyteRaw).bold()
                Spacer()
                Text(LabsModel.valueText(c.valueNumeric, c.valueText, unit: c.unitRaw))
            }
            Text(LabsModel.rangeText(low: c.refLow, high: c.refHigh, text: c.refText)).font(.caption)
            if let flag = LabsModel.flagText(c.flag) { Text(flag).font(.caption) }
            if c.analyteKey == nil { Text("Not in dictionary").font(.caption2).foregroundStyle(.orange) }
            switch row.decision {
            case .pending:
                HStack {
                    Button("Confirm") { labs.confirm(row.id) }.buttonStyle(.borderedProminent)
                    Button("Edit", action: onEdit).buttonStyle(.bordered)
                    Button("Reject", role: .destructive) { labs.reject(row.id) }.buttonStyle(.bordered)
                }
            case .confirmed:
                HStack {
                    Label(row.edited ? "Edited and confirmed" : "Confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Undo") { labs.reopen(row.id) }
                }
            case .rejected:
                HStack {
                    Label("Rejected (won't be saved)", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { labs.reopen(row.id) }
                }
            }
        }
        .buttonStyle(.borderless)
    }
}

struct EditRowView: View {
    let row: ReviewRow
    var labs: LabsModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var unit = ""
    @State private var analyteKey: String?
    @State private var invalid = false

    var body: some View {
        Form {
            Section("As printed") { Text(row.candidate.sourceText).font(.caption.monospaced()) }
            Section("Corrected value") {
                TextField("Value", text: $value)
                unitField
                Picker("Test", selection: $analyteKey) {
                    Text("Not in dictionary").tag(String?.none)
                    ForEach(AnalyteDictionary.all.sorted { $0.name < $1.name }, id: \.key) { Text($0.name).tag(Optional($0.key)) }
                }
                if invalid { Text("Enter a number or a result like Negative.").font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Edit value")
        .onAppear(perform: load)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm") {
                    if labs.edit(row.id, value: value, unit: unit, analyteKey: analyteKey) { dismiss() } else { invalid = true }
                }
            }
        }
    }

    @ViewBuilder private var unitField: some View {
        #if os(iOS)
        TextField("Unit", text: $unit).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        TextField("Unit", text: $unit).autocorrectionDisabled()
        #endif
    }

    private func load() {
        value = row.candidate.valueText ?? row.candidate.valueNumeric.map(LabParser.fmt) ?? ""
        unit = row.candidate.unitRaw
        analyteKey = row.candidate.analyteKey
    }
}
#endif
