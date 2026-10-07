import Foundation
import TerminalDeckNativeCore

/// Preserve the source IPC names and argument shapes. All authority decisions
/// are supplied by the app's real session/device grants, never inferred here.
public actor BackendBrowserScrapingRPC {
    public static let channels: Set<String> = ["browser-worker:list", "browser-worker:ensure", "browser-worker:register", "browser-worker:unregister",
        "browser-worker:pace", "browser-worker:lift", "browser-worker:inject", "browser-worker:lift-requests", "browser-worker:lift-answer", "browser-worker:forget-lift",
        "browser-scraping:config", "browser-scraping:config-set", "browser-scraping:status", "browser-scraping:capture-clear", "browser-scraping:capture-reveal", "browser-scraping:ledger-clear",
        "browser:block-capture", "browser:block-capture-set"]
    public let workers: BackendBrowserWorkers
    public let store: BackendBrowserScrapingStore
    public let assets: BackendBrowserScrapingAssets
    public let network: BackendBrowserNetworkCapture
    public let inbox: BackendBrowserWorkersLiftRequests
    private let resolveProfile: @Sendable (BackendBrowserScrapingCaller, String?) async throws -> String
    private let profiles: @Sendable (BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile]
    private let authorize: BackendBrowserScrapingAuthorize
    private let reveal: @Sendable (BackendBrowserScrapingCaller, URL) async throws -> Void
    private let sessionLift: BackendBrowserSessionLift?
    private var watching: [String: (BackendBrowserScrapingCaller, String)] = [:]
    private var inboxWatching: [String: BackendBrowserScrapingCaller] = [:]
    public init(workers: BackendBrowserWorkers, store: BackendBrowserScrapingStore, assets: BackendBrowserScrapingAssets,
                network: BackendBrowserNetworkCapture, inbox: BackendBrowserWorkersLiftRequests,
                resolveProfile: @escaping @Sendable (BackendBrowserScrapingCaller, String?) async throws -> String,
                profiles: @escaping @Sendable (BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile],
                authorize: @escaping BackendBrowserScrapingAuthorize,
                reveal: @escaping @Sendable (BackendBrowserScrapingCaller, URL) async throws -> Void,
                sessionLift: BackendBrowserSessionLift? = nil) {
        self.workers = workers; self.store = store; self.assets = assets; self.network = network; self.inbox = inbox
        self.resolveProfile = resolveProfile; self.profiles = profiles; self.authorize = authorize; self.reveal = reveal; self.sessionLift = sessionLift
    }
    public func register(on registry: NativeChannelRegistry, ownerID: String) async throws {
        // No subscription tokens here: invoke registrations are held by registry.
        // Roll back only this facade's registrations if a duplicate is found.
        var installed: [String] = []
        do {
            for channel in Self.channels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { [self] context, args in
                    try await invoke(channel, args: args, context: context)
                }
                installed.append(channel)
            }
        } catch {
            for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
    }
    /// Fetch on every response. A supplied service's permission/expiry/pending
    /// state must never be frozen at RPC construction or read from tool args.
    private func currentWorkerView(_ caller: BackendBrowserScrapingCaller, base: NativeRPCValue? = nil) async throws -> NativeRPCValue {
        let value: NativeRPCValue
        if let base { value = base } else { value = try await workers.view(caller) }
        guard let sessionLift else { return value }
        let current = try await sessionLift.view(caller)
        return try BackendBrowserWorkers.applyingTransferState(current, to: value)
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw BackendBrowserScrapingError.invalid("Unknown browser scraping channel.") }
        let caller = BackendBrowserScrapingCaller.native(context)
        func arg(_ index: Int) -> NativeRPCValue { context.argument(index, in: args) }
        try await authorize(caller, channel, nil, nil, .array(args))
        switch channel {
        case "browser-worker:list": return try await currentWorkerView(caller)
        case "browser-worker:ensure":
            let value = try await workers.ensure(arg(0), caller: caller); return try await currentWorkerView(caller, base: value)
        case "browser-worker:register":
            let value = try await workers.register(arg(0).requireString("profile", nonempty: true), caller: caller); return try await currentWorkerView(caller, base: value)
        case "browser-worker:unregister":
            let value = try await workers.unregister(arg(0).requireString("profile", nonempty: true), caller: caller); return try await currentWorkerView(caller, base: value)
        case "browser-worker:pace":
            let value = try await workers.setPace(arg(0), caller: caller); return try await currentWorkerView(caller, base: value)
        case "browser-worker:lift-requests":
            let value = try await inbox.list(caller); inboxWatching[context.ownerID] = caller; return value
        case "browser-worker:lift-answer": return try await inbox.answer(arg(0), caller: caller)
        case "browser-worker:lift", "browser-worker:inject", "browser-worker:forget-lift":
            if let sessionLift {
                return try await BackendBrowserSessionLiftChannels.invoke(channel, arguments: args, context: context,
                    service: sessionLift, workersView: { [self] caller in try await currentWorkerView(caller) })
            }
            throw BackendBrowserScrapingError.unsupported("Authorized WebKit session lifting/injection is not wired. No login data was read, copied or forgotten.")
        case "browser:block-capture", "browser:block-capture-set":
            guard let named = arg(0).string, !named.isEmpty else { return .null }
            let profile: String
            if named == "isolated" {
                guard context.caller == .nativeApp else { throw BackendBrowserScrapingError.denied("The legacy isolated block toggle belongs to the local native app.") }
                profile = "isolated"
            } else { profile = try await resolveProfile(caller, named) }
            try await authorize(caller, channel, profile, nil, .array(args))
            if channel == "browser:block-capture-set" {
                guard arg(1).bool != nil else { return .null }
                _ = try await store.setConfig(profile, patch: .object([.init("checks", .object([.init("screenshotOnBlock", arg(1))]))]))
            }
            return .bool(try await store.blockCapture(profile))
        default:
            let profile = try await resolveProfile(caller, arg(0).string)
            try await authorize(caller, channel, profile, nil, .array(args))
            switch channel {
            case "browser-scraping:config": return try await config(profile, caller: caller)
            case "browser-scraping:config-set": return try await setConfig(profile, patch: arg(1), caller: caller)
            case "browser-scraping:status":
                let fleet = try await currentWorkerView(caller)
                let value = try await store.status(profile, workers: fleet); watching[context.ownerID] = (caller, profile); return value
            case "browser-scraping:capture-clear": return try await store.clearCapture(profile)
            case "browser-scraping:ledger-clear": return try await store.clearLedgers(profile)
            case "browser-scraping:capture-reveal":
                let directory = try await store.paths.capture(profile); try await reveal(caller, directory); return .null
            default: throw BackendBrowserScrapingError.invalid("No implementation for this browser scraping channel.")
            }
        }
    }
    public func tool(_ id: String, args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await authorize(caller, id, args["profileId"].string, nil, args)
        switch id {
        case "browser.workers": return try await currentWorkerView(caller)
        case "browser.worker":
            switch args["action"].string {
            case "take": return try await workers.take(worker: args["worker"].string, holdMS: args["holdMs"], caller: caller)
            case "release": return try await workers.release(worker: args["worker"].requireString("worker", nonempty: true), caller: caller)
            case "renew": return try await workers.release(worker: args["worker"].requireString("worker", nonempty: true), renew: true, holdMS: args["holdMs"], caller: caller)
            default: throw BackendBrowserScrapingError.invalid("Worker action is take, release or renew.")
            }
        case "browser.lift_request":
            let fleet = try await currentWorkerView(caller); return try await inbox.file(args, caller: caller, workers: fleet)
        case "browser.network": return try await network.invoke(args, caller: caller)
        case "assets.rendition": return try await assets.rendition(args, caller: caller)
        case "assets.ledger": return try await assets.ledger(args, caller: caller)
        case "assets.fetch": return try await assets.fetch(args, caller: caller)
        case "assets.coverage": return try await assets.coverage(args, caller: caller)
        case "assets.blocks":
            return try await blockTool(args, caller: caller)
        case "browser.scraping": return try await scrapingTool(args, caller: caller)
        default: throw BackendBrowserScrapingError.invalid("Unknown browser scraping tool.")
        }
    }
    private func blockTool(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        guard !caller.remote else { throw BackendBrowserScrapingError.denied("Block evidence is local profile data and is not granted to paired devices.") }
        let selected: [String]
        if let profile = args["profileId"].string, !profile.isEmpty { selected = [try await resolveProfile(caller, profile)] }
        else { selected = Array(Set(try await profiles(caller).map(\.id))).sorted() }
        var records: [(String, NativeRPCValue)] = [], off: [String] = [], excluded = 0
        for profile in selected {
            do { try await authorize(caller, "assets.blocks", profile, nil, args) }
            catch let error as NativeRPCError where error.code == "access-denied" {
                if args["profileId"].string != nil { throw error }; excluded += 1; continue
            }
            let captureOn = try await store.blockCapture(profile)
            if !captureOn { off.append(profile) }
            for row in try await store.blockRecords(profile) {
                let address = row["evidence"]["finalUrl"].string.flatMap { $0.isEmpty ? nil : $0 } ?? row["evidence"]["requestedUrl"].string ?? ""
                guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") else { excluded += 1; continue }
                do { try await authorize(caller, "assets.blocks", profile, url, args) }
                catch let error as NativeRPCError where error.code == "access-denied" { excluded += 1; continue }
                records.append((profile, row))
            }
        }
        let since = args["since"].number
        let filtered = records.filter { since == nil || ($0.1["at"].number ?? 0) >= since! }.sorted { ($0.1["at"].number ?? 0) > ($1.1["at"].number ?? 0) }
        let limit = BackendBrowserScrapingIO.integer(args["limit"], default: 20, min: 1, max: 200)
        let shots = filtered.prefix(limit).map { profile, row -> NativeRPCValue in
            let evidence = row["evidence"], rawURL = evidence["finalUrl"].string.flatMap { $0.isEmpty ? nil : $0 } ?? evidence["requestedUrl"].string ?? ""
            return .object([.init("at", row["at"]), .init("profileId", .string(profile)), .init("url", .string(Self.scrubURL(rawURL))),
                .init("httpStatus", evidence["httpStatus"]), .init("title", evidence["title"]), .init("signals", row["verdict"]["signals"]),
                .init("screenshot", row["path"]), .init("evidence", row["sidecar"]), .init("note", row["note"])])
        }
        let empty = filtered.isEmpty
        var emptyReason = ""
        if empty {
            emptyReason = since == nil ? "No refusing page was photographed in the profiles and origins granted to this caller. Nothing blocked and nothing observed are different possibilities."
                : "No granted block evidence matched since. \(records.count) older granted records remain; drop since to inspect them."
            if !off.isEmpty { emptyReason += " Block capture is off for \(off.joined(separator: ", "))." }
        }
        let paths = await store.paths
        return .object([.init("folder", .string(paths.dataRoot.appendingPathComponent("scrape/blocks").path)),
            .init("total", .number(Double(filtered.count))), .init("shots", .array(shots)), .init("empty", .bool(empty)), .init("emptyReason", .string(emptyReason)),
            .init("scope", .string("granted-profiles-and-origins")), .init("offProfiles", .array(off.map(NativeRPCValue.string))),
            .init("excludedByGrants", .number(Double(excluded))), .init("legacyUnownedIncluded", .bool(false))])
    }
    private static func scrubURL(_ string: String) -> String {
        guard var url = URLComponents(string: string) else { return string }
        url.user = nil; url.password = nil
        let secret = Set(["x-amz-signature", "x-amz-security-token", "x-amz-credential", "signature", "sig", "token", "access_token", "key", "apikey", "api_key", "password", "policy", "expires", "hmac", "auth"])
        url.queryItems = url.queryItems?.map { .init(name: $0.name, value: secret.contains($0.name.lowercased()) ? "…" : $0.value) }
        return url.string ?? string
    }
    private func scrapingTool(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        let action = args["action"].string ?? "config"
        if action == "workers" {
            let value = try await workers.ensure(args["count"], caller: caller); return try await currentWorkerView(caller, base: value)
        }
        if action == "pace" {
            let value = try await workers.setPace(.object([.init("maxConcurrent", args["concurrency"]), .init("minDelayMs", args["delayMs"]), .init("jitterMs", args["jitterMs"])]), caller: caller)
            return try await currentWorkerView(caller, base: value)
        }
        if action == "forgetlift" {
            try await authorize(caller, "browser.scraping.forgetlift", nil, nil, args)
            if let sessionLift, let context = caller.rpc, context.caller == .nativeApp {
                return try await BackendBrowserSessionLiftChannels.invoke("browser-worker:forget-lift", arguments: [args["lift"]], context: context,
                    service: sessionLift, workersView: { [self] caller in try await currentWorkerView(caller) })
            }
            throw BackendBrowserScrapingError.unsupported("Forgetting a held WebKit session needs the supplied lift service and a trusted native-app caller context.")
        }
        let profile = try await resolveProfile(caller, args["profile"].string)
        try await authorize(caller, "browser.scraping." + action, profile, nil, args)
        switch action {
        case "config": return try await config(profile, caller: caller)
        case "set": return try await setConfig(profile, patch: args["patch"], caller: caller)
        case "status":
            let fleet = try await currentWorkerView(caller), requests = try await inbox.list(caller)
            let value = try await store.status(profile, workers: fleet)
            return value.setting("liftRequests", requests)
        case "clearcapture": return try await store.clearCapture(profile)
        case "clearledgers": return try await store.clearLedgers(profile)
        case "showcapture":
            let directory = try await store.paths.capture(profile); try await reveal(caller, directory)
            return .object([.init("shown", .bool(true)), .init("directory", .string(directory.path))])
        case "blockshots":
            if args["on"].bool != nil { return try await store.setConfig(profile, patch: .object([.init("checks", .object([.init("screenshotOnBlock", args["on"])]))])) }
            return try await store.config(profile)["checks"]["screenshotOnBlock"]
        case "addworker":
            let value = try await workers.register(profile, caller: caller); return try await currentWorkerView(caller, base: value)
        case "removeworker":
            let value = try await workers.unregister(profile, caller: caller); return try await currentWorkerView(caller, base: value)
        default: throw BackendBrowserScrapingError.invalid("Unknown scraping action.")
        }
    }
    private func config(_ profile: String, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        let fleet = try await currentWorkerView(caller), config = try await store.config(profile)
        return config.setting("fleet", .object([.init("profileIds", .array(fleet["workers"].elements?.map { $0["profileId"] } ?? [])),
            .init("concurrency", fleet["pace"]["maxConcurrent"]), .init("delayMs", fleet["pace"]["minDelayMs"])]))
    }
    private func setConfig(_ profile: String, patch: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        if patch["fleet"].fields != nil {
            let view = try await currentWorkerView(caller)
            _ = try await workers.setPace(.object([.init("maxConcurrent", patch["fleet"]["concurrency"].isNullish ? view["pace"]["maxConcurrent"] : patch["fleet"]["concurrency"]),
                .init("minDelayMs", patch["fleet"]["delayMs"].isNullish ? view["pace"]["minDelayMs"] : patch["fleet"]["delayMs"]),
                .init("jitterMs", view["pace"]["jitterMs"])]), caller: caller)
        }
        _ = try await store.setConfig(profile, patch: patch.removing("fleet"))
        return try await config(profile, caller: caller)
    }
    /// Call from the injected changed callbacks. Publish one caller's profile
    /// data only to that owner. Revoked watchers are removed immediately.
    public func publishChanged(on registry: NativeChannelRegistry, profile: String? = nil) async {
        for (owner, entry) in watching where profile == nil || entry.1 == profile {
            do {
                try await authorize(entry.0, "browser-scraping:status", entry.1, nil, .object([]))
                let fleet = try await currentWorkerView(entry.0), value = try await store.status(entry.1, workers: fleet)
                try await registry.publish("browser-scraping:changed", arguments: [value], ownerID: owner)
            } catch { watching[owner] = nil }
        }
        for (owner, caller) in inboxWatching {
            do {
                let requests = try await inbox.list(caller)
                try await registry.publish("browser-worker:lift-request", arguments: [requests], ownerID: owner)
            }
            catch { inboxWatching[owner] = nil }
        }
    }
    public func disconnect(_ caller: BackendBrowserScrapingCaller) async {
        watching[caller.ownerID] = nil; inboxWatching[caller.ownerID] = nil
        await workers.releaseAll(holder: caller.holder); await network.disconnect(caller); await inbox.disconnect(caller.holder)
    }
}
