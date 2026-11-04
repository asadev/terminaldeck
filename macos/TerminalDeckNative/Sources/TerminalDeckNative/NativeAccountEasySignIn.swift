import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// ACCOUNTS-SPEC §4a: sign in to an AI account without a terminal. The app runs the AI's own
// sign-in (profiles:signin-start); the browser opens; this shows where things stand in plain
// words, takes a code only if the AI asks for one, and finishes by itself. A code typed here goes
// straight to the sign-in and is cleared at once; nothing is logged.

@MainActor @Observable
final class NativeAccountSignInModel {
    static let shared = NativeAccountSignInModel()

    struct Active: Identifiable, Equatable {
        let id: String            // the flow
        var accountID: String
        var accountName: String
        var provider: String
        var state: String         // waiting | needs-code | done | failed | cancelled
        var message: String
        /// A brand-new account that should take its name from the email it signs in with.
        var namesItself: Bool
        /// Created by this sign-in: removed again if the sign-in is cancelled or fails.
        var createdHere: Bool
        var loginStore: String = "app"
    }
    var active: Active?
    var code = ""
    var problem: String?
    /// This Mac's own login, waiting for the person to confirm its sign-in (it is the Terminal's login too).
    var confirmingOwnLogin: CodingAIAccount?
    /// The last sign-in, to start again once a missing AI is installed (CONNECT-SKILLS).
    @ObservationIgnored var retry: (@MainActor () -> Void)?
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// Claude and Codex have a sign-in command the app can run; Gemini signs in inside a session.
    static func canDrive(_ provider: String?) -> Bool { CodingAILogins.appSignsIn(provider) }

    /// 4 Nov (Asad: Sign in on this Mac's own login "opens a new chat session instead of taking me somewhere where
    /// I can sign in"): the ONE thing every Sign in button does. Claude Code and Codex: the app's own sign-in (the
    /// browser opens; this Mac's own login asks first, because the Terminal uses it too). Gemini has no sign-in
    /// command, so it alone still signs in inside a session.
    func open(_ account: CodingAIAccount, store: NativeCodingAIStore? = nil) {
        guard !account.isAPIKey else { return }
        guard Self.canDrive(account.provider) else { (store ?? .shared).signIn(account); return }
        if account.system { problem = nil; confirmingOwnLogin = account } else { start(account: account) }
    }
    /// The person confirmed: sign this Mac's own login in.
    func confirmOwnLogin() {
        guard let account = confirmingOwnLogin else { return }
        confirmingOwnLogin = nil
        start(account: account, ownLogin: true)
    }

    /// Sign in (or sign in again) to an account that exists.
    func start(account: CodingAIAccount, email: String? = nil, namesItself: Bool = false, createdHere: Bool = false, ownLogin: Bool = false) {
        problem = nil; code = ""
        let provider = account.provider ?? "claude"
        // An account this sign-in made is removed again on failure: its retry is the whole Add (set there).
        if !createdHere { retry = { [weak self] in self?.start(account: account, email: email, namesItself: namesItself, ownLogin: ownLogin) } }
        Task {
            do {
                var options: [String: Any] = [:]
                if let email, !email.isEmpty { options["email"] = email }
                if ownLogin { options["ownLogin"] = true }
                let raw = try await EngineBridge.shared.invoke("profiles:signin-start", [account.id, options] as [Any]) as? [String: Any] ?? [:]
                guard let flow = raw["flow"] as? String else { throw NativeRPCError(code: "signin", message: "The sign-in could not be started.") }
                active = Active(id: flow, accountID: account.id,
                                accountName: account.system ? CodingAIAccountLabels.ownLoginLabel(provider) : account.name, provider: provider,
                                state: raw["state"] as? String ?? "waiting", message: raw["message"] as? String ?? "",
                                namesItself: namesItself, createdHere: createdHere, loginStore: ownLogin ? "mac" : raw["loginStore"] as? String ?? "app")
                watch(flow)
            } catch {
                let text = CodingAIErrorText.from(error, fallback: "The sign-in could not be started.")
                problem = NativeAccountLevelsModel.saysOlderHelper(text) ? NativeAccountLevelsModel.olderHelperSignIn : text
                if createdHere { _ = try? await EngineBridge.shared.invoke("profiles:signin-discard", [account.id]); NativeCodingAIPages.announceAccountsChanged() }
            }
        }
    }

