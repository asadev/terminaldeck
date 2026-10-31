import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

struct NativeINT2PhoneAccessControl: View {
    let deviceID: String
    /// Every row's level comes from one read by its screen (#404): nil while that read runs or after it failed.
    let level: String?
    var problem: String?
    let save: (String) async throws -> Void
    @State private var saving = false
    @State private var error: String?

    private var known: String { level.flatMap(BackendINT2PhoneAccessLevel.init(rawValue:))?.rawValue ?? "" }
    private var loading: Bool { level == nil && problem == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Device access", selection: Binding(get: { known }, set: { selected in Task { await apply(selected) } })) {
                if known.isEmpty { Text("Choose access…").tag("") }
                ForEach(BackendINT2PhoneAccessLevel.offered, id: \.self) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.menu).labelsHidden().fixedSize().disabled(level == nil || saving)
            if loading || saving { ProgressView().controlSize(.small) }
            if let message = error ?? problem ?? (known.isEmpty && level?.isEmpty == false ? "The device returned an unknown access level. Try again." : nil) {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func apply(_ selected: String) async {
        guard BackendINT2PhoneAccessLevel(rawValue: selected) != nil else {
            error = "Choose " + BackendINT2PhoneAccessLevel.offered.map(\.title).joined(separator: ", ") + "."
            return
        }
        saving = true; defer { saving = false }
        do { try await save(selected); error = nil }
        catch { self.error = deckMessage(error) }
    }

    /// The whole access list, read once for every row.
    static func read() async throws -> [String: String] {
        try levels(await EngineBridge.shared.invoke("remote:device-access", []))
    }
    /// Saves one device's level; the answer is the whole list again.
    static func write(_ deviceID: String, _ level: String) async throws -> [String: String] {
        try levels(await EngineBridge.shared.invoke("remote:device-access:set", [deviceID, level]))
    }
    static func levels(_ raw: Any) throws -> [String: String] {
        let rows = try NativeRPCValue.fromFoundation(raw).requireArray("Device access")
        return Dictionary(rows.compactMap { row in row["id"].string.map { ($0, row["access"].string ?? "") } }, uniquingKeysWith: { first, _ in first })
    }
}
