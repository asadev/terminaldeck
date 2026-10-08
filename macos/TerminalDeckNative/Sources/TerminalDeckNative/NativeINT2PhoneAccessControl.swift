import SwiftUI
import TerminalDeckNativeCore

struct NativeINT2PhoneAccessControl: View {
    let deviceID: String
    @State private var level = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Phone access", selection: Binding(get: { level }, set: { selected in Task { await save(selected) } })) {
                if level.isEmpty { Text("Choose access…").tag("") }
                Text("Look only").tag("look")
                Text("Work").tag("work")
                Text("Full control").tag("full")
            }.pickerStyle(.menu).disabled(loading || saving)
            if loading || saving { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.task { await load() }
    }
    private func apply(_ raw: Any) throws {
        let rows = try NativeRPCValue.fromFoundation(raw).requireArray("Device access")
        level = rows.first { $0["id"].string == deviceID }?["access"].string ?? ""
    }
    private func load() async {
        defer { loading = false }
        do { try apply(await EngineBridge.shared.invoke("remote:device-access", [])); error = nil }
        catch { self.error = deckMessage(error) }
    }
    private func save(_ selected: String) async {
        guard ["look", "work", "full"].contains(selected) else { return }
        saving = true; defer { saving = false }
        do { try apply(await EngineBridge.shared.invoke("remote:device-access:set", [deviceID, selected])); error = nil }
        catch { self.error = deckMessage(error) }
    }
}
