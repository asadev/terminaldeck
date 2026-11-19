import Foundation
import MachO
import CryptoKit
import SystemConfiguration
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Production assembly injects public endpoints and the existing protected-store owner.
/// Fixtures keep Runtime.cloudAccount nil or inject their in-process service explicitly.
@MainActor
enum NativeCloudApplication {
    /// True whenever a test bundle is loaded into this process, whichever runner started it (`swift test`'s
    /// swiftpm-testing-helper, xctest, Xcode). Decided only from what is loaded, never from environment variables, so
    /// the shipped app (which never loads an `.xctest` bundle or the XCTest/Testing frameworks) cannot be made to
    /// look like a test, and a test can never reach production configuration.
    nonisolated static var isTestProcess: Bool {
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        // swiftpm-testing-helper loads the test bundle's binary with dlopen, which Bundle.allBundles may not list.
        for index in 0..<_dyld_image_count() {
            if let name = _dyld_get_image_name(index), String(cString: name).contains(".xctest/") { return true }
        }
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("packagetests")
    }
    /// The app's live owners for saved passwords, set by the app's composition once its Servers and voice owners
    /// exist (`NativeCompositionRoot`). nil in fixtures. Asked only when an account is being built AND saved
    /// passwords are switched on (`NativeCloudSecretsSwitch`), so a release build before the proof never calls it.
    static var liveSecrets: (@MainActor (_ appName: String) throws -> NativeCloudSecretsLive?)?
    /// Saved passwords' hand-over for this account, or nil: then nothing of saved passwords is built.
    static func secretsHandOver(appName: String) -> NativeCloudSecretsLive? {
        guard NativeCloudSecretsSwitch.on, let liveSecrets else { return nil }
        return try? liveSecrets(appName)
    }
    /// The app's live owners for projects and agents (lane A2), or nil while those rows are not switched on: then
    /// nothing of them is built and the owners are not even looked up.
    static func recordsHandOver(root: BackendCompositionRoot) -> NativeCloudRecordsLive? {
        guard !NativeCloudBrainRegistration.recordRows.isEmpty else { return nil }
        return NativeCloudRecordsOwners.live(root: root)
    }
    /// Would `make` build an account for this copy? Read from the bundle and the folder's ownership only: nothing is
    /// constructed, requested or stored. False in a test process, a read-only data folder or without the public key.
    static func canSignIn(root: BackendCompositionRoot) -> Bool {
        var scratch = false
        #if DEBUG
        scratch = NativeCloudScratch.plan(environment: ProcessInfo.processInfo.environment, dataRoot: root.dataRoot) != nil
        #endif
        return canSignIn(testProcess: isTestProcess, readOnly: root.state.ownership == .readOnly,
                         appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
                         publishableKey: Bundle.main.object(forInfoDictionaryKey: "TDCloudStorePublishableKey") as? String, scratch: scratch)
    }
    nonisolated static func canSignIn(testProcess: Bool, readOnly: Bool, appName: String?, publishableKey: String?, scratch: Bool) -> Bool {
        guard !testProcess, !readOnly, let appName, !appName.isEmpty else { return false }
        return scratch || publishableKey.map(CloudAccountConfiguration.isPublicStoreKey) == true
    }
    /// This Mac's name as the account lists it ("name.local"). Two-Mac proof (13 Nov): the first Sign in press took
    /// 35 seconds before the browser opened because `ProcessInfo.hostName` resolved the name over the network (mDNS,
    /// behind macOS's local-network question) on the main thread while the account was being built. The local host
    /// name is read from the system's own configuration instead: no network, well under a millisecond, same text.
    nonisolated static func localDeviceName() -> String {
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { return local + ".local" }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return "Mac"
    }
    static func make(root: BackendCompositionRoot) async throws -> BackendCloudAccount? {
        BackendCloudTrace.note("account-factory")
        guard !isTestProcess else { throw CloudFailure.unsafeConfiguration }
        guard root.state.ownership != .readOnly else { return nil }
        guard let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, !appName.isEmpty else { throw CloudFailure.unsafeConfiguration }
        #if DEBUG
        // Proof P3 only: a scratch copy pointed at the TEST service (see NativeCloudScratch). Never in a release build.
        if let plan = NativeCloudScratch.plan(environment: ProcessInfo.processInfo.environment, dataRoot: root.dataRoot) {
            NativeCloudScratch.adopt(plan)
            let scratch = try CloudAccountConfiguration(baseURL: plan.base, issuer: plan.issuer, websiteStartURL: plan.start, storeAuthURL: plan.auth,
                publishableKey: plan.key, deviceLabel: String((localDeviceName() + " " + root.dataRoot.deletingLastPathComponent().lastPathComponent).prefix(80)),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", environment: .fixture)
            if let file = plan.signInURLFile {
                NativeCloudAccount.shared.useSignInOpener { url in try? Data(url.absoluteString.utf8).write(to: file, options: .atomic) }
            }
            let scratchInstance = NativeCloudAccountHash.hash(root.dataRoot.path)
            return try assemble(configuration: scratch, dataRoot: root.dataRoot,
                                protectedStore: .keychain(appName: appName, instanceId: scratchInstance),
                                trustSlot: { .keychain(appName: appName, instanceId: scratchInstance, subjectHash: $0) },
                                secrets: secretsHandOver(appName: appName), records: recordsHandOver(root: root))
        }
        #endif
        // The existing Store gateway requires its public client key for refresh after access-token expiry.
        // Release tooling injects this public configuration; there is no user setup field or local feature switch.
        guard let publishableKey = Bundle.main.object(forInfoDictionaryKey: "TDCloudStorePublishableKey") as? String,
              CloudAccountConfiguration.isPublicStoreKey(publishableKey) else { return nil }
        let config = try CloudAccountConfiguration(baseURL: URL(string: CloudWire.productionBase)!, issuer: CloudWire.issuer,
            websiteStartURL: URL(string: "https://terminaldeck.dev/api/store/cloud/start")!, storeAuthURL: URL(string: CloudWire.issuer)!,
            publishableKey: publishableKey, deviceLabel: String(localDeviceName().prefix(80)),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", environment: .production)
        let instance = NativeCloudAccountHash.hash(root.dataRoot.path)
        return try assemble(configuration: config, dataRoot: root.dataRoot,
                            protectedStore: .keychain(appName: appName, instanceId: instance),
                            trustSlot: { .keychain(appName: appName, instanceId: instance, subjectHash: $0) },
                            secrets: secretsHandOver(appName: appName), records: recordsHandOver(root: root),
                            machine: .system(markFile: root.dataRoot.appendingPathComponent("cloud/machine-described"),
                                             copy: BackendCloudMachineFacts.copyName(appName: appName, dataRoot: root.dataRoot)))
    }
    /// `trustSlot` gives the place of this Mac's trusted-device list for one account (by its subject hash): in the app a
    /// Keychain item of its own under this copy's own name, in fixtures whatever the fixture holds.
    /// `secrets` is everything saved passwords (lane V) need from the real app. Without it nothing of saved passwords
    /// is built: no graph, no tool, no page section, no saved-password domain in the sync core.
    /// `make` hands it over only while saved passwords are switched on (`NativeCloudSecretsSwitch`: proof P3's
    /// scratch plan in a debug build; in a release build only after that proof has passed) and the app's Servers
    /// owner exists. Lane V's lean local-store check needs no account vault and no Receiver fence.
    static func assemble(configuration: CloudAccountConfiguration, dataRoot: URL, protectedStore: BackendCloudAccountProtectedStore,
                         trustSlot: @escaping @Sendable (_ subjectHash: String) -> BackendCloudTrustSlot,
                         secrets: NativeCloudSecretsLive? = nil, records: NativeCloudRecordsLive? = nil,
                         machine: BackendCloudMachineFacts? = nil) throws -> BackendCloudAccount {
        if isTestProcess, case .production = configuration.environment { throw CloudFailure.unsafeConfiguration }
        let http = BackendCloudAccountURLSession()
        let identity = BackendCloudAccountIdentity(configuration: configuration, store: protectedStore, http: http)
        let binding = BackendCloudAccountBinding(identity: identity) { session, registration in
            let subject = CloudSubject(issuer: configuration.issuer, sub: session.user.id)
            let subjectHash = NativeCloudAccountHash.hash(configuration.issuer + "\n" + session.user.id)
            let storage = try CloudSyncStore(root: dataRoot.appendingPathComponent("cloud/" + subjectHash), subject: subject)
            let budget = CloudSyncBudget(store: storage)
            let environment: CloudSyncEndpoint.Environment
            switch configuration.environment { case .production: environment = .production; case .fixture: environment = .test }
            let endpoint = try CloudSyncEndpoint(base: configuration.baseURL, environment: environment, objectHosts: [configuration.baseURL.host!])
            let signer: CloudSyncSigner = { payload in BackendCloudAccountIdentity.base64(try await identity.signDevicePayload(payload)) }
            let transport = try CloudSyncTransport(endpoint: endpoint, auth: identity, signer: signer, store: storage, budget: budget)
            let keys = BackendCloudAccountBrainKeys { epoch in try await transport.brainKey(epoch: epoch).key }
            // Lean scope item 4: this Mac's own list of trusted device keys. The sync core asks it for a device's stored
            // key at the moment of applying each pack and decides from that alone (apply, held, refused); the service's
            // device list is never asked who signed a pack.
            let trust = BackendCloudTrustStore(subject: subject, slot: trustSlot(subjectHash),
                                               pressRefused: { BackendRemoteInputGuard.system.refusesPress() })
            // With no memory row switched on the engine is built with no memory domain (sync 8fcfe0d4): it does not read
            // the memory feed, and memory starts from its old position once a row is switched on.
            let domains = NativeCloudBrainRegistration.brainDomains
            let running = NativeCloudBrainRegistration.Running()
            // 13 Nov blocker: every sync failure writes one plain line to engine.log (never a token, key or content).
            CloudSyncDiagnostics.shared.setSink { line in Task { @MainActor in NativeCloudAccount.log(line) } }
            // Saved passwords (lean scope item 3). Both stay empty unless `secrets` was handed in and its graph was built
            // below, before the sync core is first needed. The sync core is the only reader of the event socket, so the
            // service's saved-password notices are shown to the sink on their way to it (never a second socket or a timer).
            let secretsParts = BackendCloudSecretsEngineParts(), secretsEvents = BackendCloudSecretsEventSink(
                statusCache: BackendCloudSecretsStatusCache(holdFirstReadMs: BackendCloudSecretsStatusCache.appHoldFirstReadMs))
            // Reach by account hears `devices` and `gate` on the same socket (the tap only shows events, never holds one).
            // The same `devices` event also makes the Cloud page ask for the account's device list at once (two-Mac proof).
            secretsEvents.listenReach { event in
                NativeReachAccount.event(event)
                if event.type == "devices" { NativeCloudAccount.devicesEvent() }
            }
            let outbox = BackendCloudAccountOutboxFactory {
                let current = try await identity.credentials()
                guard current.user.id == subject.sub else { throw CloudFailure.gateClosed }
                let key = try await transport.brainKey()
                let stillCurrent = try await identity.credentials()
                guard stillCurrent.user.id == subject.sub else { throw CloudFailure.gateClosed }
                let content = try CloudSyncContent(subject: subject.sub, epoch: key.epoch, keyProvider: { epoch in try await keys.key(epoch: epoch) })
                let secretsDomains = secretsParts.domains
                let wire: any CloudTransportPort
                // Always through the tap since reach by account (R2): it hands every call through unchanged.
                wire = BackendCloudSecretsEventTap(upstream: transport, sink: secretsEvents)
                let engine = try CloudSyncEngine(store: storage, transport: wire, objects: transport, content: content, budget: budget,
                    subject: subject.sub, deviceId: registration.deviceId, epoch: key.epoch,
                    brainDomains: domains, secretsDomains: secretsDomains, secretsContent: secretsParts.content,
                    deviceSigner: { deviceId, payload in BackendCloudAccountIdentity.base64(try await identity.signDevicePayload(payload, deviceId: deviceId)) },
                    trust: trust)
                await engine.startEvents()
                // Only integrator-proven rows register (none yet). Enabling runs in the one serialised place (M11), off the
                // engine's construction; it asks the §10 memory question there, never at sign-in (N6).
                await running.attach(.init(engine: engine, deviceId: registration.deviceId, subjectHash: subjectHash,
                                           dataRoot: dataRoot, displayName: session.user.displayName, records: records,
                                           firstArrivalConfirmed: { await trust.hasDeviceTrustedByPress() }))
                await MainActor.run { NativeCloudBrainRegistration.current = running }
                // Mac shelf (15 Nov): what is in his Cloud now, for his phones and the web when every Mac is off. Its own
                // door on the transport (never sync's back-off); its small state beside this identity's sync store.
                let shelfFile = dataRoot.appendingPathComponent("cloud/" + subjectHash + "/shelf.json")
                await MainActor.run {
                    NativeCloudShelf.shared.attach(send: { method, path, body in try await transport.shelf(method: method, path: path, body: body) },
                                                   file: shelfFile)
                    // The "Sessions and chats" switch of Settings › Cloud › Keep in sync on this Mac (same-everywhere).
                    NativeCloudChats.sessionsAndChatsInSync = { NativeCloudSyncChoices.shared.isOn(.sessions) }
                    // Sessions in the Cloud (15 Nov, step 1): this Mac's list and its sessions' chats, through the
                    // transport's own chats door (never sync's back-off); its small state beside the shelf's.
                    NativeCloudChats.shared.attach(send: { method, path, body in try await transport.chats(method: method, path: path, body: body) },
                                                   directory: dataRoot.appendingPathComponent("cloud/" + subjectHash + "/chats", isDirectory: true),
                                                   deviceId: registration.deviceId)
                }
                // The id join (15 Nov): this Mac's `machine` as the Cloud's session rows name it (the service's rule:
                // its machineId, else its device id), in the live session list's header for phones and the web.
                BackendCloudChatsMachine.shared.set(BackendCloudChats.machineRef(subject: session.user.id,
                    machine: machine?.pair(subject: session.user.id)?.machineId ?? registration.deviceId))
                // Step 2: the socket's "a session is being moved, look" reaches the sessions driver.
                await transport.onSessionsMoved { refs in NativeCloudChats.movesHinted(refs) }
                Task { try? await running.enable() }
                return engine
            }
            // One graph per subject + device, sealed with these ports and never carried to another identity.
            let savedPasswords: BackendCloudSecretsGraph?
            // Same everywhere (15 Nov): "Saved passwords and secret files" switched off on this Mac = not wired here.
            if let secrets, NativeCloudSyncChoices.isOn(.secrets, dataRoot: dataRoot) {
                // Lane V's nine routes go out through the transport's own sender: same token, same device proof, same budget.
                let control = BackendCloudSecretsLean.control(send: { method, path, body, requestId in
                    try await transport.control(method: method, path: path, body: body, requestId: requestId)
                }, devices: { try await transport.devices() }, statusCache: secretsEvents.statusCache)
                // The gate is judged against the sync core's service-corrected time once it is known.
                let now: @Sendable () -> Int64 = { outbox.serviceTime() ?? Int64(Date().timeIntervalSince1970 * 1000) }
                let gate = BackendCloudSecretsGate(fetch: { try await transport.capabilities() }, now: now)
                // Automatic hand-over (owner, 14 Nov; on by default): a new device of his account opens by itself, only
                // from a device THIS Mac's own trusted-device list holds with exactly that signing key, only for a
                // request that device SIGNED (checked with the key pinned here), once per device per key generation
                // (recorded beside the key, before the answer goes out). His stricter setting ("Ask me on each new
                // device") is read by the coordinator from beside the key, never from a file.
                let automatic: CloudSecretsAutoTrust? = NativeCloudSecretsSwitch.automaticHandOver ? CloudSecretsAutoTrust(
                    on: { true },
                    pinned: { deviceId in
                        guard let entry = await trust.entry(deviceId: deviceId), entry.trusted else { return nil }
                        // The kind of device as THIS Mac kept it with the key (review blocker 1: computers only).
                        return .init(name: entry.name, signKey: entry.signKey, platform: entry.platform.flatMap(CloudPlatform.init(rawValue:)))
                    }) : nil
                savedPasswords = await NativeCloudSecretsAssembly.attach(secrets, subject: subject, registration: registration, identity: identity,
                    control: control, gate: gate, now: now, outbox: outbox, dataRoot: dataRoot, engine: secretsParts, sink: secretsEvents,
                    automatic: automatic)
                // At start: finish a waiting acknowledgement, or join the sync core and send what changed. Off this path.
                if let savedPasswords {
                    Task { await savedPasswords.catchUp() }
                    // The switch turned off later in this run seals them at once (nothing deleted anywhere).
                    await MainActor.run { NativeCloudSyncChoices.shared.sealSecrets = { await NativeCloudSecretsAssembly.seal(savedPasswords, sink: secretsEvents) } }
                }
            } else { savedPasswords = nil }
            return .init(transport: transport, outbox: outbox, trust: trust, seal: {
                if let savedPasswords { await NativeCloudSecretsAssembly.seal(savedPasswords, sink: secretsEvents) }
                await running.stop()
                await MainActor.run {
                    if NativeCloudBrainRegistration.current === running { NativeCloudBrainRegistration.current = nil }
                    NativeCloudShelf.shared.detach()
                    NativeCloudChats.shared.detach()
                }
                BackendCloudChatsMachine.shared.set(nil)
                await keys.discard()
            })
        }
        return BackendCloudAccount(configuration: configuration, identity: identity, http: http, ports: { try await binding.resolve() }, machine: machine,
                                   deviceDoor: { try await NativeCloudApplication.deviceDoor(configuration: configuration, dataRoot: dataRoot, identity: identity) })
    }
    /// 19 Nov free plan: the service's device door for a free account's sign-in (`POST /devices`, so the account's other
    /// devices reach this Mac through the relay). The same transport the sync ports use, on the same per-identity store,
    /// but nothing else: no sync engine, no saved passwords, no event socket, no Cloud folder.
    nonisolated static func deviceDoor(configuration: CloudAccountConfiguration, dataRoot: URL, identity: BackendCloudAccountIdentity) async throws
        -> any CloudTransportPort {
        let session = try await identity.credentials()
        let subject = CloudSubject(issuer: configuration.issuer, sub: session.user.id)
        let subjectHash = NativeCloudAccountHash.hash(configuration.issuer + "\n" + session.user.id)
        let storage = try CloudSyncStore(root: dataRoot.appendingPathComponent("cloud/" + subjectHash), subject: subject)
        let environment: CloudSyncEndpoint.Environment
        switch configuration.environment { case .production: environment = .production; case .fixture: environment = .test }
        guard let host = configuration.baseURL.host else { throw CloudFailure.unsafeConfiguration }
        let endpoint = try CloudSyncEndpoint(base: configuration.baseURL, environment: environment, objectHosts: [host])
        let signer: CloudSyncSigner = { payload in BackendCloudAccountIdentity.base64(try await identity.signDevicePayload(payload)) }
        return try CloudSyncTransport(endpoint: endpoint, auth: identity, signer: signer, store: storage, budget: CloudSyncBudget(store: storage))
    }
}

extension NativeCloudApplication {
    /// The per-identity folder name under `D/cloud`; the same value the account assembly uses.
    nonisolated static func subjectHash(issuer: String, userId: String) -> String { NativeCloudAccountHash.hash(issuer + "\n" + userId) }
}

enum NativeCloudAccountHash {
    nonisolated static func hash(_ string: String) -> String {
        // Public composition values only; CryptoKit stays behind the existing core hashing helper.
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
