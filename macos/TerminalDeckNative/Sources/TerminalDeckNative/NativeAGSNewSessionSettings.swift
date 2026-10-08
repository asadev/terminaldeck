import SwiftUI
import TerminalDeckNativeCore

/// Only the owner-native dialog gets these private values. They never travel
/// through the retained page's JavaScript start request or remembered settings.
struct NativeAGSNewSessionSettings: View {
    let provider: String, accountID: String?, folder: String
    @Binding var settings: AGSAgentSettings?
    var busy = false
    @State private var names: [String] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var ready = false
    @State private var loadGeneration = 0
    private var identity: String { provider + "\n" + (accountID ?? "") + "\n" + folder }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ready, settings != nil {
                NativeAGSAgentSettingsEditor(settings: Binding(get: { settings ?? AGSAgentSettings(provider: provider) }, set: { settings = $0 }), busy: busy, availableMCPServers: names)
            } else if loading { NativePageNote("Checking the selected account's agent settings…", busy: true) }
            else if let problem { NativeCodingAINotice(tone: .error, text: problem) }
        }
        .task(id: identity) {
            loadGeneration += 1
            let mine = loadGeneration
            ready = false; loading = true; problem = nil; settings = nil
            defer { if mine == loadGeneration { loading = false } }
            do {
                let request: [String: Any] = ["provider": provider, "profileId": accountID as Any? ?? NSNull(), "cwd": folder]
                let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:session-settings", [request]))
                try Task.checkCancellation()
                guard mine == loadGeneration else { return }
                guard raw["canOverride"].bool == true else { throw NativeRPCError(code: "unavailable", message: "This host has not connected private agent settings to session launch.") }
                let value = try JSONDecoder().decode(AGSAgentSettings.self, from: raw["settings"].encodedJSON())
                guard value.provider == provider else { throw NativeRPCError.malformed("The settings belong to a different coding agent.") }
                names = raw["serverNames"].elements?.compactMap(\.string) ?? []
                settings = value; ready = true
            } catch is CancellationError { /* A newer selected account owns the next load. */ }
            catch { guard mine == loadGeneration else { return }; problem = CodingAIErrorText.from(error, fallback: "Private agent settings could not be checked for this account.") }
        }
    }
}

@MainActor
enum NativeAGSPrivateSessionStart {
    /// ags:session-start must be a retained native owner channel; it has no Node/page fallback implementation.
    static func start(_ request: NewSessionRequest, settings: AGSAgentSettings) async throws -> NativeRPCValue {
        var payload = request.json
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        payload["agentSettings"] = raw
        return try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:session-start", [payload]))
    }
}
