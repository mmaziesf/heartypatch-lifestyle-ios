#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import HPLCore

/// Settings › Daily reminder (one local notification a day, no health content).
struct ReminderSection: View {
    var reminders: ReminderModel

    var body: some View {
        Section {
            Toggle("Daily reminder", isOn: Binding(get: { reminders.settings.enabled }, set: { on in Task { await reminders.setEnabled(on) } }))
            if reminders.settings.enabled {
                DatePicker("Time", selection: Binding(get: { time }, set: { setTime($0) }), displayedComponents: .hourAndMinute)
            }
            if let notice = reminders.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Notifications")
        } footer: {
            Text(ReminderCopy.explainer)
        }
        .disabled(!reminders.isAvailable)
    }

    private var time: Date {
        Calendar.current.date(from: DateComponents(hour: reminders.settings.hour, minute: reminders.settings.minute)) ?? Date()
    }

    private func setTime(_ d: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        Task { await reminders.setTime(hour: c.hour ?? 8, minute: c.minute ?? 0) }
    }
}

/// Settings › Privacy & your data: what's stored, export all, delete all (§9.2, §10).
struct YourDataSection: View {
    var model: AppModel
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var exportDocument: JSONExportDocument?

    var body: some View {
        Section {
            NavigationLink("How your data is handled") { PrivacyDetailView() }
            Button("Export all data (JSON)") {
                if let data = try? model.exportAllJSON() { exportDocument = JSONExportDocument(data: data); exporting = true }
            }
            Button(model.isWiping ? "Deleting…" : "Delete all data", role: .destructive) { confirmDelete = true }
                .disabled(!model.canDeleteAll || model.isWiping)
        } header: {
            Text("Privacy & your data")
        } footer: {
            Text(PrivacyCopy.exportExplainer)
        }
        .confirmationDialog(PrivacyCopy.deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all data", role: .destructive) { Task { await model.deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PrivacyCopy.deleteMessage)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "hpl-export") { _ in
            exportDocument = nil
        }
    }
}

struct PrivacyDetailView: View {
    var body: some View {
        List {
            Section { ForEach(PrivacyCopy.points, id: \.self) { Text($0) } }
            Section { Text(PrivacyCopy.deleteHealthAccess).font(.footnote) }
        }
        .navigationTitle("Your data")
    }
}

/// Settings › Consents: every consent with its copy version, granted / revoked dates (§9.2).
struct ConsentsSection: View {
    var model: AppModel

    var body: some View {
        Section("Consents") {
            let history = model.consentHistory
            if history.isEmpty { Text("None recorded.").foregroundStyle(.secondary) }
            ForEach(history) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(PrivacyCopy.scopeLabel(c.scope))
                    Text(line(c)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func line(_ c: Consent) -> String {
        let granted = "v\(c.version) · given \(c.grantedAt.formatted(date: .abbreviated, time: .omitted))"
        guard let r = c.revokedAt else { return granted }
        return granted + " · turned off \(r.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: AppInfo.versionString)
            Text("HP Lifestyle is a personal wellness app. It is not a medical device.").font(.caption)
        }
    }
}

public enum AppInfo {
    public static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// Covers the screen in the app switcher and while inactive so health numbers don't show in snapshots (§10).
public struct PrivacyShieldView: View {
    public init() {}
    public var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Label("HP Lifestyle", systemImage: "heart.text.square").font(.title2.bold())
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
#endif
