import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Tools (`ToolsSection.tsx`): the heading, then "Voice dictation" —
/// the transcription key (`VoiceKeyRow`) and why it is a key and not a model.
struct NativeToolsSettings: View {
    var body: some View {
        NativeSettingsPage(sectionId: "features") {
            Section(VoiceWords.groupTitle) {
                NativeVoiceKeyRow()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(VoiceWords.whyTitle).font(.headline)
                        NativeCodingAIInfo(label: VoiceWords.whyTitle, text: VoiceWords.whyMore)
                    }
                    Text(VoiceWords.whyText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// `VoiceKeyRow`: pick a service and paste its key (checked before it is kept), or,
/// once one is stored, which service it is and Remove key.
struct NativeVoiceKeyRow: View {
    @State private var model = VoiceKeyModel()

    var body: some View {
        Group {
            if let status = model.status, !status.canStore {
                NativeCodingAINotice(tone: .warn, text: status.reason ?? "")
            } else if let status = model.status, status.hasKey {
                NativeSettingRow(label: VoiceWords.storedLabel,
                                 help: VoiceWords.storedHelp(model.providers.first { $0.id == status.provider }),
                                 more: VoiceWords.storedMore) {
                    Button(VoiceWords.remove, role: .destructive) { model.forget() }
                        .disabled(model.working)
                }
            } else {
                NativeSettingRow(label: VoiceWords.serviceLabel, help: VoiceWords.serviceHelp) {
                    Picker(VoiceWords.serviceLabel, selection: $model.chosen) {
                        ForEach(model.providers) { Text($0.optionLabel).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let provider = model.provider {
                    NativeSettingRow(label: VoiceWords.keyLabel, help: provider.note, more: VoiceWords.keyMore) {
                        HStack(spacing: 6) {
                            SecureField("", text: $model.key, prompt: Text(VoiceWords.keyPlaceholder))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(width: 200)
                                .onSubmit { if !model.blank { model.save() } }
                            Button(VoiceWords.saveLabel(working: model.working)) { model.save() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.working || model.blank)
                                .help(VoiceWords.saveHelp(key: model.key))
                        }
                    }
                    if let get = provider.getKeyLabel, let url = URL(string: provider.keysUrl) {
                        Link(get, destination: url)
                    }
                }
                if let result = model.result {
                    NativeCodingAINotice(tone: result.ok ? .info : .error, text: result.text)
                }
            }
        }
        .onAppear { model.start() }
    }
}

@MainActor @Observable
final class VoiceKeyModel {
    var providers: [VoiceProvider] = []
    var status: VoiceStatus?
    var chosen = ""
    var key = ""
    var working = false
    var result: (ok: Bool, text: String)?

    var provider: VoiceProvider? { providers.first { $0.id == chosen } }
    var blank: Bool { key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func start() {
        Task {
            if let raw = try? await call("voice:providers") {
                providers = VoiceProvider.list(raw)
                if chosen.isEmpty, let first = providers.first { chosen = first.id }
            }
            await refresh()
        }
    }

    private func refresh() async {
        if let raw = try? await call("voice:status") { status = VoiceStatus.from(raw) }
    }

    func save() {
        working = true
        result = nil
        let request: [String: Any] = ["provider": chosen, "key": key]
        Task {
            if let raw = try? await call("voice:save", [request]) {
                let said = VoiceWords.saveResult(raw)
                result = said
                if said.ok {
                    key = ""
                    await refresh()
                    Self.tellThePage()
                }
            } else {
                result = (false, "That did not go through.")
            }
            working = false
        }
    }

    func forget() {
        working = true
        Task {
            _ = try? await call("voice:forget")
            result = nil
            await refresh()
            Self.tellThePage()
            working = false
        }
    }

    /// The voice feature follows the key: the Settings page's `VoiceFeatureSync` reads again.
    private static func tellThePage() {
        _ = NativeCodingAIPages.evaluate("(function(){try{window.dispatchEvent(new CustomEvent('td:voice-changed'));return true}catch(e){return false}})()",
                                         in: .settings)
    }
}
