#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
import SwiftUI
import UniformTypeIdentifiers
import HPLCore

public extension UTType {
    /// `.hplevent`: JSON Lines of hpl.signed_event.v1 (declared in project.yml as an exported type).
    static let hplEvent = UTType(exportedAs: "com.hpl.lifestyle.hplevent", conformingTo: .utf8PlainText)
}

public extension MealsModel {
    /// Reads a shared / opened `.hplevent` file (share sheet, Files, "Open in") and imports it.
    func importFile(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        await importFile(data)
    }
}

struct MealsView: View {
    var meals: MealsModel
    @State private var showImporter = false
    @State private var showManual = false
    @State private var editing: MealLog?

    var body: some View {
        List {
            if let notice = meals.notice {
                Section { Label(notice, systemImage: "info.circle").font(.footnote).onTapGesture { meals.dismissNotice() } }
            }
            Section {
                Label(meals.state.paused ? "Glasses bridge paused" : meals.lastEventText,
                      systemImage: meals.state.paused ? "pause.circle" : "eyeglasses").font(.footnote)
            }
            if !meals.pending.isEmpty {
                Section("To confirm") {
                    ForEach(meals.pending) { m in
                        PendingMealRow(meal: m, onConfirm: { Task { await meals.confirm(m.id) } },
                                       onEdit: { editing = m }, onReject: { Task { await meals.reject(m.id) } })
                    }
                }
            }
            if meals.timeline.isEmpty && meals.pending.isEmpty {
                ContentUnavailableView("No meals yet", systemImage: "fork.knife", description: Text(MealsCopy.emptyCopy))
            }
            ForEach(meals.timeline) { day in
                Section(day.day.description) {
                    ForEach(day.meals) { MealRow(meal: $0) }
                        .onDelete { idx in for i in idx { let id = day.meals[i].id; Task { await meals.delete(id) } } }
                }
            }
            Section {
                Text("Calories are rough estimates from your companion app's camera model, shown as it sent them.").font(.caption)
                Text(Disclaimer.footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Meals")
        .toolbar {
            Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .disabled(!meals.isAvailable || meals.isImporting)
            Button { showManual = true } label: { Label("Add", systemImage: "plus") }.disabled(!meals.isAvailable)
        }
        .onAppear { meals.reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.hplEvent, .json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task { await meals.importFile(at: url) }
        }
        .sheet(isPresented: $showManual) { NavigationStack { ManualMealSheet(meals: meals) } }
        .sheet(item: $editing) { m in NavigationStack { EditMealSheet(meals: meals, meal: m) } }
    }
}

struct PendingMealRow: View {
    let meal: MealLog
    let onConfirm: () -> Void
    let onEdit: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MealRow(meal: meal)
            HStack {
                Button("Confirm", action: onConfirm).buttonStyle(.borderedProminent)
                Button("Edit", action: onEdit).buttonStyle(.bordered)
                Spacer()
                Button("Not a meal", role: .destructive, action: onReject).buttonStyle(.borderless)
            }
            .font(.callout)
        }
    }
}

struct MealRow: View {
    let meal: MealLog

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(MealsCopy.title(meal)).bold()
                Spacer()
                Text(MealsCopy.time(meal)).font(.callout).foregroundStyle(.secondary)
            }
            let detail = MealsCopy.detail(meal)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if !meal.tags.isEmpty { Text(meal.tags.joined(separator: " · ")).font(.caption2) }
        }
    }
}

struct EditMealSheet: View {
    var meals: MealsModel
    let meal: MealLog
    @State private var name = ""
    @State private var kcal = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Calories (optional estimate)", text: $kcal)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            if meal.items.count > 1 { Text("Editing the first of \(meal.items.count) items.").font(.caption) }
        }
        .navigationTitle("Edit meal")
        .onAppear { name = meal.items.first?.name ?? ""; kcal = meal.items.first?.kcalEst.map { String(Int($0)) } ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save & confirm") {
                    Task {
                        await meals.edit(meal.id, name: name, kcal: Double(kcal))
                        await meals.confirm(meal.id)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ManualMealSheet: View {
    static let tagChoices: [MealTag] = [.homeCooked, .restaurant, .processed, .highProtein, .highFiber, .highSugar]
    var meals: MealsModel
    @State private var name = ""
    @State private var kcal = ""
    @State private var at = Date()
    @State private var tags: Set<MealTag> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("What did you eat?", text: $name)
            DatePicker("When", selection: $at)
            TextField("Calories (optional estimate)", text: $kcal)
            Section("Tags") {
                ForEach(Self.tagChoices, id: \.self) { tag in
                    Toggle(tag.rawValue, isOn: Binding(get: { tags.contains(tag) }, set: { on in if on { tags.insert(tag) } else { tags.remove(tag) } }))
                }
            }
        }
        .navigationTitle("Add meal")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task {
                        await meals.addManual(name: name, at: at, kcal: Double(kcal), tags: Self.tagChoices.filter { tags.contains($0) })
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Settings › Glasses: consent, pause, last event, photo policy, pairings (§8.4, §9.2).
struct GlassesSettingsSection: View {
    var meals: MealsModel
    @State private var label = ""

    var body: some View {
        Section("Glasses meals") {
            if !meals.hasConsent {
                ForEach(GlassesConsent.points, id: \.self) { Text($0).font(.caption) }
                Button("Turn on glasses meals") { meals.grantConsent(); meals.reload() }.disabled(!meals.isAvailable)
            } else {
                Toggle("Pause bridge", isOn: Binding(get: { meals.state.paused }, set: { meals.setPaused($0) }))
                LabeledContent("Status", value: meals.state.paused ? "Paused" : meals.lastEventText)
                LabeledContent("Photos", value: "Off (not imported in this version)")
                ForEach(meals.state.pairings) { p in
                    LabeledContent(p.label, value: "Paired \(p.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .swipeActions { Button("Remove", role: .destructive) { meals.revoke(p.id) } }
                }
                TextField("Companion name (e.g. Glance)", text: $label)
                Button("Pair a companion") { meals.pair(label: label); label = "" }
            }
        }
        .sheet(isPresented: Binding(get: { meals.newPairing != nil }, set: { if !$0 { meals.finishPairing() } })) {
            if let p = meals.newPairing { NavigationStack { PairingSheet(uri: p.uri, onDone: { meals.finishPairing() }) } }
        }
    }
}

struct PairingSheet: View {
    let uri: String
    let onDone: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan this code in your glasses companion app, or share the link to it. It contains the key the companion signs meals with.")
            if let image = QRCode.image(uri) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).frame(maxWidth: .infinity)
            }
            ShareLink(item: uri) { Label("Share pairing link", systemImage: "square.and.arrow.up") }
            Text("Treat it like a password. It's shown only now; to pair again later, create a new pairing.").font(.caption)
            Spacer()
        }
        .padding()
        .navigationTitle("Pair companion")
        .toolbar { Button("Done", action: onDone) }
    }
}
#endif
