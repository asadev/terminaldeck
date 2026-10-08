import SwiftUI
import TerminalDeckNativeCore

/// Private values stay in this owner-native view, never in the retained page's
/// session request. The current host refuses unverified launch overrides.
struct NativeINT2AGSSessionSettings: View {
    let provider: String
    @State private var settings: AGSAgentSettings?
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let settings {
                NativeAGSAgentSettingsEditor(settings: .constant(settings), busy: true, availableMCPServers: [])
            } else if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            else { NativePageNote("Reading inherited agent settings…", busy: true) }
            Text("Private session overrides are unavailable until this host connects the selected CLI's help, complete MCP settings and private launch lease. Unconfigured sessions still use their existing settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: provider) {
            settings = nil; problem = nil
            do {
                let value = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:session-settings", [provider]))
                settings = try JSONDecoder().decode(AGSAgentSettings.self, from: value["settings"].encodedJSON())
            } catch { problem = "Inherited agent settings could not be read. " + error.localizedDescription }
        }
    }
}
