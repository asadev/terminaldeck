import Foundation
import Observation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// One file watch for every open chat. Settings and MCP renames both write this existing account file.
@MainActor @Observable
final class NativeChatAccountNames {
    static let shared = NativeChatAccountNames()
    private var accounts: [String: CodingAIAccount] = [:]
    /// R9 (6 Nov): who is signed in to each unnamed login, read once per change of the account file.
    private var signIns: [String: CodingAISignIn] = [:]
    @ObservationIgnored private var watch: BackendHootFileWatch?
    @ObservationIgnored private var revision = 0

    func start() async {
        guard watch == nil, let root = NativeCompositionRoot.shared.backend?.dataRoot else { return }
        watch = BackendHootFileWatch(files: [root.appendingPathComponent("profiles.json")]) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        await reload()
    }
    private func reload() async {
        revision += 1
        let mine = revision
        guard let raw = try? await EngineBridge.shared.invoke("profiles:list"), mine == revision else { return }
        let list = CodingAIAccountsParse.snapshot(CodingAIJSON(raw)).accounts
        accounts = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Only an unnamed login is called by its address; a chosen name needs no sign-in check.
        var read: [String: CodingAISignIn] = [:]
        for account in list where !CodingAIAccountLabels.hasChosenName(account) && !account.isAPIKey {
            guard let value = try? await EngineBridge.shared.invoke("profiles:signin", [account.id, ["refresh": false]]) else { continue }
            read[account.id] = CodingAIAccountsParse.signIn(CodingAIJSON(value))
        }
        guard mine == revision else { return }
        signIns = read
    }

    /// R9 (6 Nov): what a chat shows for an account, as the phones do: the chosen name (newest rename), else the part of
    /// the signed-in address before "@", else which install it is. Never a generated "Default". `signIn` is what the
    /// caller itself read (a session chip's own check); without one, the last check made here is used.
    func label(_ id: String?, fallback: String, provider: String?, signIn: CodingAISignIn? = nil) -> String {
        var account = id.flatMap { accounts[$0] } ?? CodingAIAccount(id: id ?? "", name: fallback, provider: provider,
            // A session's recorded "Default…" is an install's generated name even before the account list has loaded.
            system: id.map(CodingAIAccountLabels.isSystemAccountId) == true || Self.isGeneratedName(fallback))
        if account.provider == nil { account.provider = provider }
        let known = signIn.flatMap { CodingAIAccountLabels.accountLabel($0) == nil ? nil : $0 }
        return CodingAIAccountLabels.chatLabel(account, known ?? id.flatMap { signIns[$0] } ?? signIn)
    }
    private static func isGeneratedName(_ name: String) -> Bool {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded == "default" || folded.hasPrefix("default (")
    }
}
