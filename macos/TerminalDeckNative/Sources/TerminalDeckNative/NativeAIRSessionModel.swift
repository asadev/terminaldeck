import Foundation
import Observation
import TerminalDeckNativeCore

/// A prepared AI request using the app's existing provider and login resolver.
/// Opening this sheet reads choices; only Start AI session launches anything.
@MainActor
@Observable
final class NativeAIRSessionModel: Identifiable {
    let id = UUID()
    let projectPath: String
    let checkTitle: String
    var prompt: String
    var provider: String?
    var profileID: String?
    private(set) var loading = true
    private(set) var resolvingLogin = false
    private(set) var starting = false
    private(set) var error: String?
    private(set) var providers: [NewSessionProviderRow] = []
    private(set) var accounts = CodingAIAccountsSnapshot.empty
    private(set) var defaultProvider: String?
    private(set) var defaultProfileID: String?
    private(set) var signIn: CodingAISignIn?
    private(set) var accountSignIns: [String: CodingAISignIn] = [:]
    @ObservationIgnored private let dependencies: NativeAIRReadinessDependencies
    @ObservationIgnored private let opened: (NativeAIRLaunch) -> Void
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var signInTicket = 0
    @ObservationIgnored private var profileTicket = 0

    init(projectPath: String, check: ReadinessCheck, plan: AIRReadinessActionPlan,
         preferredAgent: String?, dependencies: NativeAIRReadinessDependencies,
         opened: @escaping (NativeAIRLaunch) -> Void) {
        self.projectPath = projectPath
        checkTitle = plan.title
        prompt = plan.aiPrompt
        provider = preferredAgent
        self.dependencies = dependencies
        self.opened = opened
    }

    var resolution: NewSessionResolution {
        NewSessionStart.resolve(providers: NewSessionStartProvider.from(providers),
            profiles: accountOptions.map { NewSessionStartProfile(id: $0.id, name: $0.name, system: $0.system) },
            memory: NewSessionMemory(), defaultProvider: defaultProvider, defaultProfileId: defaultProfileID,
            projectPath: projectPath, provider: provider, profileId: profileID, resume: false)
    }

    var request: NewSessionRequest? {
        guard var request = resolution.request else { return nil }
        request.firstPrompt = prompt
        request.title = "AI readiness · \(checkTitle)"
        return request
    }

    var availableProviders: [NewSessionProviderRow] { providers.filter(\.available) }
    /// The existing resolver first chooses the agent. Logins are then scoped to
    /// that agent, so the UI shows the same account the native launcher uses.
    var selectedProviderID: String? {
        NewSessionStart.resolve(providers: NewSessionStartProvider.from(providers), profiles: [],
            memory: NewSessionMemory(), defaultProvider: defaultProvider, defaultProfileId: nil,
            projectPath: projectPath, provider: provider, profileId: nil, resume: false).request?.provider
    }
    var accountOptions: [CodingAIAccount] {
        guard let id = selectedProviderID else { return [] }
        return CodingAILogins.oneRowPerEmail(accounts.accounts, signIn: accountSignIns).filter { $0.provider == id }
    }
    var activeProvider: NewSessionProviderRow? { providers.first { $0.id == request?.provider } }
    var activeAccount: CodingAIAccount? { accountOptions.first { $0.id == request?.profileId } }
    var loginNotice: String? { NewSessionProviders.isolationNotice(request?.provider) }
    var canStart: Bool {
        !loading && !resolvingLogin && !starting && request != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func call(_ channel: String, _ arguments: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await dependencies.invoke(channel, arguments))
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let detection = call("providers:detect")
            async let custom = call("agents:list")
            async let profiles = call("profiles:list")
            async let preferences = call("prefs:get")
            let (found, added, snapshot, prefs) = try await (detection, custom, profiles, preferences)
            // A terminal cannot act on an AI prompt, so it is not an AI choice.
            providers = NewSessionProviders.rows(detected: found, added: NewSessionCustomAgent.parse(added))
                .filter { $0.id != "shell" }
            accounts = CodingAIAccountsParse.snapshot(snapshot)
            Task { await readAccountIdentities() }
            defaultProvider = prefs["defaultProvider"].string
            await resolveDefaultProfile()
        } catch {
            self.error = "Could not load the AI choices. \(NativeAIRReadinessModel.sentence(error))"
            loaded = false
        }
    }

    /// CONNECT-SKILLS: the coding AIs this Mac does not have yet, each installable from the sheet.
    var installableProviders: [NewSessionProviderRow] { providers.filter { !$0.available && ["claude", "codex", "gemini"].contains($0.id) } }
    /// An AI was installed from the sheet: read the choices again and pick it.
    func installed(_ id: String) async {
        loaded = false
        await load()
        provider = id
        await changedProvider()
    }

    func changedProvider() async {
        guard !loading, !starting else { return }
        profileID = nil
        defaultProfileID = nil
        signIn = nil
        await resolveDefaultProfile()
    }

    private func resolveDefaultProfile() async {
        profileTicket += 1
        let mine = profileTicket
        guard let id = selectedProviderID, NewSessionProviders.isolationNotice(id) == nil else {
            defaultProfileID = nil
            resolvingLogin = false
            signIn = nil
            return
        }
        resolvingLogin = true
        defer { if mine == profileTicket { resolvingLogin = false } }
        do {
            let answer = try await call("profiles:resolve", [["projectPath": projectPath, "provider": id]])
            guard mine == profileTicket, selectedProviderID == id else { return }
            let account = CodingAIAccountsParse.account(answer)
            defaultProfileID = account?.provider == id ? account?.id : nil
        } catch {
            guard mine == profileTicket else { return }
            self.error = "Could not confirm the project's login. \(NativeAIRReadinessModel.sentence(error))"
            defaultProfileID = nil
        }
        guard mine == profileTicket else { return }
        resolvingLogin = false
        await checkSignIn()
    }

    private func readAccountIdentities() async {
        for account in accounts.accounts {
            if let raw = try? await call("profiles:signin", [account.id, ["provider": account.provider ?? "claude", "refresh": false]]) {
                accountSignIns[account.id] = CodingAIAccountsParse.signIn(raw)
            }
        }
    }

    func checkSignIn() async {
        guard !resolvingLogin else { return }
        signInTicket += 1
        let mine = signInTicket
        guard let request, let id = request.profileId, loginNotice == nil else {
            signIn = nil
            return
        }
        do {
            let answer = try await call("profiles:signin", [id, ["provider": request.provider]])
            guard mine == signInTicket else { return }
            signIn = NewSessionLogin.signIn(answer)
            if let signIn { accountSignIns[id] = signIn }
        } catch {
            guard mine == signInTicket else { return }
            signIn = .uncheckable
        }
    }

    func start() async {
        guard canStart, let request else { return }
        starting = true
        error = nil
        defer { starting = false }
        do {
            opened(try await dependencies.launchSession(request))
        } catch {
            self.error = NativeAIRReadinessModel.sentence(error)
        }
    }
}
