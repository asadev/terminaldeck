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

struct NativeCodingAIDeviceSection: View {
    let device: CodingAIDevice
    @Bindable var model: NativeCodingAIDeviceModel

    private var session: CodingAIRemoteSession? { device.online ? device.sessions.first : nil }

    var body: some View {
        Section {
            content
        } header: {
            Text(CodingAIMachineLogins.heading(device.name))
        }
    }

    @ViewBuilder private var content: some View {
        if !device.online {
            prose(CodingAIMachineLogins.notConnected(device.name))
        } else if !model.loaded {
            prose(CodingAIMachineLogins.asking(device.name))
        } else if !model.answered && session == nil {
            prose(CodingAIMachineLogins.noWayToAsk(device.name))
        } else if !model.answered && !model.viaLoaded {
            prose(CodingAIMachineLogins.asking(device.name))
        } else {
            let accounts = model.answered ? model.accounts : model.viaAccounts
            if accounts.isEmpty {
                prose(CodingAIMachineLogins.nothingCameBack(device.name))
            } else {
                if let notice = model.notice {
                    NativeCodingAINotice(tone: notice.ok ? .info : .error, text: notice.text)
                }
                if !model.answered {
                    NativeCodingAINotice(tone: .info, text: CodingAIMachineLogins.readThroughSession(device.name))
                }
                ForEach(accounts) { account in
                    row(account, running: !model.answered && model.viaCurrent?.id == account.id && session != nil)
                }
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ account: CodingAIMachineAccount, running: Bool) -> some View {
        let offers = CodingAIMachineLogins.offers(account, machineAnswered: model.answered)
        let state = account.signInOrNotReported
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            NativeCodingAIDot(token: account.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    NativeCodingAIProviderMark(provider: account.provider, size: 13)
                    Text(account.label)
                        .textSelection(.enabled)
                    if running, let title = session?.title, !title.isEmpty {
                        NativeCodingAIBadge(text: title)
                    }
                }
                HStack(spacing: 5) {
                    NativeCodingAIStateMark(state: state.state.rawValue)
                    Text(account.stateLine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                if let note = offers.signOutNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if offers.signIn {
                Button("Sign in") { model.signIn(account, name: device.name, sessionId: session?.id) }
                    .disabled(model.busy != nil)
            }
            if offers.signOut {
                Button("Sign out") { model.signOut(account, name: device.name, sessionId: session?.id) }
                    .disabled(model.busy != nil)
            }
        }
        .padding(.vertical, 2)
    }
}
