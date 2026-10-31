import SwiftUI
import TerminalDeckNativeCore

/// Permission is requested only by this person's click. Loading this row is
/// a noninteractive read, so it cannot put a Keychain alert on their screen.
struct NativeAccountVaultRecovery: View {
    typealias Invoke = @MainActor (String) async throws -> [String: Any]
    @Bindable var store: NativeCodingAIStore
    var invoke: Invoke = { channel in
        try await EngineBridge.shared.invoke(channel, []) as? [String: Any] ?? [:]
    }
    @State private var loading = true
    @State private var needsPermission = false
    @State private var pending = false
    @State private var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading {
                ProgressView("Reading login store…").controlSize(.small)
            } else if needsPermission {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail ?? "Click Allow login store. If the Mac asks, click Always Allow so the app and its background helper can open your saved logins.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(pending ? "Opening login store…" : "Allow login store") {
                        pending = true
                        Task { @MainActor in
                            defer { pending = false }
                            do {
                                let raw = try await invoke("profiles:vault-recover")
                                needsPermission = raw["needsPermission"] as? Bool ?? true
                                detail = raw["detail"] as? String
                                store.reloadAccounts()
                            } catch { detail = CodingAIErrorText.from(error, fallback: "The login store could not be opened. Click Allow login store to try again.") }
                        }
                    }
                    .disabled(pending)
                }
            }
        }
        .task {
            defer { loading = false }
            do {
                let raw = try await invoke("profiles:vault-status")
                needsPermission = raw["needsPermission"] as? Bool ?? false
                detail = raw["detail"] as? String
            } catch {
                needsPermission = true
                detail = CodingAIErrorText.from(error, fallback: "Click Allow login store to try opening your saved logins again.")
            }
        }
    }
}
