import Foundation
import TerminalDeckNativeCore

/// Joined into A's existing tool dispatcher under its normal permission policy.
/// No method accepts words, keys, canaries, cookies, or an approval decision.
public actor BackendCloudSecretsTools {
    private let secrets: any CloudSecretsPort
    private let policy: CloudSecretsPolicy
    private let browser: @Sendable (_ action: String, _ profile: String?) async throws -> CloudBrowserCoverage
    private var flow: Task<Void, Never>?
    private var outcome = "Ready"
    /// Plain sentences for sources this build does not save in Cloud (`BackendCloudSecretsLeanCoverage`): named in
    /// every status answer, never silently missing.
    private let notSaved: [String]
    /// This Mac's own stores, as the local-store check sees them (`BackendCloudRecoveryLocalStores.standing()`), the
    /// same answer the page uses. Anything but `.ready` means nothing from this Mac was sent: never "protected"
    /// (review A-M1). nil only where no local store is wired.
    private let localStanding: (@Sendable () async -> BackendCloudRecoveryLocalStanding)?
    /// One plain sentence per source whose last save to Cloud FAILED (review B-M2), from the wiring. While any is
    /// there, the status answer is "gaps", never "protected". nil where nothing reports save failures.
    private let saveFailures: (@Sendable () async -> [String])?
    public init(secrets: any CloudSecretsPort, policy: CloudSecretsPolicy,
                browser: @escaping @Sendable (String, String?) async throws -> CloudBrowserCoverage, notSaved: [String] = [],
                localStanding: (@Sendable () async -> BackendCloudRecoveryLocalStanding)? = nil,
                saveFailures: (@Sendable () async -> [String])? = nil) {
        self.secrets = secrets; self.policy = policy; self.browser = browser; self.notSaved = notSaved; self.localStanding = localStanding
        self.saveFailures = saveFailures
    }
    /// The one state word of the status answer and its sentence. "protected" only when Cloud has saved passwords,
    /// this Mac holds the confirmed key, its own stores open and nothing is left out.
    static func standing(status: CloudSecretsStatus?, waiting: Bool, local: BackendCloudRecoveryLocalStanding, gaps: [String],
                         outcome: String) -> (state: String, message: String) {
        guard let status else {
            return ("cant_check", "Can't check saved passwords right now. Nothing on this Mac was changed. Open Cloud and choose Check again.")
        }
        let setUp = status.state != .unset
        switch local {
        case .ready: break
        case .blocked: return ("blocked", local.words(cloudKeyHere: status.recoveryReady || waiting, cloudSetUp: setUp) ?? "")
        case .keyLost: return ("key_lost", local.words(cloudKeyHere: status.recoveryReady || waiting, cloudSetUp: setUp) ?? "")
        case .cannotCheck: return ("cant_check", local.words(cloudKeyHere: status.recoveryReady || waiting, cloudSetUp: setUp) ?? "")
        case .notConverted: return ("not_converted", local.words(cloudKeyHere: status.recoveryReady || waiting, cloudSetUp: setUp) ?? "")
        }
        if waiting { return ("waiting_for_cloud", CloudSecretsProtection.waitingAdvice) }
        guard setUp else { return ("not_set_up", "Saved passwords are not set up in Cloud yet. Nothing from this Mac has been sent.") }
        guard status.recoveryReady else {
            return ("locked", "Saved passwords are locked on this Mac: it does not hold the key yet, so nothing from this Mac is sent to Cloud.")
        }
        if !gaps.isEmpty { return ("gaps", "Some saved items are not in Cloud: " + gaps.joined(separator: " ")) }
        return ("protected", outcome)
    }
    public static let contribution = CloudFeatureContribution(owner: "V", tools: [
        .init(id: "cloud.secrets", title: "Cloud secrets", description: "Check saved-password protection or open its secure native sheet. Reads whether new devices open by themselves (askOnNewDevice false) or wait for the owner's click. No action changes that setting, starts the saved passwords again, or hands the key to a device: those are the owner's own presses on the Cloud page.",
              inputSchema: schema(actions: ["status", "setup", "request_device", "open_approval", "recover", "reset"], optional: "approvalId"),
              mutates: true, inventoryRows: ["I13", "I14", "I15", "I16", "I22"]),
        .init(id: "cloud.browser", title: "Browser sign-ins", description: "Check or transfer saved browser sign-ins. Returns counts only.",
              inputSchema: schema(actions: ["status", "backup", "restore"], optional: "profileId"),
              mutates: true, inventoryRows: ["I22"])
    ], inventoryRows: ["I13", "I14", "I15", "I16", "I22"], actions: ["secrets.setup", "secrets.request_device", "secrets.open_approval", "secrets.recover", "secrets.reset", "browser.backup", "browser.restore"])
    private static func schema(actions: [String], optional: String) -> CloudValue {
        .init(.object([.init("type", .string("object")), .init("additionalProperties", .bool(false)),
            .init("required", .array([.string("action")])), .init("properties", .object([
                .init("action", .object([.init("type", .string("string")), .init("enum", .array(actions.map(NativeRPCValue.string)))])),
                .init(optional, .object([.init("type", .string("string"))])),
                .init("requestId", .object([.init("type", .string("string"))]))]))]))
    }
    public func invoke(_ tool: String, arguments: CloudValue) async throws -> CloudValue {
        try await policy.require(tool == "cloud.browser" ? .browser : .secret, stage: .download)
        let value = arguments.raw
        let optional = tool == "cloud.browser" ? "profileId" : "approvalId"
        guard let fields = value.fields, Set(fields.map(\.key)).count == fields.count,
              Set(fields.map(\.key)).isSubset(of: ["action", optional, "requestId"]), let action = value["action"].string else { throw CloudFailure.invalidRequest }
        if value.has(optional), value[optional].string == nil { throw CloudFailure.invalidRequest }
        if value.has("requestId") { _ = try CloudSecretsCrypto.uuidBytes(value["requestId"].requireString("request", nonempty: true)) }
        if tool == "cloud.browser" {
            guard ["status", "backup", "restore"].contains(action) else { throw CloudFailure.invalidRequest }
            let result = try await browser(action, value["profileId"].string)
            return .init(try NativeRPCValue.parseJSON(JSONEncoder().encode(result)).setting("note", .string(CloudBrowserCoverage.renewalNotice)))
        }
        guard tool == "cloud.secrets", ["status", "setup", "request_device", "open_approval", "recover", "reset"].contains(action),
              action == "open_approval" ? value["approvalId"].string != nil : !value.has("approvalId") else { throw CloudFailure.invalidRequest }
        if action == "status" {
            // A status that cannot be read (this Mac's key blocked, Cloud not answering) is "can't check", not an error.
            let status: CloudSecretsStatus? = try? await secrets.status()
            let service = secrets as? CloudSecretsService
            // Saved here after "Codes match" but not yet confirmed by Cloud: say so.
            let waiting: Bool = await service?.protection() == .waitingForCloud
            // Anything left on this Mac is said plainly; never "protected" or
            // "Finished" while a gap exists (round-6 review R6-1).
            let bySource: [String: [String]] = await service?.gaps() ?? [:]
            let failed: [String] = await saveFailures?() ?? []
            let gaps: [String] = Array(Set(bySource.values.flatMap { $0 })).sorted() + failed.sorted()
            // Recovery words are no longer offered on the normal path (owner, 14 Nov); "recover" stays for older accounts.
            let steps: [NativeRPCValue] = waiting ? [.string("request_device")] : []
            // Items from other devices that were closed here without being applied, with their plain reason.
            let noticed: [String: Int] = await service?.notices() ?? [:]
            let skipped: [NativeRPCValue] = noticed.keys.sorted().map { reason in
                NativeRPCValue.object([.init("reason", .string(reason)), .init("count", .number(Double(noticed[reason] ?? 0)))])
            }
            let skippedCount: Int = noticed.values.reduce(0, +)
            let local: BackendCloudRecoveryLocalStanding = await localStanding?() ?? .ready
            let said = Self.standing(status: status, waiting: waiting, local: local, gaps: gaps, outcome: outcome)
            // Read only: the owner's stricter setting as this Mac applies it (nil where this Mac holds no key).
            var ask = NativeRPCValue.null
            if said.state == "protected" || said.state == "gaps", let service { ask = .bool(await service.askOnNewDevice()) }
            return .init(.object([.init("protected", .bool(said.state == "protected")), .init("state", .string(said.state)),
                .init("waitingForCloud", .bool(waiting)),
                .init("epoch", .number(Double(status?.epoch ?? 0))),
                .init("approvedDevices", .number(Double(status?.approvedDeviceCount ?? 0))), .init("pendingDevices", .number(Double(status?.pendingApprovals.count ?? 0))),
                .init("busy", .bool(flow != nil)),
                .init("askOnNewDevice", ask),
                .init("gaps", .array(gaps.map(NativeRPCValue.string))), .init("gapCount", .number(Double(gaps.count))),
                .init("skipped", .array(skipped)), .init("skippedCount", .number(Double(skippedCount))),
                .init("notSaved", .array(notSaved.map(NativeRPCValue.string))),
                .init("nextSteps", .array(steps)),
                .init("message", .string(said.message))]))
        }
        guard flow == nil else { return .init(.object([.init("pending", .bool(true))])) }
        let id = value["approvalId"].string
        if let id { _ = try CloudSecretsCrypto.uuidBytes(id) }
        outcome = "Waiting for you in Cloud"
        flow = Task { [secrets] in
            do {
                switch action {
                // On by default (owner, 14 Nov): set-up makes the key with no sheet and no recovery words.
                case "setup":
                    if let service = secrets as? CloudSecretsService { try await service.setupSilently() } else { try await secrets.beginSetup() }
                case "request_device": _ = try await secrets.requestApproval()
                case "open_approval": try await secrets.openApproval(id: id!)
                case "recover": try await secrets.beginRecovery()
                case "reset": try await secrets.beginReset()
                default: throw CloudFailure.invalidRequest
                }
                self.finished("Finished. Check Cloud for the current protection status.")
            } catch is CancellationError { self.finished("Cancelled. Local saved passwords were kept.") }
            catch { self.finished("This did not finish. Local saved passwords were kept. Open Cloud to try again.") }
        }
        return .init(.object([.init("pending", .bool(true)), .init("message", .string("Continue in the secure Cloud sheet on this Mac."))]))
    }
    private func finished(_ message: String) { flow = nil; outcome = message }
    public func stop() { flow?.cancel(); flow = nil }
}