    /// Add account: the app starts the AI's sign-in before it registers the account.
    func addAndSignIn(provider: String, name: String, email: String?) {
        problem = nil
        retry = { [weak self] in self?.addAndSignIn(provider: provider, name: name, email: email) }
        Task {
            do {
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                var options: [String: Any] = ["provider": provider, "name": wanted]
                if let email, !email.isEmpty { options["email"] = email }
                let raw = try await EngineBridge.shared.invoke("profiles:add-signin", [options]) as? [String: Any] ?? [:]
                guard let id = raw["profileId"] as? String, let flow = raw["flow"] as? String else {
                    throw NativeRPCError(code: "signin", message: "The sign-in could not be started. Click Add account to try again.")
                }
                active = Active(id: flow, accountID: id, accountName: raw["accountName"] as? String ?? wanted, provider: provider,
                    state: raw["state"] as? String ?? "waiting", message: raw["message"] as? String ?? "",
                    namesItself: wanted.isEmpty, createdHere: true, loginStore: raw["loginStore"] as? String ?? "agent")
                watch(flow)
                NativeCodingAIPages.announceAccountsChanged()
            } catch { problem = CodingAIErrorText.from(error, fallback: "Could not add that account.") }
        }
    }

    private func watch(_ flow: String) {
        watching?.cancel()
        watching = Task { [weak self] in
            // Only while a sign-in is open. 18 Oct (#513): the sign-in answers as soon as something changes (or after
            // 15 quiet seconds), so the code prompt shows at once; a helper from before that answers at once and is
            // asked again after a second, as before. #141: five failed reads in a row end the wait with a working Close.
            var revision: Int?, failures = 0
            while !Task.isCancelled {
                guard let self, self.active?.id == flow else { return }
                var options: [String: Any] = ["wait": 15]
                if let revision { options["after"] = revision }
                let asked = ContinuousClock.now
                do {
                    let raw = try await EngineBridge.shared.invoke("profiles:signin-state", [flow, options] as [Any], timeout: 30) as? [String: Any] ?? [:]
                    failures = 0
                    guard var now = self.active, now.id == flow else { return }
                    now.state = raw["state"] as? String ?? now.state
                    now.message = raw["message"] as? String ?? now.message
                    self.active = now
                    if ["done", "failed", "cancelled"].contains(now.state) { await self.finished(now); return }
                    revision = (raw["revision"] as? NSNumber)?.intValue
                    if revision == nil { try? await Task.sleep(until: asked + .seconds(1)) }
                } catch {
                    failures += 1
                    if failures >= 5 { self.lost(flow, CodingAIErrorText.from(error, fallback: "")); return }
                    try? await Task.sleep(until: asked + .seconds(1))
                }
            }
        }
    }

    /// The sign-in cannot be reached or stopped: the sheet says so and its Close and Try Again work.
    private func lost(_ flow: String, _ why: String) {
        guard var now = active, now.id == flow, !["done", "failed", "cancelled"].contains(now.state) else { return }
        watching?.cancel(); watching = nil
        now.state = "failed"
        now.message = "Terminal Deck lost track of this sign-in" + (why.isEmpty ? "." : ": " + why) + " Close this window, then try again."
        active = now
        NativeCodingAIPages.announceAccountsChanged()
    }

