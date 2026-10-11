#if canImport(SwiftUI)
import SwiftUI
import HPLCore

public struct RootView: View {
    var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if model.needsDisclaimer {
            DisclaimerOnboardingView { model.acknowledgeDisclaimer() }
        } else {
            MainTabView(model: model)
        }
    }
}

struct DisclaimerOnboardingView: View {
    let onAcknowledge: () -> Void
    @State private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("HeartyPatch Lifestyle").font(.largeTitle.bold())
            Label(Disclaimer.title, systemImage: "exclamationmark.shield").font(.title2.bold())
            ScrollView { Text(Disclaimer.text).font(.body) }
            Toggle("I understand this is not medical advice", isOn: $understood)
            Button("Continue", action: onAcknowledge)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!understood)
        }
        .padding()
    }
}

struct MainTabView: View {
    var model: AppModel

    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") { NavigationStack { TodayView(model: model) } }
            Tab("Labs", systemImage: "testtube.2") { Placeholder(title: "Labs", detail: "Blood-work import with confirm-every-value arrives in M2.") }
            Tab("Meals", systemImage: "fork.knife") { Placeholder(title: "Meals", detail: "Manual + Ray-Ban (VisionClaw) meal logs arrive in M5.") }
            Tab("Insights", systemImage: "lightbulb") { Placeholder(title: "Insights", detail: "Recommendation history and experiments arrive in M4.") }
            Tab("Settings", systemImage: "gearshape") { NavigationStack { SettingsView(model: model) } }
        }
    }
}

struct TodayView: View {
    var model: AppModel

    var body: some View {
        List {
            if model.summary?.provenance == .syntheticFixture {
                Section {
                    Label(Disclaimer.syntheticDataBanner, systemImage: "flask")
                        .font(.footnote.bold())
                        .foregroundStyle(.orange)
                }
            }
            Section("Today's notes") {
                if model.recommendations.isEmpty {
                    Text("Nothing notable today.").foregroundStyle(.secondary)
                }
                ForEach(model.recommendations) { RecommendationRow(rec: $0) }
            }
            Section { Text(Disclaimer.footer).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Today")
        .task { await model.loadToday() }
    }
}

struct RecommendationRow: View {
    let rec: Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rec.kind.rawValue.replacingOccurrences(of: "_", with: " ").uppercased())
                .font(.caption2.bold()).foregroundStyle(.secondary)
            Text(rec.title).font(.headline)
            Text(rec.body).font(.subheadline)
            DisclosureGroup("Why am I seeing this?") {
                ForEach(rec.evidence, id: \.self) { e in
                    LabeledContent(e.fieldPath, value: e.value.display)
                        .font(.caption.monospaced())
                }
                Text("Engine: \(rec.generator.engine.rawValue) · \(rec.generator.promptVersion)").font(.caption2)
                Text(Disclaimer.footer).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct SettingsView: View {
    var model: AppModel

    var body: some View {
        Form {
            Section(Disclaimer.title) {
                Text(Disclaimer.text).font(.footnote)
                if let at = model.disclaimerAcknowledgedAt {
                    LabeledContent("Acknowledged", value: at.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Version", value: Disclaimer.version)
            }
            Section("Engine") { LabeledContent("Insights", value: "Rules only (\(model.engineName))") }
            Section("Data") {
                LabeledContent("Apple Health", value: "Not connected (M1)")
                LabeledContent("Cloud analysis", value: "Off")
            }
        }
        .navigationTitle("Settings")
    }
}

struct Placeholder: View {
    let title: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text(detail))
    }
}

extension JSONValue {
    var display: String {
        switch self {
        case .null: "—"
        case .bool(let b): String(b)
        case .number(let n): n.formatted(.number.precision(.fractionLength(0...2)))
        case .string(let s): s
        case .array(let a): a.map(\.display).joined(separator: ", ")
        case .object: "{…}"
        }
    }
}
#endif
