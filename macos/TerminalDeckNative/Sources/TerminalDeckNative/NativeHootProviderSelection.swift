import SwiftUI

struct NativeHootProviderSelection: View {
    @State private var provider = "claude"
    @State private var ready = false
    @State private var pending = false
    @State private var restart = false
    @State private var error: String?
    var body: some View {
        Section {
            Picker("Agent", selection: $provider) {
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
                Text("Gemini").tag("gemini")
            }.disabled(!ready || pending)
            if restart { Text("Restart the app to use this agent. Each agent keeps its own conversation and account.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task {
            do {
                let value = try await EngineBridge.shared.invoke("hoot:provider:read") as? [String: Any]
                provider = value?["provider"] as? String ?? "claude"
                restart = value?["restartRequired"] as? Bool ?? false
                ready = true
            } catch { self.error = error.localizedDescription }
        }.onChange(of: provider) { _, selected in
            guard ready, !pending else { return }
            pending = true
            Task {
                defer { pending = false }
                do {
                    let value = try await EngineBridge.shared.invoke("hoot:provider:select", [selected]) as? [String: Any]
                    restart = value?["restartRequired"] as? Bool ?? false; error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