    private func finished(_ flow: Active) async {
        code = ""
        if flow.state == "done" {
            // Named from the email it signed in with (he can rename it afterwards).
            if flow.namesItself,
               let report = try? await EngineBridge.shared.invoke("profiles:signin", [flow.accountID, ["refresh": true]] as [Any]) as? [String: Any],
               let email = report["account"] as? String, !email.isEmpty {
                if (try? await EngineBridge.shared.invoke("profiles:rename", [flow.accountID, email])) != nil, var now = active, now.id == flow.id {
                    now.accountName = email; active = now
                }
            }
        } else if flow.createdHere {
            // Nothing was signed in: do not leave an empty account behind.
            _ = try? await EngineBridge.shared.invoke("profiles:signin-discard", [flow.accountID])
        }
        // The row reads its sign-in again at once (the answer it had is the one from before this sign-in).
        if flow.state == "done" { NativeCodingAIStore.shared.reloadAccounts(forcing: [flow.accountID]) }
        NativeCodingAIPages.announceAccountsChanged()
        await NativeAccountLevelsModel.shared.reload()
        await NativeAccountLevelsModel.shared.reloadUsage()
    }

    func submitCode() {
        guard let flow = active?.id else { return }
        let typed = code
        code = ""
        Task {
            do { _ = try await EngineBridge.shared.invoke("profiles:signin-code", [flow, typed]) }
            catch { problem = CodingAIErrorText.from(error, fallback: "That code could not be sent.") }
        }
    }

    func cancel() {
        guard let flow = active else { return }
        if !["done", "failed", "cancelled"].contains(flow.state) {
            // #141: a Cancel the sign-in refuses still leaves the sheet with a Close that works.
            Task {
                do { _ = try await EngineBridge.shared.invoke("profiles:signin-cancel", [flow.id]) }
                catch { lost(flow.id, CodingAIErrorText.from(error, fallback: "")) }
            }
        } else { close() }
    }

    func close() { watching?.cancel(); watching = nil; active = nil; code = ""; problem = nil }

    func tryAgain(_ accounts: [CodingAIAccount]) {
        guard let flow = active else { return }
        let again = accounts.first { $0.id == flow.accountID }, add = retry
        close()
        // #514: an account this sign-in made was removed when it failed: Try Again runs the whole Add again.
        if flow.createdHere, let add { add() }
        else if let again { start(account: again, namesItself: flow.namesItself) }
    }
}

/// Where a sign-in stands: waiting for the browser, asking for a code, done or failed.
struct NativeAccountSignInSheet: View {
    @Bindable var model: NativeAccountSignInModel
    let accounts: [CodingAIAccount]

    var body: some View {
        if let flow = model.active {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: DeckRowIcon.provider(flow.provider))
                    Text(flow.state == "done" ? "Signed in" : "Sign in to " + CodingAICatalog.label(flow.provider)).font(.headline)
                }
                switch flow.state {
                case "done":
                    Label("\(flow.accountName) is signed in. " + (flow.loginStore == "mac" ? "Your Terminal uses this login too."
                        : flow.loginStore == "agent" ? "This login is in the AI’s own store for this account." : "Terminal Deck keeps this login."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case "failed", "cancelled":
                    Label(flow.message.isEmpty ? "The sign-in did not finish." : flow.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                default:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(flow.message).fixedSize(horizontal: false, vertical: true) }
                    Text("Your browser has opened \(CodingAICatalog.label(flow.provider))’s own sign-in page. Approve there and this finishes by itself.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if flow.state == "needs-code" {
                        HStack(spacing: 6) {
                            SecureField("Code from the sign-in page", text: $model.code)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.submitCode() }
                            Button("Paste") {
                                if let text = NSPasteboard.general.string(forType: .string) { model.code = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                            Button("Continue") { model.submitCode() }.buttonStyle(.borderedProminent).disabled(model.code.isEmpty)
                        }
                    }
                }
                if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    switch flow.state {
                    case "done": Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
                    case "failed", "cancelled":
                        Button("Close") { model.close() }
                        Button("Try Again") { model.tryAgain(accounts) }.buttonStyle(.borderedProminent)
                    default: Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }
}
