import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The logins on one linked device, asked about the machine itself
/// (`machines:logins:read`), with a fallback through a session running on it
/// for an older build over there (`machines:account:read`). Sign in and Sign
/// out are asked of that machine, which runs them and answers in a sentence.
@MainActor
@Observable
final class NativeCodingAIDeviceModel {
    let deviceId: String
    private(set) var loaded = false
    private(set) var answered = false
    private(set) var accounts: [CodingAIMachineAccount] = []
    private(set) var viaLoaded = false
    private(set) var viaCurrent: CodingAIMachineAccount?
    private(set) var viaAccounts: [CodingAIMachineAccount] = []
    private(set) var busy: String?
    private(set) var notice: (ok: Bool, text: String)?
    @ObservationIgnored private var ticket = 0

    init(deviceId: String) { self.deviceId = deviceId }

    private func call(_ channel: String, _ args: [Any?]) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func load(sessionId: String?) {
        ticket += 1
        let mine = ticket
        Task {
            let raw = (try? await call("machines:logins:read", [deviceId])) ?? .null
            guard mine == ticket else { return }
            let read = CodingAIMachineLogins.parse(raw)
            answered = read.answered
            accounts = read.accounts
            loaded = true
            guard !read.answered, let sessionId else { return }
            let through = (try? await call("machines:account:read", [deviceId, sessionId])) ?? .null
            guard mine == ticket else { return }
            if let parsed = CodingAIMachineLogins.parseThroughSession(through) {
                viaCurrent = parsed.current
                viaAccounts = parsed.accounts
            }
            viaLoaded = true
        }
    }

    func signIn(_ account: CodingAIMachineAccount, name: String, sessionId: String?) {
        act("machines:logins:signin", account, name: name, sessionId: sessionId)
    }

    func signOut(_ account: CodingAIMachineAccount, name: String, sessionId: String?) {
        act("machines:logins:signout", account, name: name, sessionId: sessionId)
    }

    private func act(_ channel: String, _ account: CodingAIMachineAccount, name: String, sessionId: String?) {
        busy = account.id
        notice = nil
        Task {
            defer { busy = nil }
            do {
                let answer = CodingAIMachineLogins.outcome(try await call(channel, [deviceId, account.id]))
                // The far machine's own words, both ways.
                notice = (answer.ok, answer.message)
                if answer.ok { load(sessionId: sessionId) }
            } catch {
                notice = (false, CodingAIMachineLogins.didNotAnswer(name))
            }
        }
    }
}
