import Foundation
import Observation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// One file watch for every open chat. Settings and MCP renames both write this existing account file.
@MainActor @Observable
final class NativeChatAccountNames {
    static let shared = NativeChatAccountNames()
    private var names: [String: String] = [:]
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
        let accounts = CodingAIAccountsParse.snapshot(CodingAIJSON(raw)).accounts
        names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
    func name(_ id: String?, fallback: String) -> String { id.flatMap { names[$0] } ?? fallback }
}
