#if canImport(SwiftUI)
import SwiftUI
import HPLCore
import HPLCloud

/// Settings › Cloud analysis: off by default; turning it on shows the consent copy first (§9.2).
struct CloudSettingsSection: View {
    var cloud: CloudModel
    @State private var showConsent = false
    @State private var consented = false

    var body: some View {
        Section("Cloud analysis") {
            if consented {
                LabeledContent("Status", value: "On")
                LabeledContent("Analyzer", value: cloud.transportLabel)
                NavigationLink("Run an analysis") { CloudAnalysisView(cloud: cloud) }
                Button("Turn off cloud analysis", role: .destructive) { cloud.revokeConsent(); consented = cloud.hasConsent }
            } else {
                LabeledContent("Status", value: "Off")
                Button("Turn on cloud analysis…") { showConsent = true }
            }
        }
        .onAppear { consented = cloud.hasConsent }
        .sheet(isPresented: $showConsent) {
            NavigationStack {
                CloudConsentSheet(onAccept: {
                    cloud.grantConsent()
                    consented = cloud.hasConsent
                    showConsent = false
                }, onCancel: { showConsent = false })
            }
        }
    }
}

struct CloudConsentSheet: View {
    let onAccept: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        List {
            Section {
                ForEach(CloudConsent.points, id: \.self) { Text($0).font(.callout) }
            }
            Section {
                Button("I understand, turn it on") { onAccept() }
                Button("Not now", role: .cancel) { onCancel() }
            }
        }
        .navigationTitle("Cloud analysis")
    }
}

/// Choose → preview (sections + exact JSON + SHA-256) → Send / Cancel → results and history.
struct CloudAnalysisView: View {
    @Bindable var cloud: CloudModel

    var body: some View {
        List {
            switch cloud.phase {
            case .idle, .failed:
                options
            case .preparing:
                Section { ProgressView("Preparing…") }
            case .preview(let job):
                preview(job, sending: false)
            case .sending(let job):
                preview(job, sending: true)
            case .done(let result):
                results(result)
            }
            if !cloud.history.isEmpty { history }
        }
        .navigationTitle("Cloud analysis")
    }

    @ViewBuilder private var options: some View {
        Section {
            Picker("Window", selection: $cloud.policy.windowDays) {
                ForEach(AnonymizationPolicy.allowedWindows, id: \.self) { Text("\($0) days").tag($0) }
            }
            Toggle("Include meal times and tags", isOn: $cloud.policy.includeMeals)
            Toggle("Include common lab values (rounded)", isOn: $cloud.policy.includeLabs)
            Button("Prepare preview") { Task { await cloud.prepare() } }
        } footer: {
            Text(cloud.transportLabel)
        }
        if case .failed(let message) = cloud.phase {
            Section { Text(message).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private func preview(_ job: PreparedJob, sending: Bool) -> some View {
        Section {
            Text(CloudCopy.previewNote).font(.callout)
            if cloud.usingExample { Text(CloudCopy.exampleNote).font(.caption).foregroundStyle(.orange) }
        }
        ForEach(job.preview.sections, id: \.title) { s in
            Section(s.title) { ForEach(Array(s.lines.enumerated()), id: \.offset) { Text($0.element).font(.caption) } }
        }
        Section("Exact JSON (\(job.preview.bytes) bytes)") {
            ScrollView(.horizontal) { Text(job.preview.json).font(.caption2.monospaced()).textSelection(.enabled) }
            LabeledContent("SHA-256") { Text(job.preview.sha256).font(.caption2.monospaced()).textSelection(.enabled) }
        }
        Section {
            Button(sending ? "Sending…" : "Send") { Task { await cloud.send() } }.disabled(sending)
            Button("Cancel", role: .cancel) { cloud.cancel() }.disabled(sending)
        }
    }

    @ViewBuilder private func results(_ result: CloudResult) -> some View {
        Section {
            Text(CloudCopy.resultsNote).font(.caption)
            if result.blocked > 0 { Text("\(result.blocked) result(s) didn't pass the safety rules and were hidden.").font(.caption) }
        }
        ForEach(result.recommendations) { rec in
            Section(NoteCopy.kindLabel(rec.kind)) {
                Text(rec.title).font(.headline)
                Text(rec.body).font(.subheadline)
                ForEach(rec.evidence, id: \.fieldPath) { e in
                    LabeledContent(e.fieldPath, value: e.summaryDay).font(.caption2)
                }
            }
        }
        Section { Button("Done") { cloud.cancel() } }
    }

    private var history: some View {
        Section("History (on this device)") {
            ForEach(cloud.history) { r in
                NavigationLink {
                    ScrollView { Text(r.payloadJSON).font(.caption2.monospaced()).textSelection(.enabled).padding() }
                        .navigationTitle("Payload")
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(r.at.formatted(date: .abbreviated, time: .shortened)) · \(r.outcome.rawValue) · \(r.bytes) bytes")
                        Text("\(r.leftDevice ? "Left the device" : "Stayed on device") · \(r.accepted) shown, \(r.blocked) hidden")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
#endif
