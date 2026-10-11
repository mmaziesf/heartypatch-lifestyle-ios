#if canImport(SwiftUI)
import SwiftUI
import HPLCore
import HPLPipeline

public struct RootView: View {
    var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if model.needsDisclaimer {
            DisclaimerOnboardingView { model.acknowledgeDisclaimer() }
        } else if model.needsHealthPrompt {
            HealthConnectView(onConnect: { Task { await model.connectHealth() } }, onSkip: { model.dismissHealthPrompt() })
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

struct HealthConnectView: View {
    let onConnect: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Connect Apple Health", systemImage: "heart.text.square").font(.title.bold())
            Text("HP Lifestyle reads sleep, heart, activity, body, and workout data to build daily summaries on this iPhone.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Read-only. Nothing is written to Health.", systemImage: "eye")
                Label("Only per-day totals are stored, in an encrypted on-device store.", systemImage: "lock")
                Label("Nothing leaves this device.", systemImage: "iphone")
            }
            .font(.subheadline)
            Spacer()
            Button("Connect Apple Health", action: onConnect).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("Not now", action: onSkip).frame(maxWidth: .infinity)
        }
        .padding()
    }
}

struct MainTabView: View {
    var model: AppModel

    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") { NavigationStack { TodayView(model: model) } }
            Tab("Labs", systemImage: "testtube.2") { NavigationStack { LabsView(labs: model.labs) } }
            Tab("Meals", systemImage: "fork.knife") { Placeholder(title: "Meals", detail: "Manual + Ray-Ban (VisionClaw) meal logs arrive in M5.") }
            Tab("Insights", systemImage: "lightbulb") { NavigationStack { InsightsView(insights: model.insights) } }
            Tab("Settings", systemImage: "gearshape") { NavigationStack { SettingsView(model: model) } }
        }
    }
}

struct TodayView: View {
    static let noDataHelp = "Apple Health doesn't tell apps whether access was denied. "
        + "Check Settings › Health › Data Access & Devices › HP Lifestyle, and make sure your Apple Watch has synced."
    var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            HealthStatusSection(model: model)
            switch model.todaySource {
            case .syntheticFixture:
                Section {
                    Label(Disclaimer.syntheticDataBanner, systemImage: "flask")
                        .font(.footnote.bold())
                        .foregroundStyle(.orange)
                }
            case .noData:
                Section {
                    ContentUnavailableView {
                        Label("No data (or access not granted)", systemImage: "heart.slash")
                    } description: {
                        Text(Self.noDataHelp)
                    } actions: {
                        Button("Open Health") { if let url = URL(string: "x-apple-health://") { openURL(url) } }
                    }
                }
            case .device:
                EmptyView()
            }
            if model.todaySource != .noData {
                Section(model.todaySource == .device ? "Today vs your 28-day typical" : "Example metrics") {
                    ForEach(model.todayMetrics) { MetricRowView(row: $0) }
                }
                if let active = model.insights.activeExperiment {
                    Section("Your experiment") { ExperimentCard(experiment: active, insights: model.insights) }
                }
                Section("Today's notes") {
                    if let notice = model.insights.notice {
                        Label(notice, systemImage: "info.circle").font(.footnote)
                    }
                    if model.insights.today.isEmpty {
                        Text("Nothing notable today.").foregroundStyle(.secondary)
                    }
                    ForEach(model.insights.today) { NoteCard(note: $0, insights: model.insights) }
                    if model.insights.isExample {
                        Text("Example notes: actions here aren't saved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section { Text(Disclaimer.footer).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Today")
        .refreshable { await model.refresh() }
        .task { await model.loadToday() }
    }
}

struct HealthStatusSection: View {
    var model: AppModel

    var body: some View {
        switch model.healthStatus {
        case .notConnected:
            Section {
                Button { Task { await model.connectHealth() } } label: {
                    Label("Connect Apple Health to see your own data", systemImage: "heart.text.square")
                }
            }
        case .syncing(let progress):
            Section {
                if let progress {
                    ProgressView("Reading the last 90 days from Apple Health…", value: progress)
                } else {
                    ProgressView("Updating from Apple Health…")
                }
            }
        case .ready(let last?):
            Section { Text("Updated \(last.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        case .failed:
            Section { Label(model.errorMessage ?? "Apple Health sync failed.", systemImage: "exclamationmark.triangle").font(.footnote) }
        case .ready(nil), .unavailable:
            EmptyView()
        }
    }
}

struct MetricRowView: View {
    let row: MetricRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                Spacer()
                Text(row.value ?? "No data").bold().foregroundStyle(row.value == nil ? .secondary : .primary)
            }
            if let typical = row.typical {
                Text("Typical: \(typical)").font(.caption).foregroundStyle(.secondary)
            }
            if let note = row.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
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
            Section("Engine") {
                LabeledContent("Insights", value: model.engineStatus)
                Text("Notes are written on this device from your daily summary only, then checked by fixed safety rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
            EvalSection(model: model)
            #endif
            Section("Data") {
                LabeledContent("Apple Health", value: healthLabel)
                if model.healthStatus == .notConnected {
                    Button("Connect Apple Health") { Task { await model.connectHealth() } }
                }
                LabeledContent("Stored", value: "Per-day totals only, on this device")
                LabeledContent("Cloud analysis", value: "Off")
            }
        }
        .navigationTitle("Settings")
        .task { await model.refreshEngineStatus() }
    }

    private var healthLabel: String {
        switch model.healthStatus {
        case .unavailable: "Not available on this device"
        case .notConnected: "Not connected"
        case .syncing: "Syncing…"
        case .ready(let last?): "Connected · \(last.formatted(date: .abbreviated, time: .shortened))"
        case .ready(nil): "Connected"
        case .failed: "Sync failed"
        }
    }
}

#if DEBUG
/// Developer-only: score the live engine on the synthetic eval set (architecture §11 M3 gate) and record latency on this device.
struct EvalSection: View {
    var model: AppModel

    var body: some View {
        Section("Developer: insight eval") {
            Button(model.isRunningEval ? "Running…" : "Run on \(EvalFixtures.count) synthetic days") { Task { await model.runInsightEval() } }
                .disabled(model.isRunningEval)
            if let r = model.evalReport {
                LabeledContent("Engine", value: "\(r.engineID) · \(r.promptVersion)")
                LabeledContent("Gate", value: r.meetsM3Gate ? "PASS" : r.gateFailures.joined(separator: "; "))
                LabeledContent("Schema-valid", value: r.schemaValidRate.formatted(.percent))
                LabeledContent("Numbers traceable", value: r.numericTraceableRate.formatted(.percent))
                LabeledContent("Fallbacks / blocked / rewritten", value: "\(r.fallbacks) / \(r.draftsBlocked) / \(r.notesRewritten)")
                LabeledContent("Latency median / p90", value: latency(r))
            }
        }
    }

    private func latency(_ r: EvalHarness.Report) -> String {
        guard let median = r.medianLatencyMs, let p90 = r.p90LatencyMs else { return "n/a" }
        return "\(Int(median)) ms / \(Int(p90)) ms"
    }
}
#endif

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
