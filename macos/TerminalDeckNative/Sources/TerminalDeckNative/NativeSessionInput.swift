import Foundation
import TerminalDeckNativeCore

/// Typing into a session from somewhere that is not its terminal — the native
/// counterpart of `useAgentTarget`'s `writeOne` (send-to-session from the browser,
/// the simulators, annotate): a pty on this Mac (`session:write`), a session on a
/// paired machine without opening it here (`machines:send`), or a shell on a
/// server (`servers:shell:write`, by the shell id its pane opened).
@MainActor
enum NativeSessionInput {
    struct Outcome: Equatable {
        let ok: Bool
        let message: String?
        static let sent = Outcome(ok: true, message: nil)
    }

    /// `text` exactly as given — add "\r" yourself for a Return.
    /// - tabId: the session's tab id (`SessionTarget`): a pty UUID, `machine <id> <session>` or `server <id> <key>`.
    /// - machineName / serverName: for the sentence when it does not arrive.
    static func send(tabId: String, text: String, name: String = "that machine") async -> Outcome {
        switch SessionTarget(tabId: tabId) {
        case .local(let id):
            EngineBridge.shared.send("session:write", [id, text])
            return .sent
        case .machine(let machineId, let sessionId):
            do {
                let answer = try await EngineBridge.shared.invoke("machines:send", [machineId, sessionId, text]) as? [String: Any]
                if TerminalJSON.bool(answer?["ok"]) == true { return .sent }
                return Outcome(ok: false, message: TerminalJSON.text(answer?["message"]) ?? "\(name) refused it.")
            } catch {
                return Outcome(ok: false, message: "\(name) did not answer.")
            }
        case .server:
            let gone = Outcome(ok: false, message: "That terminal on \(name) is no longer open.")
            if let shellId = NativeServerShells.shellId(forTab: tabId) {
                let answer = try? await EngineBridge.shared.invoke("servers:shell:write", [shellId, text]) as? [String: Any]
                return TerminalJSON.bool(answer?["written"]) == true ? .sent : gone
            }
            // A shell the page holds: it types it (`server-shell-write`); it does nothing when it has none.
            AppModel.shared.web.run(.serverShellWrite(tabId, text))
            return .sent
        case nil:
            return Outcome(ok: false, message: "This build cannot type into your sessions.")
        }
    }
}

/// Which server shell id each server tab is talking to, for shells a native pane opened.
@MainActor
enum NativeServerShells {
    private static var ids: [String: String] = [:]

    static func shellId(forTab tabId: String) -> String? { ids[tabId] }

    static func opened(tabId: String, shellId: String) { ids[tabId] = shellId }

    static func closed(tabId: String) { ids[tabId] = nil }
}
