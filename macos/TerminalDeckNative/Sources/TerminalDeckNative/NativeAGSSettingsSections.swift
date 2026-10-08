import SwiftUI

/// Add directly inside the existing Coding agents Settings page's grouped Form.
struct NativeAGSDefaultsSettingsSections: View {
    @State private var model = NativeAGSSettingsModel()

    var body: some View {
        Group {
            if model.loaded {
                NativeAGSDefaultsEditor(defaults: $model.defaults, busy: model.busy,
                    savedHooks: model.savedDefaults.hooks, testHook: { id in try await model.testHook(id) })
            } else if model.loading {
                Section("Agent defaults") {
                    VStack(alignment: .leading, spacing: 12) {
                        NativeSettingRow(label: "Model") { Text("Agent default").frame(width: 160) }
                        NativeSettingRow(label: "Thinking level") { Text("Agent default") }
                        NativeSettingRow(label: "Permission mode") { Text("Ask before changes") }
                    }.redacted(reason: .placeholder).accessibilityHidden(true)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading agent settings…").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if let problem = model.problem { NativeCodingAINotice(tone: .error, text: problem) }
                HStack(spacing: 8) {
                    Text(model.hasChanges && !model.busy ? "Unsaved agent settings" : model.status)
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 8)
                    Button(model.hasChanges ? "Discard and reload" : "Reload") {
                        Task { await model.load(discardDraft: true) }
                    }.disabled(model.busy)
                    if model.hasChanges {
                        Button("Discard changes") { model.discardChanges() }.disabled(model.busy)
                    }
                    Button(model.saving ? "Saving…" : "Save agent settings") {
                        Task { await model.save() }
                    }.disabled(!model.canSave)
                }
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}
