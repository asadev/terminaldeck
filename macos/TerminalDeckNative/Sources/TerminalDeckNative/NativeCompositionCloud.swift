import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Only a complete injected account/sync assembly may enter the app graph.
/// Default production composition has no Cloud contribution until that assembly exists.
@MainActor
final class NativeCompositionCloud {
    static func resolveAccount(_ make: @MainActor () async throws -> BackendCloudAccount?) async -> BackendCloudAccount? {
        CloudDeleteWitnessSlot.shared.installOnce(BackendCloudDeleteWitness())
        // A failed Cloud sign-in/store must never fail the session-owning app graph, but it is never silent (13 Nov).
        do {
            guard let account = try await make() else {
                NativeCloudAccount.recordActivationFailure(.init(step: "account", kind: "refused (no public Store key or a read-only data folder)"))
                return nil
            }
            return account
        } catch {
            NativeCloudAccount.recordActivationFailure(.init(step: "account", kind: NativeCloudAccount.kind(error)))
            return nil
        }
    }
    let service: BackendCloudAccount
    private let root: BackendCompositionRoot
    private let joins: BackendCompositionProductionBindings
    private var task: Task<Void, Never>?
    /// Whether `cloud.secrets` is registered right now. Its owner id is never touched while it was not.
    private var secretsRegistered = false
    /// The same for lane A2's read-only `cloud.versions`.
    private var recordsRegistered = false
    /// The same for lane F's read-only `cloud.boot_files`.
    private var bootRegistered = false
    /// The same for the read-only `cloud.reach.status` (reach by account).
    private var reachRegistered = false
    /// The same for `sessions.switch_to_this_mac`.
    private var moveRegistered = false
    init(service: BackendCloudAccount, root: BackendCompositionRoot, joins: BackendCompositionProductionBindings) {
        self.service = service; self.root = root; self.joins = joins
        NativeCloudAccount.shared.attach(service)
        NativeReachAccount.shared.bindAccount(service)
        NativeCloudSecrets.shared.attached = { [weak self] in
            Task { @MainActor [weak self] in
                do { try await self?.registerSecrets() } catch { NativeCloudAccount.shared.reportFailure() }
            }
        }
        task = Task { [weak self] in
            for await _ in await service.events() {
                guard !Task.isCancelled else { return }
                do {
                    // `cloud.status` also carries the Cloud page's one summary, so an agent reads what the person sees.
                    let entries = try await BackendCloudAccountTools.registrations(service: service, now: Int64(Date().timeIntervalSince1970 * 1000), overview: {
                        await MainActor.run { NativeCloudOverview.current()?.wireValue }
                    }, contents: {
                        // `cloud.contents`: the same lists the "See what is in your Cloud" window shows.
                        await NativeCloudContentsModel.wire()
                    }, line: {
                        // Status-line lane: the one status line and the space per kind, as the window shows them.
                        // Profile edit in place (15 Nov): `profileName` = the name people and agents see, as his profile
                        // says it now (read only; no tool changes his profile).
                        await MainActor.run {
                            var fields = NativeCloudStatusLineModel.shared.wire().fields ?? []
                            if let name = NativeProfileFacts.current().name { fields.append(.init("profileName", .string(name))) }
                            return NativeRPCValue.object(fields)
                        }
                    }, shelf: { @MainActor in
                        await NativeCloudShelf.shared.wire()
                    }, chats: { @MainActor in
                        await NativeCloudChats.shared.wire()
                    }, signin: { provider in
                        await NativeCloudAccount.shared.signIn(provider: provider)
                    })
                    guard !Task.isCancelled else { return }
                    let bundle = try BackendDeckCoreCatalogueBundle(metadata: entries.map(\.0), policies: entries.map { joins.mcpPolicy($0.0, handler: $0.1) })
                    try joins.replaceContributions(owner: BackendCloudAccountTools.owner, [bundle], policiesWrapped: true)
                    // Direct callers still pass their existing caller grant; core calls use the wrapped policy above.
                    try await root.mcp.replaceTools(ownerID: BackendCloudAccountTools.owner, tools: entries)
                    // Saved passwords join the same way under their own owner id (`registerSecrets`).
                    try await self?.registerSecrets()
                    guard !Task.isCancelled else { return }
                    // Projects and agents (lane A2): ONE read-only tool, `cloud.versions`, only while those rows are
                    // built for this identity and Cloud is open.
                    let recordEntries = try await NativeCloudRecords.shared.toolEntries(visible: {
                        await service.state().visible(at: Int64(Date().timeIntervalSince1970 * 1000))
                    })
                    guard !Task.isCancelled else { return }
                    if !recordEntries.isEmpty || self?.recordsRegistered == true {
                        let recordBundle = try BackendDeckCoreCatalogueBundle(metadata: recordEntries.map(\.0), policies: recordEntries.map { joins.mcpPolicy($0.0, handler: $0.1) })
                        try joins.replaceContributions(owner: NativeCloudRecords.toolOwner, [recordBundle], policiesWrapped: true)
                        try await root.mcp.replaceTools(ownerID: NativeCloudRecords.toolOwner, tools: recordEntries)
                        self?.recordsRegistered = !recordEntries.isEmpty
                    }
                    // Switch to this Mac (step 2): its tool, beside the session tools, under its own owner id.
                    if self?.moveRegistered != true {
                        let moveEntries = try await MainActor.run { try NativeCloudChats.toolEntries() }
                        let moveBundle = try BackendDeckCoreCatalogueBundle(metadata: moveEntries.map(\.0), policies: moveEntries.map { joins.mcpPolicy($0.0, handler: $0.1) })
                        try joins.replaceContributions(owner: BackendCloudSessionMoveTools.owner, [moveBundle], policiesWrapped: true)
                        try await root.mcp.replaceTools(ownerID: BackendCloudSessionMoveTools.owner, tools: moveEntries)
                        self?.moveRegistered = true
                    }
                    // Reach by account: ONE read-only tool, `cloud.reach.status`, while signed in. Nothing switches reach on.
                    if self?.reachRegistered != true {
                        let reachEntries = try await MainActor.run { try NativeReachAccount.shared.toolEntries() }
                        let reachBundle = try BackendDeckCoreCatalogueBundle(metadata: reachEntries.map(\.0), policies: reachEntries.map { joins.mcpPolicy($0.0, handler: $0.1) })
                        try joins.replaceContributions(owner: BackendReachAccountTools.owner, [reachBundle], policiesWrapped: true)
                        try await root.mcp.replaceTools(ownerID: BackendReachAccountTools.owner, tools: reachEntries)
                        self?.reachRegistered = true
                    }
                    // Boot files (lane F): ONE read-only tool, `cloud.boot_files`. Accepting a file is never a tool.
                    let bootEntries = try await NativeCloudBoot.shared.toolEntries(visible: {
                        await service.state().visible(at: Int64(Date().timeIntervalSince1970 * 1000))
                    })
                    guard !Task.isCancelled else { return }
                    if !bootEntries.isEmpty || self?.bootRegistered == true {
                        let bootBundle = try BackendDeckCoreCatalogueBundle(metadata: bootEntries.map(\.0), policies: bootEntries.map { joins.mcpPolicy($0.0, handler: $0.1) })
                        try joins.replaceContributions(owner: NativeCloudBoot.toolOwner, [bootBundle], policiesWrapped: true)
                        try await root.mcp.replaceTools(ownerID: NativeCloudBoot.toolOwner, tools: bootEntries)
                        self?.bootRegistered = !bootEntries.isEmpty
                    }
                } catch { NativeCloudAccount.shared.reportFailure() }
            }
        }
    }
    /// Saved passwords' tools under their own owner id: `cloud.secrets` and the read-only `cloud.secrets.status`, only
    /// while this identity's saved passwords are wired and open. Nothing is registered otherwise. Gap 1b (14 Nov): also
    /// run the moment the graph attaches (it is built after the account's first events, so until the next account
    /// event the tools were missing).
    private func registerSecrets() async throws {
        let service = self.service
        var secretEntries: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = []
        if let graph = NativeCloudSecrets.shared.graph {
            secretEntries = try await BackendCloudSecretsLeanTool.registrations(tools: graph.tools, visible: {
                let open = await service.state().visible(at: Int64(Date().timeIntervalSince1970 * 1000))
                let sealed = await graph.isSealed()
                return open && !sealed
            }, summary: { await graph.summary() })
        }
        guard task != nil else { return }
        // The owner id is touched only once there is a tool to register, and afterwards to take it away.
        if !secretEntries.isEmpty || secretsRegistered {
            let secretBundle = try BackendDeckCoreCatalogueBundle(metadata: secretEntries.map(\.0), policies: secretEntries.map { joins.mcpPolicy($0.0, handler: $0.1) })
            try joins.replaceContributions(owner: BackendCloudSecretsLeanTool.owner, [secretBundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: BackendCloudSecretsLeanTool.owner, tools: secretEntries)
            secretsRegistered = !secretEntries.isEmpty
        }
    }
    /// Sign-out returns the app to its no-account state: no tools, observers or account task remain.
    func retire() async {
        NativeCloudSecrets.shared.attached = nil
        task?.cancel(); task = nil
        NativeCloudAccount.shared.detach()
        NativeReachAccount.shared.unbindAccount()
        if moveRegistered {
            moveRegistered = false
            await root.mcp.removeTools(ownerID: BackendCloudSessionMoveTools.owner)
            try? joins.replaceContributions(owner: BackendCloudSessionMoveTools.owner, [], policiesWrapped: true)
        }
        if reachRegistered {
            reachRegistered = false
            await root.mcp.removeTools(ownerID: BackendReachAccountTools.owner)
            try? joins.replaceContributions(owner: BackendReachAccountTools.owner, [], policiesWrapped: true)
        }
        if let empty = try? BackendDeckCoreCatalogueBundle(metadata: [], policies: []) {
            try? joins.replaceContributions(owner: BackendCloudAccountTools.owner, [empty], policiesWrapped: true)
        }
        try? await root.mcp.replaceTools(ownerID: BackendCloudAccountTools.owner, tools: [])
        // `cloud.secrets`, only if it is registered: the account task may be cancelled before it sees the sign-out.
        if secretsRegistered {
            secretsRegistered = false
            await root.mcp.removeTools(ownerID: BackendCloudSecretsLeanTool.owner)
            try? joins.replaceContributions(owner: BackendCloudSecretsLeanTool.owner, [], policiesWrapped: true)
        }
        if recordsRegistered {
            recordsRegistered = false
            await root.mcp.removeTools(ownerID: NativeCloudRecords.toolOwner)
            try? joins.replaceContributions(owner: NativeCloudRecords.toolOwner, [], policiesWrapped: true)
        }
        if bootRegistered {
            bootRegistered = false
            await root.mcp.removeTools(ownerID: NativeCloudBoot.toolOwner)
            try? joins.replaceContributions(owner: NativeCloudBoot.toolOwner, [], policiesWrapped: true)
        }
    }
    deinit { task?.cancel() }
}

/// AM8: Cloud is optional and quiet. A data folder where nobody signed in, or where the person signed out,
/// starts with no Cloud object at all; only the person's own sign-in link constructs the account.
@MainActor
enum NativeCloudLaunch {
    nonisolated static func folder(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("cloud", isDirectory: true) }
    nonisolated static func signedOutMarker(_ dataRoot: URL) -> URL { folder(dataRoot).appendingPathComponent("signed-out") }
    /// N3: written when the server explicitly said Cloud is not allowed. Holds the wall-clock second of that answer,
    /// used only to re-check at most once a day (never compared with a server time).
    nonisolated static func dormantMarker(_ dataRoot: URL) -> URL { folder(dataRoot).appendingPathComponent("dormant") }
    nonisolated static let dormantRecheckSeconds: TimeInterval = 86_400
    /// A few stats and one tiny read. Creates nothing and reads no protected storage.
    nonisolated static func used(dataRoot: URL, now: Date = Date()) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder(dataRoot).path, isDirectory: &directory), directory.boolValue else { return false }
        guard !FileManager.default.fileExists(atPath: signedOutMarker(dataRoot).path) else { return false }
        // A dormant account is re-checked lazily, off the launch path, at most once a day (and whenever a link arrives).
        if let text = try? String(contentsOf: dormantMarker(dataRoot), encoding: .utf8), let at = TimeInterval(text) {
            return now.timeIntervalSince1970 - at >= dormantRecheckSeconds || now.timeIntervalSince1970 < at
        }
        return !FileManager.default.fileExists(atPath: dormantMarker(dataRoot).path)
    }
    /// Markers live only inside the account's existing folder; a folder is never created for them.
    nonisolated static func recordSession(_ change: BackendCloudAccountSessionChange, dataRoot: URL, now: Date = Date()) {
        let fm = FileManager.default
        if change == .signedIn {
            try? fm.removeItem(at: signedOutMarker(dataRoot)); try? fm.removeItem(at: dormantMarker(dataRoot)); return
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: folder(dataRoot).path, isDirectory: &directory), directory.boolValue else { return }
        if change == .signedOut {
            try? fm.removeItem(at: dormantMarker(dataRoot))
            // A "Signed out from <device> on <date>" line already written into the marker stays (lost-device B4).
            if !fm.fileExists(atPath: signedOutMarker(dataRoot).path) { try? Data().write(to: signedOutMarker(dataRoot), options: .atomic) }
        } else {
            try? Data(String(Int(now.timeIntervalSince1970)).utf8).write(to: dormantMarker(dataRoot), options: .atomic)
        }
    }
    /// Lost-device B4: the Profile line "Signed out from <device> on <date> ..." kept in the signed-out marker, so it is
    /// still there after the app restarts; the next sign-in removes the marker and with it the line. Plain words only.
    nonisolated static func recordSignedOutElsewhere(_ line: String, dataRoot: URL) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder(dataRoot).path, isDirectory: &directory), directory.boolValue else { return }
        try? FileManager.default.removeItem(at: dormantMarker(dataRoot))
        try? Data(String(line.prefix(400)).utf8).write(to: signedOutMarker(dataRoot), options: .atomic)
    }
    nonisolated static func signedOutElsewhereLine(dataRoot: URL) -> String? {
        guard let data = try? Data(contentsOf: signedOutMarker(dataRoot)), !data.isEmpty, data.count <= 1_600,
              let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        return line
    }
    /// Signed in, but the server's last explicit answer did not allow Cloud (N3).
    nonisolated static func isDormant(dataRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: dormantMarker(dataRoot).path) && !FileManager.default.fileExists(atPath: signedOutMarker(dataRoot).path)
    }
    /// Returns the account to resume now, or nil after arming only the sign-in link.
    static func begin(dataRoot: URL, activate: @escaping @MainActor () async -> BackendCloudAccount?) async -> BackendCloudAccount? {
        // Lost-device B4: the line survives a restart until the next sign-in.
        if let line = signedOutElsewhereLine(dataRoot: dataRoot) { NativeCloudAccount.shared.signedOutElsewhere(line) }
        guard used(dataRoot: dataRoot) else { NativeCloudAccount.shared.arm(activate, dormant: isDormant(dataRoot: dataRoot)); return nil }
        if let account = await activate() { return account }
        // A refused build (no Store key, read-only data folder) keeps the person's link working (finding 25).
        NativeCloudAccount.shared.arm(activate, dormant: isDormant(dataRoot: dataRoot))
        return nil
    }

    /// §10 / N6: one explicit, recorded choice per identity before this Mac's existing memory may travel to it.
    /// Asked when the first memory row is about to be enabled (never at sign-in), changeable on the Cloud page.
    nonisolated static func memoryChoiceFile(dataRoot: URL, subjectHash: String) -> URL {
        folder(dataRoot).appendingPathComponent(subjectHash, isDirectory: true).appendingPathComponent("memory-choice")
    }
    /// nil = never asked; true/false = the person's answer.
    ///
    /// Review B-M4 (Decker's decision), the ONE place that says what the stored choice means. The file keeps its old
    /// name and values ("include" / "local"), but the question is no longer about memory alone:
    /// - "include" = "Use Cloud here": this Mac's memory, projects, agents and boot files are added to the Cloud AND
    ///   what is in the Cloud comes to this Mac;
    /// - "local" = "Not now": Cloud is not used on this Mac: its memory, projects, agents and boot files are not sent, and none arrive here (the rows are
    ///   not built at all, so neither direction runs). Nothing is deleted on either side.
    /// `NativeCloudAccount.memoryIncluded` carries the same meaning.
    nonisolated static func memoryChoice(dataRoot: URL, subjectHash: String) -> Bool? {
        switch try? String(contentsOf: memoryChoiceFile(dataRoot: dataRoot, subjectHash: subjectHash), encoding: .utf8) {
        case "include": return true
        case "local": return false
        default: return nil
        }
    }
    nonisolated static func memoryIncluded(dataRoot: URL, subjectHash: String) -> Bool { memoryChoice(dataRoot: dataRoot, subjectHash: subjectHash) == true }
    /// Written only inside the account folder the signed-in assembly already created.
    nonisolated static func setMemoryChoice(_ include: Bool, dataRoot: URL, subjectHash: String) {
        let file = memoryChoiceFile(dataRoot: dataRoot, subjectHash: subjectHash)
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        try? Data((include ? "include" : "local").utf8).write(to: file, options: .atomic)
    }
    /// Review B-M4's words. Owner, 13 Nov: the question is no longer asked; signing in turns Cloud on for this Mac
    /// (both directions) and the Cloud page keeps one switch to turn it off. The words stay for the page's button.
    nonisolated static let cloudHereTitle = "Use your Cloud on this Mac?"
    nonisolated static let cloudHereText = "This Mac's memory, projects, agents and boot files are added to your Cloud, and what is in your Cloud comes to this Mac. Nothing is deleted on either side."
    nonisolated static let cloudHereYes = "Use Cloud here"
    nonisolated static let cloudHereNo = "Not now"

    /// "How this Mac trusts your other devices" (owner, 13 Nov): this Mac's own setting, kept in the Keychain beside
    /// this copy's trusted-device lists (security gap 1). No stored choice = "Automatically, with my account". The old
    /// `cloud/trust-mode` file is only a one-time migration source and is deleted. No tool writes it; only the Cloud
    /// page's guarded press.
    nonisolated static func trustModeFile(_ dataRoot: URL) -> URL { folder(dataRoot).appendingPathComponent("trust-mode") }
    nonisolated static func trustModeStore(dataRoot: URL) -> BackendCloudTrustModeStore? {
        guard let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, !appName.isEmpty else { return nil }
        return .keychain(appName: appName, instanceId: NativeCloudAccountHash.hash(dataRoot.path), legacyFile: trustModeFile(dataRoot))
    }
    nonisolated static func trustMode(dataRoot: URL) -> BackendCloudTrustMode {
        trustModeStore(dataRoot: dataRoot)?.load() ?? .ask
    }
    nonisolated static func setTrustMode(_ mode: BackendCloudTrustMode, dataRoot: URL) {
        try? trustModeStore(dataRoot: dataRoot)?.save(mode)
    }
}
