import Foundation

/// Setup/recovery is separate from all logical stores, especially the team roster.
/// Failure cannot clear, migrate, rotate or replace any existing local store.
public actor CloudRecoveryCoordinator {
    private let subject: CloudSubject
    public let device: CloudDeviceRegistration
    private let keys: any CloudDeviceKeyPort
    private let local: any CloudSecretsLocalKeyPort
    private let control: any CloudSecretsControlPort
    private let words: any CloudRecoveryWordsCodec
    private let interaction: any CloudSecretsInteractionPort
    private let policy: CloudSecretsPolicy
    private let resetTicket: @Sendable () async throws -> String
    private var busy = false
    private var requestedApproval: CloudApproval?
    /// An envelope already waiting before this request was made (an earlier,
    /// ended attempt). It is not this request's answer and never prompts.
    private var staleEnvelope: CloudDeviceKeyEnvelope?
    /// The last acknowledgment for this request may have reached the server
    /// although its answer did not arrive (transport failure).
    private var possessionUnconfirmed = false
    /// Set once the server accepted a new vault in setup/reset: from then on the
    /// words are the only copy until the local save, so a cancellation keeps
    /// the "did not finish, keep these words" sheet instead of wiping it.
    private var vaultCreated = false
    /// From the server's acceptance until the local save: the words are the
    /// only copy, so sign-out or gate-off keeps them on screen (round-6 S-1).
    private var wordsStillNeeded = false
    /// Owner's decision (14 Nov): under "Automatically, with my account" the hand-over needs no code and no click.
    /// nil (fixtures, older wiring) = the earlier behaviour exactly: sheets and codes on both sides.
    private var automatic: CloudSecretsAutoTrust?
    /// This Mac's current request was signed for the automatic hand-over (no code was shown).
    private var signedRequest = false
    /// Whether this account has recovery words, once known (the recovery copy is a placeholder after a silent set-up).
    private var wordsKnown: Bool?
    private var wordsAsked = false
    public init(subject: CloudSubject, device: CloudDeviceRegistration, keys: any CloudDeviceKeyPort,
                local: any CloudSecretsLocalKeyPort, control: any CloudSecretsControlPort,
                words: any CloudRecoveryWordsCodec, interaction: any CloudSecretsInteractionPort,
                policy: CloudSecretsPolicy, resetTicket: @escaping @Sendable () async throws -> String) {
        self.subject = subject; self.device = device; self.keys = keys; self.local = local; self.control = control
        self.words = words; self.interaction = interaction; self.policy = policy; self.resetTicket = resetTicket
    }
    public func use(automatic value: CloudSecretsAutoTrust?) { automatic = value }
    /// The app's log (`CloudSecretsLog`: names and plain words only). Fixtures: nothing, or a list they scan.
    private var log = CloudSecretsLog.none
    public func use(log value: CloudSecretsLog) { log = value }
    /// The passkey sheet offers itself at most once per app start (and not for a day after he cancelled it).
    private var spareOfferedThisRun = false
    private var spareUnavailableSaid = false
    /// Each automatic refusal is said once per request and reason (the graph looks several times).
    private var refusalsSaid: Set<String> = []
    private func refusal(_ approvalId: String, _ why: String) {
        guard refusalsSaid.insert(approvalId + "|" + why).inserted else { return }
        if refusalsSaid.count > 256 { refusalsSaid = [approvalId + "|" + why] }
        log.say("did not answer " + why)
    }
    /// PASSWORDS-5 point 6: ONE source for a device's name in the log and on the page: the account's device list by its
    /// friendly name ("Studio Mac mini"), then a friendly name the service gave with the fact itself (`shown`, e.g. the
    /// spare's `addedByName`), then the name THIS Mac kept when it trusted the device, then `fallback` (a recorded
    /// label). "this Mac" for itself. Display only.
    private func nameOf(_ deviceId: String, shown: String? = nil, fallback: String? = nil) async -> String {
        if deviceId == device.deviceId { return "this Mac" }
        if let friendly = await friendlyNames(needing: deviceId)[deviceId]?.name { return CloudSecretsLog.name(friendly) }
        if let shown, !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return CloudSecretsLog.name(shown) }
        if let automatic, let pinned = await automatic.pinned(deviceId) { return CloudSecretsLog.name(pinned.name) }
        return CloudSecretsLog.name(fallback)
    }
    /// The account's device list (friendly names, who holds the key), read at most once a minute, plus once for a device
    /// it did not list yet (one that just joined); kept for the run.
    private var friendly: [String: CloudSecretsDeviceName] = [:]
    private var friendlyReadAt: Int64?
    private var friendlyMissed: Set<String> = []
    private func friendlyNames(needing id: String? = nil) async -> [String: CloudSecretsDeviceName] {
        guard let port = control as? any CloudSecretsDeviceNamesPort else { return friendly }
        let now = policy.now()
        let fresh = friendlyReadAt.map { now >= $0 && now - $0 < 60_000 } ?? false
        if fresh {
            guard let id, friendly[id] == nil, friendlyMissed.insert(id).inserted else { return friendly }
        } else { friendlyMissed = [] }
        friendlyReadAt = now
        guard let list = try? await port.deviceNames() else { return friendly }
        var next: [String: CloudSecretsDeviceName] = [:]
        for entry in list where !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next[entry.deviceId] = entry }
        friendly = next
        return friendly
    }
    /// PASSWORDS-5 point 1: the passkey sheet this Mac has open now (its key generation and the passkey that shows it).
    private var spareSheet: (epoch: Int, passkey: any CloudSecretsPasskeyPort, replacing: Bool)?
    /// Why the open sheet was withdrawn (the log line is already written); nil = not withdrawn.
    private var spareSheetWithdrawn: String?
    /// Waits the given milliseconds (the app: a real sleep). Used only to withdraw an open passkey sheet when its
    /// one-time challenge runs out. Tests replace it.
    private var sleep: @Sendable (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }
    func use(sleep value: @escaping @Sendable (Int64) async -> Void) { sleep = value }
    /// The sheet was withdrawn by this Mac (a spare was made elsewhere, or its challenge ran out): not his cancel.
    struct SpareSheetWithdrawn: Error {}
    /// The service refused the add while this generation already had a spare: the passkey just made may have replaced
    /// the one that spare was sealed for (point 4).
    struct SpareOrphaned: Error {}
    /// The automatic answer could not read the requests' signatures (not a mismatch).
    struct SignatureFetchFailed: Error { let underlying: any Error }
    /// Tests only: a new app start (the once-per-start rule starts over; the book beside the key stays).
    func forgetThisRun() { spareOfferedThisRun = false; spareUnavailableSaid = false }
    /// True while automatic hand-over is wired on this Mac (the requesting side signs its request; the receiving side
    /// takes the key from a device its own list holds). The owner's stricter setting is checked separately, on the
    /// ANSWERING side only (`answersBySelf`).
    private func automaticOn() async -> Bool {
        guard let automatic else { return false }
        return await automatic.on()
    }
    // MARK: the hand-over book (beside the key) and the stricter setting
    private var bookPort: (any CloudSecretsHandOverBookPort)? { local as? any CloudSecretsHandOverBookPort }
    /// The book as stored; nil when this store keeps none or it cannot be read (callers fail safe).
    private func readBook() async -> CloudSecretsHandOverBook? {
        guard let bookPort else { return nil }
        do { return try await bookPort.handOverBook() ?? CloudSecretsHandOverBook() } catch { return nil }
    }
    /// A relayed stricter setting is taken only when it is signed by THIS Mac or by a device THIS Mac's own list
    /// holds as trusted, with the signing key pinned here, and only when it is newer than what this Mac knows (an
    /// older one replayed never switches it back). A time more than 5 minutes ahead is refused (it would pin the
    /// setting against every later change).
    /// Review blocker 2: a relayed setting may only switch the stricter setting ON. Switching it OFF happens only by
    /// his own press on that Mac (each Mac separately), so a fake device the account lists cannot weaken any Mac.
    private func adoptRelayedPolicy(_ book: inout CloudSecretsHandOverBook, found: CloudSecretsAskPolicy?) async {
        guard let found = await verifiedPolicy(found), found.askOnNewDevice, found.at > book.policyAt else { return }
        var next = book
        next.askOnNewDevice = true; next.policyAt = found.at
        guard (try? await bookPort?.saveHandOverBook(next)) != nil else { return }
        book = next
        log.say("took the stricter setting (ask on each new device) switched on by " + (await nameOf(found.by)))
    }
    /// The relayed record when its signature holds (by this Mac, or by a device pinned here) and its time is not more
    /// than 5 minutes ahead; nil otherwise.
    private func verifiedPolicy(_ found: CloudSecretsAskPolicy?) async -> CloudSecretsAskPolicy? {
        guard let found, found.at <= policy.now() + 300_000 else { return nil }
        let key: CloudPublicJWK
        if found.by == device.deviceId { key = device.signPublicJwk }
        else if let automatic, let pinned = await automatic.pinned(found.by) { key = pinned.signKey }
        else { return nil }
        guard (try? CloudSecretsCrypto.verify(found.signature, bytes: CloudSecretsProof.askPolicy(sub: subject.sub,
            askOnNewDevice: found.askOnNewDevice, at: found.at, by: found.by), key: key)) != nil else { return nil }
        return found
    }
    /// What the service relays about the stricter setting, from ONE status read. `turnedOff` (service 72959fbbd) is
    /// unsigned: it is shown and never adopted. `newService`: the service sends its new optional facts (today's live
    /// service does not, and then everything below behaves exactly as before).
    private struct Relayed {
        var found: CloudSecretsAskPolicy?
        var turnedOff: CloudSecretsStatusFacts.Change?
        var newService = false
        var reached = false
    }
    private func relayedPolicy() async -> Relayed {
        guard let relay = control as? any CloudSecretsPolicyRelayPort else { return .init() }
        if let facts = control as? any CloudSecretsStatusFactsPort {
            do {
                let read = try await facts.statusFacts().facts
                return .init(found: read.askPolicy, turnedOff: read.turnedOff, newService: read.newService, reached: true)
            } catch { return .init() }
        }
        do { return .init(found: try await relay.publishedPolicy(), reached: true) } catch { return .init() }
    }
    /// The owner's stricter setting as THIS Mac applies it ("Ask me on each new device"). Unreadable or not kept =
    /// true (a person decides).
    public func askOnNewDevice() async -> Bool {
        guard var book = await readBook() else { return true }
        await adoptRelayedPolicy(&book, found: await relayedPolicy().found)
        return book.askOnNewDevice
    }
    /// What the Cloud page shows beside the switch, from ONE read of the service:
    /// - `on`: the setting as this Mac applies it (a relayed "on" taken first);
    /// - `offElsewhere`: he switched it off on another of his devices (the service's plain `askPolicyTurnedOff`, or a
    ///   signed off record, newer than this Mac's setting) while it is still on here. DISPLAY ONLY: neither ever
    ///   changes this Mac's own setting (only his press here does);
    /// - `thisMacOnly`: it is on here and the service does not carry it to his other devices (no route, or the
    ///   last publish did not get through).
    public func askState() async -> CloudSecretsAskState {
        guard var book = await readBook() else { return .init(on: true, offElsewhere: false, thisMacOnly: false) }
        let relayed = await relayedPolicy()
        await adoptRelayedPolicy(&book, found: relayed.found)
        guard book.askOnNewDevice else { return .init(on: false, offElsewhere: false, thisMacOnly: false) }
        let verified = await verifiedPolicy(relayed.found)
        let signedOff = verified.map { !$0.askOnNewDevice && $0.at > book.policyAt } ?? false
        // The service never signs an OFF (72959fbbd): it says who switched it off and when, as a plain fact. Shown when
        // another device did it after this Mac's own setting; this Mac's book is not touched.
        let plainOff = relayed.turnedOff.map { $0.by != device.deviceId && $0.at > book.policyAt } ?? false
        let offElsewhere = signedOff || plainOff
        let carried = control is any CloudSecretsPolicyRelayPort && (!relayed.reached || (relayed.found.map { $0.at >= book.policyAt } ?? false))
        // One line, not two: "switched off on another device" already says the others do not carry it.
        return .init(on: true, offElsewhere: offElsewhere, thisMacOnly: book.policyAt > 0 && !carried && !offElsewhere)
    }
    /// A Mac with no key yet: what the setting probably is, for its one waiting line only (never for a decision).
    /// The new service sends `askPolicy` only while the setting is ON; `askPolicyTurnedOff`, or no field at all, is
    /// "off". Today's service (no new facts) is read exactly as before.
    public func askHint() async -> Bool {
        let relayed = await relayedPolicy()
        if relayed.reached {
            if relayed.newService || relayed.turnedOff != nil { return relayed.found?.askOnNewDevice ?? false }
            if let found = relayed.found { return found.askOnNewDevice }
        }
        return await readBook()?.askOnNewDevice ?? false
    }
    /// The switch on the Cloud page. Kept beside the key FIRST (so this Mac applies it at once), then signed and handed
    /// to the service for his other devices. Returns false when the service could not carry it (kept on this Mac only).
    @discardableResult
    public func setAskOnNewDevice(_ value: Bool) async throws -> Bool {
        try await permitted()
        guard let bookPort, var book = await readBook() else { throw CloudFailure.unavailable }
        let at = max(policy.now(), book.policyAt + 1)
        book.askOnNewDevice = value; book.policyAt = at
        try await bookPort.saveHandOverBook(book)
        guard let relay = control as? any CloudSecretsPolicyRelayPort else { return false }
        do {
            let signature = try await keys.signDevicePayload(CloudSecretsProof.askPolicy(sub: subject.sub, askOnNewDevice: value, at: at, by: device.deviceId))
            try await relay.publishPolicy(requestId: UUID().uuidString.lowercased(),
                policy: .init(askOnNewDevice: value, at: at, by: device.deviceId, signature: CloudSecretsCrypto.encode(signature)))
            return true
        } catch { return false }
    }
    // MARK: his phones (15 Nov)

    /// "Keep saved passwords and secret files off my phones" as THIS Mac applies it (off by default). Unreadable or not
    /// kept = true: nothing reaches a phone when this Mac cannot tell. A relayed ON is taken first when it is signed by
    /// this Mac or by a COMPUTER pinned here, is newer than this Mac's own setting and not more than 5 minutes ahead.
    public func phonesOff() async -> Bool {
        guard var book = await readBook() else { return true }
        await adoptRelayedPhones(&book)
        return book.phonesOff == true
    }
    private func adoptRelayedPhones(_ book: inout CloudSecretsHandOverBook) async {
        guard let relay = control as? any CloudSecretsPhonesPolicyRelayPort, let found = try? await relay.publishedPhonesPolicy(),
              found.phonesOff, found.at > (book.phonesOffAt ?? 0), found.at <= policy.now() + 300_000 else { return }
        let key: CloudPublicJWK
        if found.by == device.deviceId { key = device.signPublicJwk }
        else if let automatic, let pinned = await automatic.pinned(found.by), pinned.isComputer { key = pinned.signKey }
        else { return }
        guard (try? CloudSecretsCrypto.verify(found.signature, bytes: CloudSecretsProof.phonesPolicy(sub: subject.sub, phonesOff: true,
            at: found.at, by: found.by), key: key)) != nil else { return }
        var next = book
        next.phonesOff = true; next.phonesOffAt = found.at
        guard (try? await bookPort?.saveHandOverBook(next)) != nil else { return }
        book = next
        log.say("took the setting that keeps saved passwords off your phones, switched on by " + (await nameOf(found.by)))
    }
    /// The phones switch on the Cloud page (his press only). Kept beside the key FIRST, then signed and handed to the
    /// service for his other Macs. Returns false when the service could not carry it (kept on this Mac only).
    @discardableResult
    public func setPhonesOff(_ value: Bool) async throws -> Bool {
        try await permitted()
        guard let bookPort, var book = await readBook() else { throw CloudFailure.unavailable }
        let at = max(policy.now(), (book.phonesOffAt ?? 0) + 1)
        book.phonesOff = value; book.phonesOffAt = at
        try await bookPort.saveHandOverBook(book)
        guard let relay = control as? any CloudSecretsPhonesPolicyRelayPort else { return false }
        do {
            let signature = try await keys.signDevicePayload(CloudSecretsProof.phonesPolicy(sub: subject.sub, phonesOff: value, at: at, by: device.deviceId))
            try await relay.publishPhonesPolicy(requestId: UUID().uuidString.lowercased(),
                policy: .init(phonesOff: value, at: at, by: device.deviceId, signature: CloudSecretsCrypto.encode(signature)))
            return true
        } catch { return false }
    }
    /// Whether a device of this kind may be handed the key at all: a computer always; one of his phones or browsers
    /// unless his one switch keeps saved passwords off his phones and browsers; an unknown kind never.
    private func mayHold(_ platform: CloudPlatform?) async -> Bool {
        if CloudSecretsAutoTrust.isComputer(platform) { return true }
        guard CloudSecretsAutoTrust.isPhone(platform) || CloudSecretsAutoTrust.isBrowser(platform) else { return false }
        return !(await phonesOff())
    }
    /// The highest key generation this Mac has seen (its own key's, Cloud's last notice). nil = cannot be read.
    private func highestEpochSeen() async -> Int? {
        do {
            let seen = try await local.seenCloudEpoch() ?? 0
            let own = (try await local.read())?.epoch ?? 0
            return max(seen, own)
        } catch { return nil }
    }
    private func enter() throws { guard !busy else { throw CloudFailure.unavailable }; busy = true }
    #if DEBUG
    /// Proof P3 only (two scratch copies against the TEST service). A release build compiles neither this
    /// property nor the permit type, and accepts production's issuer alone, exactly as before.
    private var scratch: CloudSecretsScratchPermit?
    /// The account assembly hands over the permit it could build for its accepted scratch plan. A permit exists
    /// only when its own conditions held (see `CloudSecretsScratchPermit`); the first one stays.
    public func adopt(scratch permit: CloudSecretsScratchPermit) { if scratch == nil { scratch = permit } }
    #endif
    /// Production's issuer, always. In a debug build only: also the ONE issuer of an adopted scratch permit.
    private func issuerAccepted() -> Bool {
        if subject.issuer == CloudWire.issuer { return true }
        #if DEBUG
        if let scratch { return scratch.accepts(subject) }
        #endif
        return false
    }
    private func permitted() async throws {
        try Task.checkCancellation()
        try await policy.require(.secret, stage: .upload)
        guard issuerAccepted() else { throw CloudFailure.invalidRequest }
    }
    private func currentKey() async throws -> CloudSecretsLocalKey {
        try await permitted()
        guard let key = try await local.read(), key.subject == subject, key.deviceId == device.deviceId,
              key.root.count == 32 else { throw CloudFailure.secretsLocked }
        let status = try await control.status()
        guard status.state == .ready, status.recoveryReady, key.epoch == status.epoch else { throw CloudFailure.versionChanged }
        return key
    }
    public func dismissPresentation() async {
        requestedApproval = nil; staleEnvelope = nil; possessionUnconfirmed = false
        if wordsStillNeeded {
            // Close any approval sheet, keep "did not finish, keep these words".
            await interaction.finishApproval()
            await interaction.finishWords(succeeded: false)
        } else { await interaction.dismiss() }
    }
    public func status() async throws -> CloudSecretsStatus {
        try await permitted()
        let remote = try await control.status()
        let key = try? await local.read()
        // A key saved after "Codes match" whose acknowledgement the cloud has
        // not confirmed is not "protected" yet (round-4 review S5).
        let ready = remote.recoveryReady && key?.subject == subject && key?.deviceId == device.deviceId
            && key?.epoch == remote.epoch && key?.acknowledged != false
        return .init(state: remote.state, epoch: remote.epoch, version: remote.version, recoveryReady: ready,
                     approvedDeviceCount: remote.approvedDeviceCount, pendingApprovals: remote.pendingApprovals)
    }
    public func setup() async throws {
        try enter(); defer { busy = false }
        try await permitted()
        let old = try await control.status()
        guard old.state == .unset, old.version == .zero, try await local.read() == nil else { throw CloudFailure.versionChanged }
        do { try await create(old: old, resetting: false); await interaction.finishWords(succeeded: true) }
        catch {
            if (error is CancellationError || Task.isCancelled) && !vaultCreated { await interaction.dismiss() }
            else { await interaction.finishWords(succeeded: false) }
            throw error
        }
    }
    /// Owner's decision (14 Nov): saved passwords are ON by default. The first device of an account makes the key by
    /// itself: no sheet, no recovery words. The service still requires a recovery copy at set-up, so one is sealed
    /// with a random secret that is thrown away at once (nobody, including us, can open it); the passkey spare key
    /// replaces it later. Everything else (independent read-back, possession, verified local save) is unchanged.
    public func setupSilently() async throws {
        try enter(); defer { busy = false }
        try await permitted()
        let old = try await control.status()
        guard old.state == .unset, old.version == .zero, try await local.read() == nil else { throw CloudFailure.versionChanged }
        try await create(old: old, resetting: false, showWords: false)
    }
    /// Review point 5: "Start again" when no device can open the Cloud copy. Replaces the unreadable copy with a
    /// fresh one made on this Mac (the service keeps the old one as an archive); nothing on this Mac is deleted. No
    /// words, no sheet. Needs the service's reset ticket (see PASSWORDS-SERVICE-CHANGE.md).
    public func resetSilently() async throws {
        try enter(); defer { busy = false }
        try await permitted()
        let old = try await control.status()
        // This Mac holds no key of the current generation (none, or only an older one, which `save` keeps as that
        // generation's archive key). Nothing on this Mac is deleted.
        let held = try await local.read()
        guard old.state == .ready || old.state == .reset, old.approvedDeviceCount == 0, (held?.epoch ?? 0) < old.epoch
        else { throw CloudFailure.versionChanged }
        try await create(old: old, resetting: true, showWords: false, withoutTicket: true)
    }
    public func reset() async throws {
        try enter(); defer { busy = false }
        try await permitted()
        guard try await interaction.confirmReset() else { throw CancellationError() }
        let old = try await control.status()
        guard old.state == .ready || old.state == .reset else { throw CloudFailure.versionChanged }
        do { try await create(old: old, resetting: true); await interaction.finishWords(succeeded: true) }
        catch {
            if (error is CancellationError || Task.isCancelled) && !vaultCreated { await interaction.dismiss() }
            else { await interaction.finishWords(succeeded: false) }
            throw error
        }
    }
    private func create(old: CloudSecretsStatus, resetting: Bool, showWords: Bool = true, withoutTicket: Bool = false) async throws {
        vaultCreated = false; wordsStillNeeded = false
        guard let oldVersion = UInt64(old.version.rawValue), oldVersion < UInt64.max, old.epoch < Int.max else { throw CloudFailure.invalidRequest }
        let vaultVersion = CloudSequence(oldVersion + 1), epoch = old.epoch + 1
        let oldRecovery: CloudSequence
        if resetting {
            let current = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
            guard current.epoch == old.epoch, current.version == old.version else { throw CloudFailure.versionChanged }
            oldRecovery = current.recoveryEnvelope.version
        } else { oldRecovery = .zero }
        guard let recoveryCounter = UInt64(oldRecovery.rawValue), recoveryCounter < UInt64.max else { throw CloudFailure.invalidRequest }
        let version = CloudSequence(recoveryCounter + 1)
        var root = try CloudSecretsCrypto.random(32), entropy = try CloudSecretsCrypto.random(32)
        defer { root.resetBytes(in: 0..<root.count); entropy.resetBytes(in: 0..<entropy.count) }
        let recovery = try CloudRecoveryKeys(entropy: entropy, sub: subject.sub)
        // No words: a placeholder that never holds the key (see `sealPlaceholder`).
        let recoveryEnvelope = showWords ? try recovery.seal(root: root, sub: subject.sub, version: version, epoch: epoch)
            : try recovery.sealPlaceholder(sub: subject.sub, version: version, epoch: epoch)
        if showWords {
            guard try recovery.open(recoveryEnvelope, sub: subject.sub, epoch: epoch, version: version) == root else { throw CloudFailure.checksumMismatch }
        }
        if showWords {
            var phrase = try await words.words(entropy: entropy)
            defer { phrase.removeAll(keepingCapacity: false) }
            guard phrase.count == 24, try await words.entropy(words: phrase) == entropy else { throw CloudFailure.checksumMismatch }
            var generator = SystemRandomNumberGenerator()
            let positions = Array((0..<24).shuffled(using: &generator).prefix(3)).sorted()
            let confirmation = try await interaction.confirmWords(phrase, positions: positions)
            guard confirmation.keptWords, Set(confirmation.answers.keys) == Set(positions),
                  positions.allSatisfy({ confirmation.answers[$0]?.decomposedStringWithCompatibilityMapping == phrase[$0] })
            else { throw CloudFailure.checksumMismatch }
        }
        try await permitted()
        let (envelope, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: root, sub: subject.sub, target: device,
            epoch: epoch, recoveryVersion: version, author: device.deviceId, sign: keys.signDevicePayload)
        if resetting {
            // "Start again" when nobody can open the copy: the service takes it with no ticket, only from a computer
            // and only while no device holds the current key (td-cloud 2fb865f1, checked again in its own write).
            let ticket: String? = withoutTicket ? nil : try await resetTicket()
            guard ticket.map({ !$0.isEmpty }) ?? true else { throw CloudFailure.invalidRequest }
            let receipt = try await control.reset(.init(requestId: UUID().uuidString.lowercased(), expectedVersion: old.version,
                resetTicket: ticket, newRecoveryEnvelope: recoveryEnvelope, newDeviceEnvelope: envelope, canaryHash: canaryHash, confirmation: true))
            guard receipt.epoch == epoch, receipt.version == vaultVersion, receipt.state == .ready,
                  !receipt.secretsApproved, !receipt.preservedArchiveId.isEmpty else { throw CloudFailure.checksumMismatch }
            vaultCreated = true; wordsStillNeeded = showWords
        } else {
            let receipt = try await control.initialize(.init(requestId: UUID().uuidString.lowercased(), expectedVersion: .zero,
                recoveryEnvelope: recoveryEnvelope, deviceEnvelope: envelope, canaryHash: canaryHash, confirmation: true))
            guard receipt.epoch == epoch, receipt.version == vaultVersion, receipt.deviceEnvelope == envelope else { throw CloudFailure.checksumMismatch }
            vaultCreated = true; wordsStillNeeded = showWords
        }
        // A POST receipt alone is not an independently fetched recovery copy.
        let cloudRecovery = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
        guard cloudRecovery.epoch == epoch, cloudRecovery.version == vaultVersion, cloudRecovery.recoveryEnvelope == recoveryEnvelope else { throw CloudFailure.checksumMismatch }
        if showWords {
            guard try recovery.open(cloudRecovery.recoveryEnvelope, sub: subject.sub, epoch: epoch, version: version) == root else { throw CloudFailure.checksumMismatch }
        }
        let readback = try await control.envelope()
        guard readback.epoch == epoch, readback.version == vaultVersion, readback.deviceEnvelope == envelope else { throw CloudFailure.checksumMismatch }
        let unwrapped = try await CloudSecretsCrypto.unwrapDevice(readback.deviceEnvelope, sub: subject.sub,
            targetDeviceId: device.deviceId, epoch: epoch, version: version, author: device.deviceId, authorKey: device.signPublicJwk, keys: keys)
        guard try CloudSecretsCrypto.decode(unwrapped.rootKey, count: 32) == root,
              CloudSecretsCrypto.hash(try CloudSecretsCrypto.decode(unwrapped.canary, count: 32)) == canaryHash else { throw CloudFailure.checksumMismatch }
        try await possess(unwrapped, version: readback.version)
        try await save(root: root, epoch: epoch, version: version, publicKey: recovery.publicKey, recoveryWords: showWords)
        wordsStillNeeded = false
    }
    private func possess(_ body: CloudSecretsUnwrapped, version: CloudSequence) async throws {
        try await permitted()
        let signature = try await keys.signDevicePayload(CloudSecretsProof.possession(sub: subject.sub,
            deviceId: device.deviceId, version: version, canary: body.canary))
        let receipt = try await control.possession(.init(requestId: UUID().uuidString.lowercased(), expectedVersion: version,
            canary: body.canary, signature: CloudSecretsCrypto.encode(signature)))
        guard receipt.secretsApproved, receipt.epoch == body.epoch, receipt.version > version else { throw CloudFailure.checksumMismatch }
    }
    private func save(root: Data, epoch: Int, version: CloudSequence, publicKey: CloudPublicJWK, acknowledged: Bool = true,
                      recoveryWords: Bool? = nil) async throws {
        try await permitted()
        let value = CloudSecretsLocalKey(subject: subject, deviceId: device.deviceId, epoch: epoch, version: version, root: root,
                                         recoveryPublicKey: publicKey, acknowledged: acknowledged, recoveryWords: recoveryWords)
        // A read failure is not "no key": a transient protected-store or decode
        // failure must never let an older epoch replace a newer verified root.
        if let existing = try await local.read(), existing.subject == subject, existing.deviceId == device.deviceId {
            // An old, correctly encrypted archive is still not a current vault.
            // A server replay must not replace a newer locally verified epoch.
            guard epoch >= existing.epoch, version >= existing.version else { throw CloudFailure.versionChanged }
            // A newer epoch's key never discards the older one: keep it as that
            // epoch's archive key first, and refuse the save if it cannot be kept.
            if existing.epoch < epoch {
                try await local.archive(existing)
                guard let kept = try await local.archived(epoch: existing.epoch), kept.root == existing.root,
                      kept.subject == subject, kept.deviceId == device.deviceId else { throw CloudFailure.checksumMismatch }
            }
        }
        try await local.saveVerified(value)
        // The highest generation this Mac has seen (condition b), beside the key.
        if let seen = try? await local.seenCloudEpoch(), seen >= epoch {} else { try? await local.saveSeenCloudEpoch(epoch) }
        guard let saved = try await local.read(), saved.subject == subject, saved.deviceId == device.deviceId,
              saved.epoch == epoch, saved.version == version, saved.root == root, saved.recoveryPublicKey == publicKey,
              saved.acknowledged == acknowledged, saved.recoveryWords == recoveryWords else { throw CloudFailure.checksumMismatch }
    }
    public func requestApproval() async throws -> CloudApproval {
        try enter(); defer { busy = false }
        try await permitted()
        let hash = try CloudSecretsCrypto.keyHash(device)
        // Note any envelope left by an earlier attempt before asking again.
        // "Nothing there" and a failed read both leave this empty.
        let leftover = try? await control.envelope().deviceEnvelope
        let approval = try await control.requestApproval(.init(requestId: UUID().uuidString.lowercased(), targetDeviceId: device.deviceId, targetKeyHash: hash))
        guard approval.targetDeviceId == device.deviceId, approval.targetKeyHash == hash,
              approval.expiresAt > policy.now(), approval.expiresAt <= policy.now() + 600_000 else { throw CloudFailure.invalidRequest }
        requestedApproval = approval; staleEnvelope = leftover; possessionUnconfirmed = false
        // Automatic hand-over: this device signs its own request (review point 2) and shows no code. If the signature
        // cannot be handed to the service, the request falls back to the person's path with its code (never a dead end).
        var signed = false
        if await automaticOn(), let signing = control as? any CloudSecretsRequestSigningPort {
            do {
                let epoch = try await control.status().epoch
                let proof = try await keys.signDevicePayload(CloudSecretsProof.request(sub: subject.sub, approval: approval,
                    wrapPublicJwk: device.wrapPublicJwk, epoch: epoch))
                try await signing.signRequest(requestId: UUID().uuidString.lowercased(), approvalId: approval.approvalId,
                                              signature: CloudSecretsCrypto.encode(proof))
                signed = true
            } catch {}
        }
        signedRequest = signed
        // Review blocker 3: under his stricter setting the answering Mac always shows the code, so this device shows
        // the same code to compare. If the service hides the setting, no code shows here and he refuses there: the
        // safe way to fail.
        if signed, !(await askHint()) { return approval }
        try await interaction.showMatchingCode(.init(deviceName: device.label, platform: device.platform, matchingCode: CloudSecretsCrypto.matchingCode(approval)))
        return approval
    }
    public func approve(id: String) async throws {
        try enter(); defer { busy = false }
        let key = try await currentKey()
        let state = try await control.status()
        guard let approval = state.pendingApprovals.first(where: { $0.approvalId == id }), approval.targetDeviceId != device.deviceId,
              approval.expiresAt > policy.now(), approval.expiresAt <= policy.now() + 600_000 else { throw CloudFailure.invalidRequest }
        let target = try await control.registeredDevice(approval.targetDeviceId)
        guard try CloudSecretsCrypto.keyHash(target) == approval.targetKeyHash else { throw CloudFailure.checksumMismatch }
        // Review blocker 1, widened 15 Nov: a computer's, or one of his phones' or browsers' request (unless his one switch
        // keeps them off); an unknown kind never.
        guard await offeredToPerson(target) else { throw CloudFailure.invalidRequest }
        // A request the device SIGNED (this build and later) from a computer THIS Mac pinned shows no code on that
        // device: the signature, checked with the signing key pinned here, already proves which device asks, so the
        // click is "Allow <name>?" with no code (`matchingCode` empty), and no second code follows. A signature that
        // does not verify is never shown. Review blocker 3: under his stricter setting the code is ALWAYS shown (the
        // new device shows it too), so the click is a real comparison.
        let signedBy = try await signedRequestAuthor(approval, target: target, epoch: key.epoch)
        let strict = await askOnNewDevice()
        // The click decides trust: a signed request keeps the name THIS Mac pinned with the key (the service's friendly
        // name is display only and could be set by whoever controls the service); otherwise the friendly name.
        let shownName: String
        if let pinned = signedBy?.name { shownName = pinned }
        else { shownName = await friendlyNames(needing: target.deviceId)[target.deviceId]?.name ?? target.label }
        var display = CloudSecretsApprovalDisplay(deviceName: shownName, platform: target.platform,
            matchingCode: signedBy == nil || strict ? CloudSecretsCrypto.matchingCode(approval) : "")
        display.signedOutBefore = await waitsForYesItsMine(approvalId: id, target: target)
        let allow = try await interaction.allowDevice(display)
        // The sheet can remain open while the request or registered key changes.
        try await permitted()
        let fresh = try await control.status(), freshTarget = try await control.registeredDevice(target.deviceId)
        guard fresh.version == state.version, fresh.epoch == state.epoch, fresh.state == .ready,
              fresh.pendingApprovals.contains(approval), freshTarget == target, approval.expiresAt > policy.now() else { throw CloudFailure.versionChanged }
        var envelope: CloudDeviceKeyEnvelope?, canaryHash: String?
        // D1: his Allow on a machine another device signed out IS the "Yes, it's mine": the account is told first
        // (`POST /devices/confirm-mine`), then the hand-over goes on. If Cloud does not take it, nothing is answered.
        if allow, await waitsForYesItsMine(approvalId: id, target: target), let port = control as? any CloudSecretsSignedOutBeforePort {
            try await port.confirmMine(deviceId: target.deviceId)
            log.say("you said \u{201C}Yes, it's mine\u{201D} for " + CloudSecretsLog.name(shownName))
        }
        if allow {
            (envelope, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: key.root, sub: subject.sub, target: target,
                epoch: key.epoch, recoveryVersion: key.version, author: device.deviceId, sign: keys.signDevicePayload)
        }
        let proof = try await keys.signDevicePayload(CloudSecretsProof.approval(approval, allow: allow, version: state.version, envelope: envelope, canaryHash: canaryHash))
        let answer = try await control.answerApproval(.init(requestId: UUID().uuidString.lowercased(), approvalId: id, allow: allow,
            expectedVersion: state.version, deviceEnvelope: envelope, canaryHash: canaryHash,
            proof: .init(signerDeviceId: device.deviceId, signature: CloudSecretsCrypto.encode(proof))))
        guard answer.approvalId == id, answer.state == (allow ? "approved" : "denied") else { throw CloudFailure.checksumMismatch }
        let who = CloudSecretsLog.name(shownName)
        log.say(allow ? "answered a request from " + who + " after your click" : "refused a request from " + who + " by your click")
        // His Allow, with the device's own signature checked here or the matching code compared by him: this wrapping key
        // is the device's own (a later key change may seal to it). Best effort; without it that device just asks again.
        if allow, let bookPort, let read = try? await bookPort.handOverBook() ?? CloudSecretsHandOverBook() {
            var book = read
            book.noteWrapKeyVerified(target); try? await bookPort.saveHandOverBook(book)
        }
        if let envelope, allow, signedBy == nil {
            try await interaction.showTransferCode(.init(deviceName: target.label, platform: target.platform,
                matchingCode: CloudSecretsCrypto.transferCode(subject: subject, approval: approval, target: target,
                    authorKey: device.signPublicJwk, envelope: envelope)))
        }
    }
    /// Automatic hand-over (owner's decision, 14 Nov; "Automatically, with my account" on THIS Mac): answers one
    /// pending request with the key sealed for the requesting device's own registered key, with no sheet and no code.
    /// Answers only when every check holds, and otherwise leaves the request untouched for a person (never a denial):
    /// - this Mac holds the confirmed key of the current epoch;
    /// - the request is pending, not expired, and not this Mac's own;
    /// - the service lists the device as active, and its two keys hash to the request's key hash;
    /// - THIS Mac's own trusted-device list holds that device as trusted with exactly that signing key (`vouch`): a
    ///   removed or stopped device, or one whose key changed, is never answered by itself.
    /// The key is sealed only to that registration's wrapping key. Returns the device answered, nil when skipped.
    public func answerAutomatically(id: String) async throws -> String? {
        guard let automatic, await automatic.on(), control is any CloudSecretsRequestSigningPort, let bookPort else { return nil }
        // The owner's stricter setting: never by itself (the request waits for his click, or his passkey later).
        guard !(await askOnNewDevice()) else { refusal(id, "a request by itself: the stricter setting is on here, it waits for your click"); return nil }
        try enter(); defer { busy = false }
        let key = try await currentKey()
        let state = try await control.status()
        guard state.state == .ready, state.epoch == key.epoch, let approval = state.pendingApprovals.first(where: { $0.approvalId == id }),
              approval.targetDeviceId != device.deviceId, approval.expiresAt > policy.now(),
              approval.expiresAt <= policy.now() + 600_000 else { return nil }
        // Not in the account's list, or not active there (removed): never answered.
        guard let target = try? await control.registeredDevice(approval.targetDeviceId), target.deviceId == approval.targetDeviceId else {
            refusal(id, "a request: its device is not active in the account"); return nil
        }
        // Point 6: the friendly name from the account's list (one source); the recorded label only without it.
        let who = CloudSecretsLog.name(await friendlyNames(needing: target.deviceId)[target.deviceId]?.name ?? target.label)
        guard try CloudSecretsCrypto.keyHash(target) == approval.targetKeyHash else { refusal(id, "a request from " + who + ": its keys do not match the request"); return nil }
        guard CloudSecretsAutoTrust.kind(target.platform) != nil else {
            refusal(id, "a request from " + who + ": not a computer, a phone or a browser"); return nil
        }
        // D1 (open with Asad): the one place a "Yes, it's mine" tap would be added. Today always false (no tap).
        if await waitsForYesItsMine(approvalId: id, target: target) { refusal(id, "a request from " + who + ": signed out from another device before; it waits for your \u{201C}Yes, it's mine\u{201D}"); return nil }
        // 15 Nov: his own phones and browsers too, unless his one switch keeps saved passwords off them.
        if CloudSecretsAutoTrust.isPhone(target.platform), await phonesOff() {
            refusal(id, "a request from " + who + ": your setting keeps saved passwords off your phones"); return nil
        }
        if CloudSecretsAutoTrust.isBrowser(target.platform), await phonesOff() {
            refusal(id, "a request from " + who + ": your setting keeps saved passwords off your browsers"); return nil
        }
        // On THIS Mac's own list as a COMPUTER (review blocker 1: the kind this Mac recorded, not the request's), with
        // exactly the signing key stored here, and the device signed this very request, over its wrapping key, with
        // that pinned key (point 2).
        let signedBy: CloudSecretsAutoTrust.Pinned?
        do { signedBy = try await signedRequestAuthor(approval, target: target, epoch: key.epoch, reportFetch: true) }
        catch CloudFailure.checksumMismatch { refusal(id, "a request from " + who + ": wrong signature"); return nil }   // never answered, never shown
        catch let failed as SignatureFetchFailed {
            // Not a mismatch: the signatures could not be read. Said as it is; nothing is answered.
            let why: String
            if case .remote(_)? = failed.underlying as? CloudFailure { why = CloudSecretsLog.cause(failed.underlying) } else { why = "no answer from the service" }
            refusal(id, "a request from " + who + ": could not check the request: " + why); return nil
        }
        catch { refusal(id, "a request from " + who + ": could not check the request: " + CloudSecretsLog.cause(error)); return nil }
        // The kind THIS Mac recorded must be the same kind the account lists now (a pinned phone never passes as a Mac).
        guard let pinned = signedBy, await mayHold(pinned.platform), CloudSecretsAutoTrust.sameKind(pinned.platform, target.platform) else {
            if let listed = await automatic.pinned(target.deviceId), listed.signKey == target.signPublicJwk {
                refusal(id, "a request from " + who + (CloudSecretsAutoTrust.kind(listed.platform) != nil ? ": not signed (an older app), or not the kind of device kept here; it waits for your click" : ": not a computer, a phone or a browser"))
            } else { refusal(id, "a request from " + who + ": not listed on this Mac") }
            return nil
        }
        // Once per device per key generation (point 3), from the book beside the key; unreadable = answered.
        guard var book = try? await bookPort.handOverBook() ?? CloudSecretsHandOverBook(),
              !book.hasAnswered(target.deviceId, epoch: key.epoch), !(await automatic.answeredBefore(target.deviceId, key.epoch)) else {
            refusal(id, "a request from " + who + ": already answered once for this key; it waits for your click"); return nil
        }
        // The setting may have changed while the list was read.
        try await permitted()
        guard await automatic.on(), !(await askOnNewDevice()), await mayHold(pinned.platform) else { return nil }
        // Condition (a): "answered" is written beside the key BEFORE the answer goes out; if it cannot be written,
        // nothing goes out (a lost answer then waits for a person, never a second automatic one).
        book.answered.append(CloudSecretsHandOverBook.key(target.deviceId, key.epoch))
        // Its own signature over this wrapping key was just checked with the pinned key: a later key change may seal to it.
        book.noteWrapKeyVerified(target)
        if book.answered.count > 256 { book.answered.removeFirst(book.answered.count - 256) }
        try await bookPort.saveHandOverBook(book)
        try await automatic.remember(target.deviceId, key.epoch)
        let (envelope, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: key.root, sub: subject.sub, target: target,
            epoch: key.epoch, recoveryVersion: key.version, author: device.deviceId, sign: keys.signDevicePayload)
        let proof = try await keys.signDevicePayload(CloudSecretsProof.approval(approval, allow: true, version: state.version,
            envelope: envelope, canaryHash: canaryHash))
        let answer = try await control.answerApproval(.init(requestId: UUID().uuidString.lowercased(), approvalId: id, allow: true,
            expectedVersion: state.version, deviceEnvelope: envelope, canaryHash: canaryHash,
            proof: .init(signerDeviceId: device.deviceId, signature: CloudSecretsCrypto.encode(proof))))
        guard answer.approvalId == id, answer.state == "approved" else { throw CloudFailure.checksumMismatch }
        // Review fix 3: the name THIS Mac saved when it trusted the device (as the earlier review required).
        return pinned.name
    }
    /// Review blocker 1: whether a request may reach the person at all. Only a computer: the service's word can only
    /// hide a request, and where THIS Mac recorded the device's kind with its key, that record decides.
    /// 15 Nov: one of his phones is offered too (it must be on THIS Mac's list with that key, recorded as a phone), unless
    /// his setting keeps saved passwords off his phones. 15 Nov (later): one of his browsers likewise, recorded here as a
    /// browser, under the same switch. An unknown kind never.
    private func offeredToPerson(_ target: CloudDeviceRegistration) async -> Bool {
        guard await mayHold(target.platform) else { return false }
        if let automatic, let pinned = await automatic.pinned(target.deviceId), pinned.signKey == target.signPublicJwk, pinned.platform != nil {
            return await mayHold(pinned.platform) && CloudSecretsAutoTrust.sameKind(pinned.platform, target.platform)
        }
        return CloudSecretsAutoTrust.isComputer(target.platform)
    }
    /// The requests the Cloud page lists for his click (review blocker 1 and point 6): pending, not this Mac's own,
    /// not run out, from a computer whose registered keys match the request, and never one whose signature is present
    /// and does not verify (its button could only fail). A phone's or a browser's request is not listed at all.
    public func approvalsForPerson() async -> [CloudApproval] {
        guard let key = try? await currentKey(), let status = try? await control.status() else { return [] }
        var listed: [CloudApproval] = []
        for approval in status.pendingApprovals where approval.targetDeviceId != device.deviceId && approval.expiresAt > policy.now() {
            guard let target = try? await control.registeredDevice(approval.targetDeviceId), target.deviceId == approval.targetDeviceId,
                  (try? CloudSecretsCrypto.keyHash(target)) == approval.targetKeyHash, await offeredToPerson(target) else { continue }
            do { _ = try await signedRequestAuthor(approval, target: target, epoch: key.epoch) } catch { continue }
            listed.append(approval)
        }
        return listed
    }
    /// The requesting device's own signature over this request (its wrapping key by hash, the key generation), checked
    /// with the signing key THIS Mac pinned for it. nil = unsigned (an older build), or the device is not on this
    /// Mac's list as a trusted COMPUTER with exactly that key (review blocker 1). A signature that is present and does
    /// not verify throws: such a request is never answered and never shown.
    /// `reportFetch`: the automatic answer only (for its log line): a failed read of the signatures throws that error
    /// instead of reading as "unsigned". Either way nothing is answered; the click paths keep reading it as unsigned.
    private func signedRequestAuthor(_ approval: CloudApproval, target: CloudDeviceRegistration, epoch: Int,
                                     reportFetch: Bool = false) async throws -> CloudSecretsAutoTrust.Pinned? {
        guard let automatic, let signing = control as? any CloudSecretsRequestSigningPort else { return nil }
        let signatures: [String: String]?
        if reportFetch {
            do { signatures = try await signing.requestSignatures() } catch { throw SignatureFetchFailed(underlying: error) }
        } else { signatures = try? await signing.requestSignatures() }
        guard let signature = signatures?[approval.approvalId] else { return nil }
        guard let pinned = await automatic.pinned(target.deviceId), pinned.signKey == target.signPublicJwk else { return nil }
        do {
            try CloudSecretsCrypto.verify(signature, bytes: CloudSecretsProof.request(sub: subject.sub, approval: approval,
                wrapPublicJwk: target.wrapPublicJwk, epoch: epoch), key: pinned.signKey)
        } catch { throw CloudFailure.checksumMismatch }
        // Checked first (a bad signature is never listed, whatever the device), then only a computer or one of his phones
        // counts (the callers apply his phones setting).
        return CloudSecretsAutoTrust.kind(pinned.platform) != nil ? pinned : nil
    }
    /// Review blocker 1: the service accepted this Mac's set-up but the key never reached this Mac's own store (quit,
    /// crash, network, Keychain). The copy this Mac sealed FOR ITSELF is still in Cloud: open it only when it is
    /// addressed to this Mac AND signed by this Mac's own signing key (the local registration, never the key the
    /// service reports), check it, prove possession, save. Nothing new is trusted. Returns true when the key is here.
    @discardableResult
    public func reopenOwnCopy() async throws -> Bool {
        try enter(); defer { busy = false }
        try await permitted()
        guard try await local.read() == nil else { return false }
        let status = try await control.status()
        guard status.state == .ready else { return false }
        guard let receipt = try? await control.envelope(), receipt.epoch == status.epoch,
              receipt.deviceEnvelope.targetDeviceId == device.deviceId, receipt.deviceEnvelope.authorDeviceId == device.deviceId else { return false }
        // Condition (b): never a key generation older than the highest this Mac has seen (a replayed older copy of
        // its own). Unreadable = refused.
        guard let highest = await highestEpochSeen(), receipt.epoch >= highest else { return false }
        let recovery = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
        guard recovery.epoch == receipt.epoch else { return false }
        let body = try await CloudSecretsCrypto.unwrapDevice(receipt.deviceEnvelope, sub: subject.sub, targetDeviceId: device.deviceId,
            epoch: receipt.epoch, version: recovery.recoveryEnvelope.version, author: device.deviceId, authorKey: device.signPublicJwk, keys: keys)
        var root = try CloudSecretsCrypto.decode(body.rootKey, count: 32)
        defer { root.resetBytes(in: 0..<root.count) }
        let words = !recovery.recoveryEnvelope.isPlaceholder
        wordsKnown = words
        // Store first (unconfirmed), then prove possession; an approved device's refusal means "already done".
        try await save(root: root, epoch: receipt.epoch, version: recovery.recoveryEnvelope.version,
                       publicKey: recovery.recoveryEnvelope.publicSigningJwk, acknowledged: false, recoveryWords: words)
        do { try await possess(body, version: receipt.version) }
        catch CloudFailure.remote(let detail) where detail.code == "secrets_locked" {}
        try await markAcknowledged()
        return true
    }
    // MARK: a lost Mac signed out from another device (Security, 15 Nov; sign-out-lost-mac-design.md B2)
    /// What one look at the key change came to.
    public enum KeyChange: String, Equatable, Sendable {
        /// Nothing due, or nothing this Mac can do now (it waits for the next notice).
        case nothing
        /// This Mac made the new key, sealed it for every device it trusts, and holds it.
        case rotated
        /// Another of his Macs made the new key; this Mac took the copy sealed for it.
        case tookCopy
    }
    /// The random wait before a due change, in ms (two Macs that hear the same notice rarely both try). Fixtures: 0.
    private var rotationJitter: @Sendable () -> Int64 = { Int64.random(in: 0...20_000) }
    func use(rotationJitter value: @escaping @Sendable () -> Int64) { rotationJitter = value }
    /// This Mac holds a key of an OLDER generation than the Cloud's (another device changed it). Unreadable = false.
    public func keyBehind() async -> Bool {
        guard let key = try? await local.read(), key.subject == subject, key.deviceId == device.deviceId,
              let status = try? await control.status(), status.state == .ready else { return false }
        return key.epoch < status.epoch
    }
    /// Called on every `vault`, `devices` and `hello` notice (no timer). Behind: take the copy another Mac sealed for this
    /// Mac. Current and the account says "key change due": wait a moment, look again, then make the new key here.
    /// Never a sheet, never a click; nothing local is deleted (the old key is kept as that generation's archive key).
    public func keyChange() async throws -> KeyChange {
        try await permitted()
        if await keyBehind() { return try await takeKeyChangeCopy() ? .tookCopy : .nothing }
        guard let port = control as? any CloudSecretsRotationPort, let due = try? await port.rotationDue(),
              due.removedDeviceId.isEmpty || due.removedDeviceId != device.deviceId,
              let key = try? await local.read(), key.subject == subject, key.deviceId == device.deviceId, key.acknowledged != false
        else { return .nothing }
        await sleep(rotationJitter())
        // Another Mac may have done it meanwhile: then its copy for this Mac is waiting.
        guard let again = try? await port.rotationDue(), again.since == due.since else { return try await copyIfBehind() }
        do { try await rotate(port: port, due: again) }
        catch let failure as CloudFailure where Self.lostTheRace(failure) {
            log.say("the key change was made on another of your Macs first; taking its copy")
            return try await copyIfBehind()
        }
        return .rotated
    }
    private func copyIfBehind() async throws -> KeyChange {
        guard await keyBehind() else { return .nothing }
        return try await takeKeyChangeCopy() ? .tookCopy : .nothing
    }
    nonisolated static func lostTheRace(_ failure: CloudFailure) -> Bool {
        if failure == .versionChanged { return true }
        if case .remote(let detail) = failure { return ["version_changed", "not_due"].contains(detail.code) }
        return false
    }
    /// The change itself: a new 32-byte key (generation + 1), a placeholder recovery copy (no words: the Macs never keep
    /// the word entropy), this Mac's own copy, and one copy for each device the service lists as holding the current key
    /// AND this Mac's own trusted list holds with exactly that signing key, of the same kind, allowed to hold it (his
    /// phones/browsers switch). The removed device never. One call; then read back and saved as `create` does.
    private func rotate(port: any CloudSecretsRotationPort, due: CloudSecretsRotationDue) async throws {
        try enter(); defer { busy = false }
        let key = try await currentKey()
        let old = try await control.status()
        guard old.state == .ready, old.epoch == key.epoch, let oldVersion = UInt64(old.version.rawValue), oldVersion < UInt64.max,
              old.epoch < Int.max else { throw CloudFailure.versionChanged }
        let vaultVersion = CloudSequence(oldVersion + 1), epoch = old.epoch + 1
        let current = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
        guard current.epoch == old.epoch, current.version == old.version else { throw CloudFailure.versionChanged }
        guard let counter = UInt64(current.recoveryEnvelope.version.rawValue), counter < UInt64.max else { throw CloudFailure.invalidRequest }
        let version = CloudSequence(counter + 1)
        var root = try CloudSecretsCrypto.random(32), entropy = try CloudSecretsCrypto.random(32)
        defer { root.resetBytes(in: 0..<root.count); entropy.resetBytes(in: 0..<entropy.count) }
        let recovery = try CloudRecoveryKeys(entropy: entropy, sub: subject.sub)
        let recoveryEnvelope = try recovery.sealPlaceholder(sub: subject.sub, version: version, epoch: epoch)
        let (envelope, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: root, sub: subject.sub, target: device,
            epoch: epoch, recoveryVersion: version, author: device.deviceId, sign: keys.signDevicePayload)
        // Review 15 Nov finding 2: a copy only to a wrapping key whose device's OWN signature THIS Mac checked earlier
        // (`CloudSecretsHandOverBook.verifiedWrapKeys`), never to whatever key the service reports now.
        let verified = (try? await bookPort?.handOverBook()) ?? nil
        var planned: [(copy: CloudSecretsRotateCopy, name: String, platform: CloudPlatform?)] = []
        for id in Set(due.holders.map { $0.lowercased() }).sorted() where id != device.deviceId.lowercased() && id != due.removedDeviceId.lowercased() {
            guard planned.count < 64 else { log.say("key change: more than 64 devices hold the key; the rest ask again by themselves"); break }
            guard let target = try? await control.registeredDevice(id), target.deviceId.lowercased() == id,
                  let pinned = await automatic?.pinned(target.deviceId), pinned.signKey == target.signPublicJwk,
                  CloudSecretsAutoTrust.kind(pinned.platform) != nil, CloudSecretsAutoTrust.sameKind(pinned.platform, target.platform),
                  await mayHold(pinned.platform) else {
                // Not on THIS Mac's own list with that key (or kept off by his switch): no copy; it asks again by itself.
                log.say("key change: no copy for a device this Mac does not list with its key; it asks again by itself")
                continue
            }
            // Key-box sign-off finding 2 (15 Nov): this change is due because a device was signed out by ANOTHER device;
            // a browser may be the one still signed in on the stolen Mac, and under "Ask me on each new device" it is
            // not new. So never a browser here: it asks again through the usual hand-over (one Allow when strict).
            guard !CloudSecretsAutoTrust.isBrowser(pinned.platform), !CloudSecretsAutoTrust.isBrowser(target.platform) else {
                log.say("key change: no copy for a browser after a sign-out from another device; it asks again by itself")
                continue
            }
            guard verified?.wrapKeyVerified(target) == true else {
                log.say("key change: no copy for " + CloudSecretsLog.name(pinned.name) + ": its own signature over its key was not checked here; it asks again by itself")
                continue
            }
            let (copy, hash) = try await CloudSecretsCrypto.wrapDevice(root: root, sub: subject.sub, target: target, epoch: epoch,
                recoveryVersion: version, author: device.deviceId, sign: keys.signDevicePayload)
            planned.append((.init(targetDeviceId: target.deviceId, envelope: copy, canaryHash: hash), pinned.name, pinned.platform))
        }
        // Review finding 3 (service 68cd59435): a copy the service cannot take (a phone answered but not proven yet, his
        // phones switch read differently there, ...) fails ONLY that copy: the change goes through and the answer names
        // it in `refusedCopies`; that device asks again through the hand-over. An older service that refuses the whole
        // call for one copy instead: once more with no copies (the change itself is what cuts the lost Mac's key off).
        var sent: [(copy: CloudSecretsRotateCopy, name: String, platform: CloudPlatform?)] = planned
        var receipt: CloudSecretsRotateReceipt?
        for attempt in 0..<2 {
            try await markCopies(sent.map { $0.copy.targetDeviceId }, epoch: epoch, keep: true)
            try await permitted()
            do {
                receipt = try await port.rotate(.init(requestId: UUID().uuidString.lowercased(), expectedVersion: old.version,
                    newRecoveryEnvelope: recoveryEnvelope, newDeviceEnvelope: envelope, canaryHash: canaryHash, copies: sent.map { $0.copy }))
                break
            } catch CloudFailure.remote(let detail) where !sent.isEmpty && attempt == 0 && Self.refusesACopy(detail.code) {
                // The call changed nothing: the "answered" marks of the copies that did not go are taken back first.
                try await markCopies(sent.map { $0.copy.targetDeviceId }, epoch: epoch, keep: false)
                log.say("key change: Cloud did not take the copies (" + detail.code + "); changing the key with none; your devices ask again by themselves")
                sent = []
            }
        }
        guard let receipt else { throw CloudFailure.unavailable }
        let refused = Set((receipt.refusedCopies ?? []).map { $0.targetDeviceId.lowercased() })
        if !refused.isEmpty {
            try await markCopies(sent.map { $0.copy.targetDeviceId }.filter { refused.contains($0.lowercased()) }, epoch: epoch, keep: false)
            log.say("key change: " + String(refused.count) + " of the copies were not taken by Cloud; those devices ask again by themselves")
            sent = sent.filter { !refused.contains($0.copy.targetDeviceId.lowercased()) }
        }
        let sealedFor = sent.map { $0.name }
        for copy in sent { try? await automatic?.remember(copy.copy.targetDeviceId, epoch) }
        guard receipt.epoch == epoch, receipt.version == vaultVersion, receipt.state == .ready, !receipt.preservedArchiveId.isEmpty
        else { throw CloudFailure.checksumMismatch }
        // Read back exactly as a new generation from `create` is (an answer alone is not the stored copy).
        let cloudRecovery = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
        guard cloudRecovery.epoch == epoch, cloudRecovery.version == vaultVersion, cloudRecovery.recoveryEnvelope == recoveryEnvelope else { throw CloudFailure.checksumMismatch }
        let readback = try await control.envelope()
        guard readback.epoch == epoch, readback.version == vaultVersion, readback.deviceEnvelope == envelope else { throw CloudFailure.checksumMismatch }
        let unwrapped = try await CloudSecretsCrypto.unwrapDevice(readback.deviceEnvelope, sub: subject.sub,
            targetDeviceId: device.deviceId, epoch: epoch, version: version, author: device.deviceId, authorKey: device.signPublicJwk, keys: keys)
        guard try CloudSecretsCrypto.decode(unwrapped.rootKey, count: 32) == root,
              CloudSecretsCrypto.hash(try CloudSecretsCrypto.decode(unwrapped.canary, count: 32)) == canaryHash else { throw CloudFailure.checksumMismatch }
        // Saved before possession, so a lost answer never leaves this Mac without the key it just made (the service
        // already holds the new generation); `save` keeps the old key as that generation's archive key first.
        wordsKnown = false
        try await save(root: root, epoch: epoch, version: version, publicKey: recovery.publicKey, acknowledged: false, recoveryWords: false)
        do { try await possess(unwrapped, version: readback.version) }
        catch CloudFailure.remote(let detail) where detail.code == "secrets_locked" {}
        try await markAcknowledged()
        log.say("changed the saved-passwords key after " + (due.removedName.isEmpty ? "a device" : CloudSecretsLog.name(due.removedName)) + " was signed out; sealed for "
                + (sealedFor.isEmpty ? "this Mac only" : sealedFor.map { CloudSecretsLog.name($0) }.joined(separator: ", ")))
    }
    /// A copy of the NEW generation that another of his Macs sealed for this Mac at a key change. Taken only when this Mac
    /// holds an older key, the copy is addressed to this Mac at the Cloud's current generation, and its author is a
    /// COMPUTER on this Mac's own trusted list with exactly that signing key (never the service's word alone). No new trust.
    @discardableResult
    public func takeKeyChangeCopy() async throws -> Bool {
        try enter(); defer { busy = false }
        try await permitted()
        guard let held = try await local.read(), held.subject == subject, held.deviceId == device.deviceId else { return false }
        let status = try await control.status()
        guard status.state == .ready, held.epoch < status.epoch,
              let receipt = try? await control.envelope(), receipt.epoch == status.epoch, receipt.version == status.version,
              receipt.deviceEnvelope.targetDeviceId == device.deviceId,
              receipt.deviceEnvelope.authorDeviceId != device.deviceId, receipt.deviceEnvelope.authorDeviceId != "recovery" else { return false }
        guard let highest = await highestEpochSeen(), receipt.epoch >= highest else { return false }
        let author = try await control.registeredDevice(receipt.deviceEnvelope.authorDeviceId)
        guard let automatic, let pinned = await automatic.pinned(author.deviceId), pinned.signKey == author.signPublicJwk,
              CloudSecretsAutoTrust.isComputer(pinned.platform), CloudSecretsAutoTrust.sameKind(pinned.platform, author.platform) else {
            log.say("a new key copy was not taken: its author is not one of your computers listed on this Mac")
            return false
        }
        let recovery = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
        guard recovery.epoch == receipt.epoch, recovery.version == receipt.version else { throw CloudFailure.versionChanged }
        let body = try await CloudSecretsCrypto.unwrapDevice(receipt.deviceEnvelope, sub: subject.sub, targetDeviceId: device.deviceId,
            epoch: receipt.epoch, version: recovery.recoveryEnvelope.version, author: author.deviceId, authorKey: pinned.signKey, keys: keys)
        var root = try CloudSecretsCrypto.decode(body.rootKey, count: 32)
        defer { root.resetBytes(in: 0..<root.count) }
        let words = !recovery.recoveryEnvelope.isPlaceholder
        wordsKnown = words
        try await save(root: root, epoch: receipt.epoch, version: recovery.recoveryEnvelope.version,
                       publicKey: recovery.recoveryEnvelope.publicSigningJwk, acknowledged: false, recoveryWords: words)
        do { try await possess(body, version: receipt.version) }
        catch CloudFailure.remote(let detail) where detail.code == "secrets_locked" {}
        try await markAcknowledged()
        log.say("took the new saved-passwords key from " + CloudSecretsLog.name(pinned.name) + " after a key change")
        return true
    }
    /// The refusals of `/secrets/rotate` that can be about one copy (not about the caller or the race).
    nonisolated static func refusesACopy(_ code: String) -> Bool { ["not_approved", "phones_off", "bad_signature", "invalid_request"].contains(code) }
    /// Condition (a) of the hand-over for the copies of a key change: "answered at this generation" is written beside the
    /// key BEFORE they go out (`keep`), and taken back for copies a refused call never delivered (`!keep`), so those
    /// devices are answered by themselves when they ask again.
    private func markCopies(_ ids: [String], epoch: Int, keep: Bool) async throws {
        guard let bookPort, !ids.isEmpty else { return }
        var book = (try? await bookPort.handOverBook() ?? CloudSecretsHandOverBook()) ?? CloudSecretsHandOverBook()
        let keys = Set(ids.map { CloudSecretsHandOverBook.key($0, epoch) })
        if keep { book.answered += keys.filter { !book.answered.contains($0) }.sorted() } else { book.answered.removeAll { keys.contains($0) } }
        if book.answered.count > 256 { book.answered.removeFirst(book.answered.count - 256) }
        try await bookPort.saveHandOverBook(book)
    }
    /// D1, DECIDED by Decker for now (15 Nov; Asad may overrule): THE ONE FLAG. True = a new sign-in on a machine that
    /// another of his devices signed out (the account's device list marks the row `signedOutBefore`) gets the
    /// saved-passwords key only after one "Yes, it's mine" (his Allow) on another of his devices. Every other device
    /// stays no-tap. Set false to give such a Mac its key with no tap (his "everything follows" rule).
    nonisolated static let askOnASignedOutMachine = true
    /// Whether this request waits for his "Yes, it's mine": the account marks it `signedOutBefore` on the request itself
    /// (`/secrets/status` pendingApprovals, service 68cd59435) or on the device's row. Fails safe: when the marks cannot
    /// be read, it waits (the next notice looks again).
    func waitsForYesItsMine(approvalId: String, target: CloudDeviceRegistration) async -> Bool {
        guard Self.askOnASignedOutMachine else { return false }
        if let port = control as? any CloudSecretsSignedOutBeforePort {
            guard let flagged = try? await port.signedOutBeforeRequests() else { return true }
            if flagged.contains(approvalId) { return true }
        }
        return await friendlyNames(needing: target.deviceId)[target.deviceId]?.signedOutBefore == true
    }
    // MARK: the passkey spare key (PASSWORDS-2 slice 2)
    // Each spare challenge is a receipt row on the service (b51a46424), so one is asked once per action and reused.
    /// The service keeps spares (it answers the spare challenge). Asks one challenge.
    public func controlKeepsSpares() async -> Bool { await spareChallenge() != nil }
    /// Whether a passkey spare can be offered on this Mac: the platform can do it and the service keeps spares.
    public func spareSupported(passkey: (any CloudSecretsPasskeyPort)?) async -> Bool {
        guard let passkey, await passkey.available() else { return false }
        return await controlKeepsSpares()
    }
    /// One spare challenge, said in the log by name and outcome (reviewer's first-real-passkey list).
    private func spareChallenge() async -> CloudSecretsSpareChallenge? {
        guard let spares = control as? any CloudSecretsSparePort else { return nil }
        do { return try await askSpareChallenge(spares) } catch { return nil }
    }
    private func askSpareChallenge(_ spares: any CloudSecretsSparePort) async throws -> CloudSecretsSpareChallenge {
        do {
            let challenge = try await spares.spareChallenge(requestId: UUID().uuidString.lowercased())
            log.say("passkey spare key: challenge asked: ok")
            return challenge
        } catch {
            log.say("passkey spare key: challenge asked: " + CloudSecretsLog.cause(error))
            throw error
        }
    }
    /// The spares on file for the current key generation (nil = could not be asked). The new service names this
    /// generation's spare in its status (`spare`): when it names none, no challenge is asked at all.
    public func sparesOnFile() async -> [CloudSecretsSpare]? {
        guard control is any CloudSecretsSparePort else { return nil }
        let epoch: Int
        if let port = control as? any CloudSecretsStatusFactsPort {
            guard let read = try? await port.statusFacts() else { return nil }
            if read.facts.newService, read.facts.spare == nil { return [] }
            epoch = read.status.epoch
        } else {
            guard let status = try? await control.status() else { return nil }
            epoch = status.epoch
        }
        guard let found = await spareChallenge() else { return nil }
        return found.spares.filter { $0.epoch == epoch }
    }
    /// Whether this generation has a spare on file (nil = could not be asked). The new service's status says it with no
    /// challenge at all; otherwise one challenge is asked.
    public func spareOnFile() async -> Bool? {
        guard control is any CloudSecretsSparePort else { return nil }
        if let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(), read.facts.newService {
            return read.facts.spare != nil
        }
        return await sparesOnFile().map { !$0.isEmpty }
    }
    /// Makes the passkey spare key once, on a Mac that holds the confirmed key: the system's own passkey sheet (Touch
    /// ID) and nothing else. The key is sealed under the passkey's PRF output, opened again here before it is sent,
    /// signed by this device's own signing key (TD-PASSWORDS-SPARE-1), and confirmed by the service afterwards.
    public func addSpare(passkey: any CloudSecretsPasskeyPort) async throws {
        guard let challenge = await spareChallenge() else { throw CloudFailure.unavailable }
        try await addSpare(passkey: passkey, challenge: challenge)
    }
    private func addSpare(passkey: any CloudSecretsPasskeyPort, challenge: CloudSecretsSpareChallenge) async throws {
        try enter(); defer { busy = false }
        let key = try await currentKey()
        guard let spares = control as? any CloudSecretsSparePort else { throw CloudFailure.unavailable }
        // One spare per key generation (service 7ff81baac).
        guard challenge.expiresAt > policy.now(), challenge.spares.filter({ $0.epoch == key.epoch }).isEmpty else { throw CloudFailure.invalidRequest }
        // Point 5: every spare passkey the service names is excluded, so the system refuses to make a second one on a
        // device that holds it (status `spare.credentialId`, service 7750c816e; the challenge's `spares[]`).
        var excludedIds = Set(challenge.spares.map(\.credentialId))
        if let port = control as? any CloudSecretsStatusFactsPort, let id = try? await port.statusFacts().facts.spareCredentialId { excludedIds.insert(id) }
        let made = try await createSheet(passkey: passkey, challenge: challenge, epoch: key.epoch,
                                         excluded: excludedIds.sorted(), replacing: false)
        var prf = made.prf
        defer { prf.resetBytes(in: 0..<prf.count) }
        let credentialId = CloudSecretsCrypto.encode(made.credentialId)
        let spare = try CloudSecretsSpareCrypto.seal(root: key.root, prf: prf, sub: subject.sub, credentialId: credentialId,
            epoch: key.epoch, createdAt: policy.now(), deviceName: device.label)
        guard try CloudSecretsSpareCrypto.open(spare, prf: prf, sub: subject.sub) == key.root else { throw CloudFailure.checksumMismatch }
        let signature = try await keys.signDevicePayload(CloudSecretsProof.spare(sub: subject.sub, by: device.deviceId, epoch: key.epoch,
            credentialId: credentialId, spare: spare))
        try await permitted()
        do {
            try await spares.addSpare(.init(requestId: UUID().uuidString.lowercased(), challengeId: challenge.challengeId,
                credentialId: credentialId, attestationObject: CloudSecretsCrypto.encode(made.attestationObject),
                clientDataJSON: CloudSecretsCrypto.encode(made.clientDataJSON), spare: spare, signature: CloudSecretsCrypto.encode(signature)))
        } catch {
            log.say("passkey spare key: add refused: " + CloudSecretsLog.spareCause(error))
            // Point 4: the passkey is made by now. When the refusal is because this generation already has a spare
            // (`spare_exists` 409; an expired challenge `approval_expired` 410 also lands here when the sheet was answered
            // late), the system's new passkey for the same site and account may have replaced the one that spare was
            // sealed for. This registration is never reused for a replace (the review's rule): the repair makes a fresh one.
            if await spareMadeElsewhere(epoch: key.epoch) {
                await noteSpareOrphaned(epoch: key.epoch)
                throw SpareOrphaned()
            }
            throw error
        }
        log.say("passkey spare key: add accepted by the service")
        // Gap 2 (14 Nov): the offer is used up only NOW, after the service answered the add.
        await noteSpareAdded(epoch: key.epoch)
        // Confirmed without a second challenge where the service says who made this generation's spare: this Mac.
        if let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(), read.facts.newService {
            guard read.status.epoch == key.epoch, read.facts.spare?.by == device.deviceId else { throw CloudFailure.checksumMismatch }
            return
        }
        guard let back = await sparesOnFile(), back.contains(spare) else { throw CloudFailure.checksumMismatch }
    }
    /// The system's passkey sheet that MAKES a passkey, known while it is open. Point 1: an offer's sheet is withdrawn
    /// when a spare is made elsewhere meanwhile (`withdrawSpareSheetIfMade`); a repair's sheet (`replacing`) is not, as
    /// a spare is on file by design. Either is withdrawn when its one-time challenge runs out (an answer after that can
    /// never be taken, but the system would still make the passkey, replacing the spare's passkey of the same account).
    private func createSheet(passkey: any CloudSecretsPasskeyPort, challenge: CloudSecretsSpareChallenge, epoch: Int,
                             excluded: [String], replacing: Bool) async throws -> CloudSecretsPasskeyCreated {
        spareSheet = (epoch, passkey, replacing); spareSheetWithdrawn = nil
        let pause = sleep, wait = max(0, challenge.expiresAt - policy.now())
        let ranOut = Task { [weak self] in
            await pause(wait)
            guard !Task.isCancelled, let self else { return }
            await self.withdrawSpareSheet(because: "its request ran out; it offers itself again at the next start")
        }
        log.say("passkey spare key: system passkey sheet shown")
        do {
            let made = try await passkey.create(challenge: CloudSecretsCrypto.decode(challenge.challenge),
                userId: CloudSecretsCrypto.decode(challenge.userId), userName: "Terminal Deck saved passwords",
                salt: CloudSecretsSpareCrypto.prfSalt(sub: subject.sub), excluded: excluded.compactMap { try? CloudSecretsCrypto.decode($0) })
            ranOut.cancel(); spareSheet = nil
            return made
        } catch {
            ranOut.cancel(); spareSheet = nil
            if spareSheetWithdrawn != nil { throw SpareSheetWithdrawn() }
            throw error
        }
    }
    /// A fresh look (the add just sent made the kept status stale): this generation has a spare that another device
    /// made. The new service says it in its status; an older one in one spare challenge.
    private func spareMadeElsewhere(epoch: Int) async -> Bool {
        if let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(), read.facts.newService {
            guard read.status.epoch == epoch, let made = read.facts.spare else { return false }
            return made.by != device.deviceId
        }
        guard let found = await spareChallenge() else { return false }
        return found.spares.contains { $0.epoch == epoch }
    }
    /// Point 4: said once in the log and kept beside the key, so the page says it until it is repaired or the generation
    /// changes. Review fix 2: worded so it is true in the race too (the other device may have been making it just then).
    private func noteSpareOrphaned(epoch: Int) async {
        log.say("passkey spare key: a second passkey was made on this Mac while another device was making your spare key; your spare key may no longer open")
        guard let bookPort, var book = await readBook() else { return }
        book.spareOrphaned = epoch
        book.spareAdded = Array(((book.spareAdded ?? []).filter { $0 != epoch } + [epoch]).suffix(16))
        try? await bookPort.saveHandOverBook(book)
    }
    private func clearSpareOrphaned() async {
        guard let bookPort, var book = await readBook(), book.spareOrphaned != nil else { return }
        book.spareOrphaned = nil
        try? await bookPort.saveHandOverBook(book)
    }
    /// Point 4: the page's warning: a second passkey was made here while this generation's spare was being made.
    public func spareOrphaned() async -> Bool {
        guard let key = try? await local.read(), key.acknowledged != false, let book = await readBook() else { return false }
        return book.spareOrphaned == key.epoch
    }
    /// Point 1: withdraws this Mac's open passkey sheet when this generation's spare was just made on another device.
    /// Review fix 1: the status may be the kept answer (a notice inside the minute after the last read only marks it
    /// stale), so when it shows no spare the ONE always-fresh spare challenge is asked too, only while a sheet is open.
    /// Nothing open: returns at once, with no service read. True when it withdrew one.
    @discardableResult
    public func withdrawSpareSheetIfMade() async -> Bool {
        guard let open = spareSheet, !open.replacing, spareSheetWithdrawn == nil else { return false }
        let facts = control as? any CloudSecretsStatusFactsPort
        var made: CloudSecretsStatusFacts.Change?
        if let read = try? await facts?.statusFacts(), read.status.epoch == open.epoch, let found = read.facts.spare {
            guard found.by != device.deviceId else { return false }
            made = found
        }
        if made == nil {
            guard let fresh = await spareChallenge(), fresh.spares.contains(where: { $0.epoch == open.epoch }) else { return false }
            // The challenge (a send) made the kept status stale: this read is fresh and names the maker.
            if let read = try? await facts?.statusFacts(), read.status.epoch == open.epoch, let found = read.facts.spare {
                guard found.by != device.deviceId else { return false }
                made = found
            }
        }
        guard let current = spareSheet, !current.replacing, spareSheetWithdrawn == nil else { return false }
        var name = "another device"
        if let made { name = await nameOf(made.by, shown: made.byName) }
        await noteSpareAdded(epoch: open.epoch)
        return await withdrawSpareSheet(because: "one was just made on " + name)
    }
    /// The system's cancel on the open sheet, said once.
    @discardableResult
    private func withdrawSpareSheet(because why: String) async -> Bool {
        guard let open = spareSheet, spareSheetWithdrawn == nil else { return false }
        spareSheetWithdrawn = why
        log.say("passkey spare key: sheet withdrawn: " + why)
        await open.passkey.cancel()
        return true
    }
    /// How "Make my spare key again" ended.
    public enum SpareRepair: Sendable, Equatable {
        /// The system refused the new passkey because the spare's passkey is still on this Mac: the spare opens.
        case stillWorks
        case replaced
        case cancelled
        /// Not done, with the reason in plain words (never a code of his, never an id).
        case notDone(String)
    }
    /// Point 4 repair (service 7750c816e), his own press only: a FRESH passkey sheet made with the stored spare's
    /// passkey excluded. The system refusing it means that passkey is still here: the spare opens, nothing is replaced.
    /// Otherwise the new passkey seals the key and `POST /secrets/spare/replace` names the stored spare in `replaces`,
    /// signed by this device (TD-PASSWORDS-SPARE-REPLACE-1). Never the registration of a refused add (review rule).
    public func repairSpare(passkey: any CloudSecretsPasskeyPort) async -> SpareRepair {
        do {
            return try await repairSpareHere(passkey: passkey)
        } catch is CloudSecretsPasskeyExcluded {
            await clearSpareOrphaned()
            log.say("passkey spare key: your spare key still works (its passkey is still on this Mac); nothing replaced")
            return .stillWorks
        } catch is CancellationError {
            log.say("passkey spare key: make it again: sheet cancelled")
            return .cancelled
        } catch is SpareSheetWithdrawn {
            return .notDone("the request ran out before the passkey was made")
        } catch {
            let why = CloudSecretsLog.spareCause(error)
            log.say("passkey spare key: make it again did not finish: " + why)
            return .notDone(why)
        }
    }
    private func repairSpareHere(passkey: any CloudSecretsPasskeyPort) async throws -> SpareRepair {
        try enter(); defer { busy = false }
        let key = try await currentKey()
        guard let spares = control as? any CloudSecretsSparePort, let replacer = control as? any CloudSecretsSpareReplacePort,
              await passkey.available() else { throw CloudFailure.unavailable }
        log.say("passkey spare key: make it again pressed")
        // A fresh challenge (always answered fresh); "spares must be empty" does not apply when replacing.
        let challenge = try await askSpareChallenge(spares)
        guard challenge.expiresAt > policy.now() else { throw CloudFailure.invalidRequest }
        // The stored spare's passkey: from the status (fresh: the challenge was a send), else from the challenge.
        var stored: String?
        if let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(), read.status.epoch == key.epoch {
            stored = read.facts.spareCredentialId
        }
        if stored == nil { stored = challenge.spares.first(where: { $0.epoch == key.epoch })?.credentialId }
        guard let replaces = stored else {
            throw CloudFailure.remote(.init(code: "no_spare", message: "no spare on file", retryable: false, requestId: challenge.challengeId))
        }
        let made = try await createSheet(passkey: passkey, challenge: challenge, epoch: key.epoch, excluded: [replaces], replacing: true)
        var prf = made.prf
        defer { prf.resetBytes(in: 0..<prf.count) }
        let credentialId = CloudSecretsCrypto.encode(made.credentialId)
        let spare = try CloudSecretsSpareCrypto.seal(root: key.root, prf: prf, sub: subject.sub, credentialId: credentialId,
            epoch: key.epoch, createdAt: policy.now(), deviceName: device.label)
        guard try CloudSecretsSpareCrypto.open(spare, prf: prf, sub: subject.sub) == key.root else { throw CloudFailure.checksumMismatch }
        let signature = try await keys.signDevicePayload(CloudSecretsProof.spareReplace(sub: subject.sub, by: device.deviceId, epoch: key.epoch,
            credentialId: credentialId, spare: spare, replaces: replaces))
        try await permitted()
        let replaced = try await replacer.replaceSpare(.init(requestId: UUID().uuidString.lowercased(), challengeId: challenge.challengeId,
            credentialId: credentialId, attestationObject: CloudSecretsCrypto.encode(made.attestationObject),
            clientDataJSON: CloudSecretsCrypto.encode(made.clientDataJSON), spare: spare, signature: CloudSecretsCrypto.encode(signature),
            replaces: replaces))
        guard replaced == replaces else { throw CloudFailure.checksumMismatch }
        await clearSpareOrphaned()
        await noteSpareAdded(epoch: key.epoch)
        log.say("passkey spare key: replaced on this Mac (made again with a new passkey)")
        return .replaced
    }
    /// Who last replaced this generation's spare and when (`name` nil = this Mac), from the service's own record.
    public func spareReplaced() async -> (name: String?, at: Int64)? {
        guard (try? await permitted()) != nil, let port = control as? any CloudSecretsStatusFactsPort,
              let read = try? await port.statusFacts(), let replaced = read.facts.spareReplaced else { return nil }
        return (replaced.by == device.deviceId ? nil : Optional(await nameOf(replaced.by, shown: replaced.byName)), replaced.at)
    }
    /// This generation has a spare on file: recorded beside the key, so it is never offered again for it.
    private func noteSpareAdded(epoch: Int) async {
        guard let bookPort, var book = await readBook() else { return }
        book.spareAdded = Array(((book.spareAdded ?? []).filter { $0 != epoch } + [epoch]).suffix(16))
        book.spareCancelledAt = nil
        try? await bookPort.saveHandOverBook(book)
    }
    /// How one try to make the spare ended.
    public enum SpareOutcome: Sendable, Equatable { case added, cancelled, failed, notOffered }
    /// Owner (14 Nov): the spare key is made with no question beyond the system's own passkey sheet. It OFFERS ITSELF:
    /// - only where the platform and the service can do it and no spare of this generation is on file;
    /// - at most once per app start;
    /// - not again for a day after he cancelled that sheet.
    /// Gap 2: the offer is used up only after the service ANSWERED the add (`spareAdded`); a cancelled or failed sheet
    /// leaves it open, and "Make a passkey spare key" (his press, `makeSpare`) is there meanwhile. True when one was made.
    @discardableResult
    public func offerSpareOnce(passkey: (any CloudSecretsPasskeyPort)?) async -> Bool {
        guard let passkey, !spareOfferedThisRun, bookPort != nil, let book = await readBook(), let key = try? await local.read(),
              key.acknowledged != false, !(book.spareAdded ?? []).contains(key.epoch) else { return false }
        guard await passkey.available() else {
            if !spareUnavailableSaid { spareUnavailableSaid = true; log.say("passkey spare key: not offered: passkeys are not available in this build of the app") }
            return false
        }
        spareOfferedThisRun = true
        if let at = book.spareCancelledAt, policy.now() - at < 86_400_000, policy.now() >= at {
            log.say("passkey spare key: not offered by itself today: you cancelled it " + CloudSecretsLog.date(at))
            return false
        }
        return await runSpare(passkey: passkey, how: "offered by itself") == .added
    }
    /// "Make a passkey spare key" on the Cloud page: his own press (the graph refuses one right after remote control).
    /// Not held back by the once-per-start or the one-day rule.
    public func makeSpare(passkey: any CloudSecretsPasskeyPort) async -> SpareOutcome {
        guard await passkey.available() else { log.say("passkey spare key: not made: passkeys are not available in this build of the app"); return .failed }
        return await runSpare(passkey: passkey, how: "asked for by your press")
    }
    private func runSpare(passkey: any CloudSecretsPasskeyPort, how: String) async -> SpareOutcome {
        guard let key = try? await local.read(), key.acknowledged != false else { return .notOffered }
        // Point 2: read right before the sheet, by itself or by his press. The new service says in its status whether this
        // generation has a spare (a spare never goes away within a generation, so a kept "on file" is right); a kept
        // "none" is then checked by the ONE challenge below, which the service answers fresh with the spare on file.
        if let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(), read.facts.newService,
           read.status.epoch == key.epoch, let made = read.facts.spare {
            await noteSpareAdded(epoch: key.epoch)
            log.say("passkey spare key: not offered: one is already on file, made on " + (await nameOf(made.by, shown: made.byName)))
            return .notOffered
        }
        // ONE challenge: it says the service keeps spares, shows none is on file, and is the one the passkey answers.
        guard let challenge = await spareChallenge() else { log.say("passkey spare key: not made: no challenge from the service"); return .failed }
        guard challenge.spares.filter({ $0.epoch == key.epoch }).isEmpty else {
            await noteSpareAdded(epoch: key.epoch)
            log.say("passkey spare key: not offered: one is already on file")
            return .notOffered
        }
        log.say("passkey spare key: " + how)
        do {
            try await addSpare(passkey: passkey, challenge: challenge)
            log.say("passkey spare key: made and confirmed")
            return .added
        } catch is SpareSheetWithdrawn {
            // Point 1: withdrawn by this Mac (its line is written); not his cancel, so no one-day hold.
            return .notOffered
        } catch is SpareOrphaned {
            return .failed
        } catch is CancellationError {
            if let bookPort, var book = await readBook() {
                book.spareCancelledAt = policy.now()
                try? await bookPort.saveHandOverBook(book)
            }
            log.say("passkey spare key: sheet cancelled; it offers itself again tomorrow at the earliest")
            return .cancelled
        } catch {
            log.say("passkey spare key: not made: " + CloudSecretsLog.cause(error))
            return .failed
        }
    }
    /// Whether "Make a passkey spare key" can help: this Mac holds the confirmed key and the service says (in its
    /// status, no challenge asked) that this generation has no spare. A service that does not say: false.
    public func spareMissing() async -> Bool {
        guard (try? await permitted()) != nil, let key = try? await local.read(), key.acknowledged != false,
              let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(), read.facts.newService,
              read.status.epoch == key.epoch else { return false }
        return read.facts.spare == nil
    }
    /// Who sealed THIS Mac's copy of the key (the device that answered it, or "this Mac" after a set-up or a passkey
    /// open here). nil = no copy here, or Cloud could not be asked. Names only.
    public func copyFrom() async -> String? {
        guard (try? await permitted()) != nil, let key = try? await local.read(), key.subject == subject,
              let receipt = try? await control.envelope(), receipt.epoch == key.epoch,
              receipt.deviceEnvelope.targetDeviceId == device.deviceId else { return nil }
        let author = receipt.deviceEnvelope.authorDeviceId
        copyAuthor = (key.epoch, author)
        // Point 6: the friendly name (one source); the recorded label (a host name) only when nothing else names it.
        let label = author == device.deviceId || friendly[author] != nil ? nil : (try? await control.registeredDevice(author))?.label
        return await nameOf(author, fallback: label)
    }
    /// The device that sealed THIS Mac's copy, per generation, once `copyFrom` read it (it held the key then).
    private var copyAuthor: (epoch: Int, deviceId: String)?
    /// Point 8: EVERY device this Mac knows holds the current key: itself; the device that sealed its copy; the devices
    /// it answered by itself for this generation; the device that made this generation's spare; and the devices the
    /// account's list shows approved for saved passwords. One name each (friendly names, one source). The service's
    /// count is the full number.
    public func holdersKnownHere() async -> [String] {
        guard let key = try? await local.read(), key.subject == subject, key.acknowledged != false else { return [] }
        var ids: [String] = []
        func add(_ id: String) { if id != device.deviceId, !ids.contains(id) { ids.append(id) } }
        if let copyAuthor, copyAuthor.epoch == key.epoch { add(copyAuthor.deviceId) }
        if let book = await readBook() {
            for entry in book.answered where entry.hasSuffix("@" + String(key.epoch)) {
                add(String(entry.dropLast(String(key.epoch).count + 1)))
            }
        }
        if let port = control as? any CloudSecretsStatusFactsPort, let read = try? await port.statusFacts(),
           read.status.epoch == key.epoch, let made = read.facts.spare { add(made.by) }
        for entry in await friendlyNames().values.sorted(by: { $0.name < $1.name }) where entry.holdsKey { add(entry.deviceId) }
        var names = ["this Mac"]
        for id in ids {
            let name = await nameOf(id)
            if name != CloudSecretsLog.name(nil), !names.contains(name) { names.append(name) }
        }
        return names
    }
    /// Opens the saved passwords on THIS device with his passkey (one Touch ID): a new device under the stricter
    /// setting, or any device when nobody else can open the Cloud copy ("Open with my passkey"). This device seals the
    /// key for itself and signs it (as at set-up); the service takes it only with a valid assertion of that passkey;
    /// then the same local save and possession as after an approval.
    public func openWithSpare(passkey: any CloudSecretsPasskeyPort) async throws {
        try enter(); defer { busy = false }
        try await permitted()
        guard let spares = control as? any CloudSecretsSparePort else { throw CloudFailure.unavailable }
        let status = try await control.status()
        let held = try await local.read()
        guard status.state == .ready, (held?.epoch ?? 0) < status.epoch else { throw CloudFailure.versionChanged }
        let challenge = try await askSpareChallenge(spares)
        let current = challenge.spares.filter { $0.epoch == status.epoch }
        guard challenge.expiresAt > policy.now(), !current.isEmpty else { throw CloudFailure.secretsLocked }
        log.say("open with your passkey: system passkey sheet shown")
        let used = try await passkey.use(challenge: CloudSecretsCrypto.decode(challenge.challenge),
            allowed: try current.map { try CloudSecretsCrypto.decode($0.credentialId) }, salt: CloudSecretsSpareCrypto.prfSalt(sub: subject.sub))
        var prf = used.prf
        defer { prf.resetBytes(in: 0..<prf.count) }
        let credentialId = CloudSecretsCrypto.encode(used.credentialId)
        guard let spare = current.first(where: { $0.credentialId == credentialId }) else { throw CloudFailure.checksumMismatch }
        var root = try CloudSecretsSpareCrypto.open(spare, prf: prf, sub: subject.sub)
        defer { root.resetBytes(in: 0..<root.count) }
        // Kept on purpose (Decker, 14 Nov: C5 withdrawn): the recovery copy gives its version, its signing key and the
        // "no recovery words" flag, which the status does not carry. One recovery look, only when he opens with his passkey.
        let recovery = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: CloudSecretsCrypto.keyHash(device)))
        guard recovery.epoch == status.epoch else { throw CloudFailure.versionChanged }
        let version = recovery.recoveryEnvelope.version
        let (envelope, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: root, sub: subject.sub, target: device,
            epoch: status.epoch, recoveryVersion: version, author: device.deviceId, sign: keys.signDevicePayload)
        try await permitted()
        let receipt: CloudSecretsEnvelopeReceipt
        do {
            receipt = try await spares.openWithSpare(.init(requestId: UUID().uuidString.lowercased(), challengeId: challenge.challengeId,
                credentialId: credentialId, authenticatorData: CloudSecretsCrypto.encode(used.authenticatorData),
                clientDataJSON: CloudSecretsCrypto.encode(used.clientDataJSON), signature: CloudSecretsCrypto.encode(used.signature),
                expectedVersion: status.version, deviceEnvelope: envelope, canaryHash: canaryHash))
        } catch {
            log.say("open with your passkey: open refused: " + CloudSecretsLog.cause(error))
            throw error
        }
        log.say("open with your passkey: open accepted by the service")
        guard receipt.epoch == status.epoch, receipt.deviceEnvelope == envelope else { throw CloudFailure.checksumMismatch }
        let fetched = try await control.envelope()
        guard fetched.deviceEnvelope == envelope, fetched.epoch == status.epoch else { throw CloudFailure.checksumMismatch }
        let body = try await CloudSecretsCrypto.unwrapDevice(fetched.deviceEnvelope, sub: subject.sub, targetDeviceId: device.deviceId,
            epoch: status.epoch, version: version, author: device.deviceId, authorKey: device.signPublicJwk, keys: keys)
        guard try CloudSecretsCrypto.decode(body.rootKey, count: 32) == root else { throw CloudFailure.checksumMismatch }
        let words = !recovery.recoveryEnvelope.isPlaceholder
        wordsKnown = words
        try await save(root: root, epoch: status.epoch, version: version, publicKey: recovery.recoveryEnvelope.publicSigningJwk,
                       acknowledged: false, recoveryWords: words)
        do { try await possess(body, version: fetched.version) }
        catch CloudFailure.remote(let detail) where detail.code == "secrets_locked" {}
        try await markAcknowledged()
        requestedApproval = nil; staleEnvelope = nil; possessionUnconfirmed = false
        log.say("opened with your passkey")
    }
    /// Review point 5: the Cloud copy exists but no device can open it (nobody holds the key and this Mac has no
    /// copy of its own). Asked only after `reopenOwnCopy` found nothing.
    /// The new service says it itself (`nobodyCanOpen`: no active device holds a key copy of this generation, approved
    /// OR not yet confirmed, which `approvedDeviceCount == 0` missed). The copy can still be opened with recovery words
    /// when a real recovery copy is there (`recoveryReady` and the words known to exist). Today's service (no field):
    /// exactly the earlier test.
    public func nobodyCanOpen() async -> Bool {
        guard (try? await permitted()) != nil, (try? await local.read()) == nil else { return false }
        if let port = control as? any CloudSecretsStatusFactsPort {
            guard let read = try? await port.statusFacts() else { return false }
            guard let nobody = read.facts.nobodyCanOpen else { return read.status.state == .ready && read.status.approvedDeviceCount == 0 }
            return read.status.state == .ready && nobody && !(read.status.recoveryReady && wordsKnown == true)
        }
        guard let status = try? await control.status() else { return false }
        return status.state == .ready && status.approvedDeviceCount == 0
    }
    /// Slice 2: who made this generation's passkey spare key and when, from the service's own record (never the name
    /// inside the sealed copy). `name` nil = this Mac. nil = none on file, or a service that does not say.
    public func spareMade() async -> (name: String?, at: Int64)? {
        guard (try? await permitted()) != nil, let port = control as? any CloudSecretsStatusFactsPort,
              let made = try? await port.statusFacts().facts.spare else { return nil }
        // Point 6: the same name source as every other line (the friendly name first).
        return (made.by == device.deviceId ? nil : Optional(await nameOf(made.by, shown: made.byName)), made.at)
    }
    /// Whether "Use recovery words" can help on this account: from this Mac's key, or from the recovery copy once
    /// it was read. nil = not known yet (then it is not offered).
    public func recoveryWordsExist() async -> Bool? {
        if let key = try? await local.read(), key.subject == subject, key.deviceId == device.deviceId { return key.recoveryWords ?? true }
        if let wordsKnown { return wordsKnown }
        // A Mac with no key yet asks the recovery copy ONCE (it spends one of the service's hourly recovery looks).
        guard !wordsAsked, !busy, (try? await permitted()) != nil, let status = try? await control.status(), status.state == .ready,
              status.recoveryReady else { return nil }
        wordsAsked = true
        guard let hash = try? CloudSecretsCrypto.keyHash(device),
              let copy = try? await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: hash)) else { return nil }
        wordsKnown = !copy.recoveryEnvelope.isPlaceholder
        return wordsKnown
    }
    /// The request this Mac is waiting on, if any (automatic hand-over asks again after it runs out).
    public func waitingRequest() -> CloudApproval? { requestedApproval }
    /// Call on the authenticated secrets-change event, never by polling a timer.
    /// Returns true only when a key was installed on this Mac; false means
    /// "still waiting" (a leftover envelope), and nothing may be unlocked.
    @discardableResult
    public func receiveApproval() async throws -> Bool {
        try enter(); defer { busy = false }
        try await permitted()
        guard let pending = requestedApproval, pending.expiresAt > policy.now(),
              pending.targetKeyHash == (try CloudSecretsCrypto.keyHash(device)) else { throw CloudFailure.invalidRequest }
        let status = try await control.status(), receipt = try await control.envelope()
        // An envelope from an earlier, ended attempt is not this request's
        // answer: stay pending quietly. No prompt (which would end the request)
        // and no recovery lookup (which spends the hourly recovery allowance).
        if let staleEnvelope, staleEnvelope == receipt.deviceEnvelope { return false }
        guard status.recoveryReady, status.state == .ready, status.version == receipt.version, status.epoch == receipt.epoch,
              receipt.deviceEnvelope.authorDeviceId != device.deviceId, receipt.deviceEnvelope.authorDeviceId != "recovery" else { throw CloudFailure.invalidRequest }
        let author = try await control.registeredDevice(receipt.deviceEnvelope.authorDeviceId)
        let recovery = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: pending.targetKeyHash))
        guard recovery.epoch == receipt.epoch, recovery.version == receipt.version else { throw CloudFailure.versionChanged }
        let body = try await CloudSecretsCrypto.unwrapDevice(receipt.deviceEnvelope, sub: subject.sub, targetDeviceId: device.deviceId,
            epoch: receipt.epoch, version: recovery.recoveryEnvelope.version, author: author.deviceId, authorKey: author.signPublicJwk, keys: keys)
        var root = try CloudSecretsCrypto.decode(body.rootKey, count: 32)
        defer { root.resetBytes(in: 0..<root.count) }
        // A retry after the root was already confirmed and saved: this Mac holds
        // exactly this root, so nothing new is trusted and no prompt is needed.
        let existing = try await local.read()
        let alreadyHeld = existing.map { $0.subject == subject && $0.deviceId == device.deviceId && $0.epoch == receipt.epoch && $0.root == root } ?? false
        wordsKnown = !recovery.recoveryEnvelope.isPlaceholder
        var answeredBy = CloudSecretsLog.name(author.label), bySelf = false
        if !alreadyHeld, signedRequest, let automatic {
            // Automatic hand-over (owner, 14 Nov): no code. The author must be a device THIS Mac already lists as
            // trusted, with exactly the signing key stored here (never the service's word at this moment); a stopped
            // or removed device, or one whose key changed, is never taken. Otherwise it stays waiting, quietly.
            guard let pinned = await automatic.pinned(author.deviceId), pinned.signKey == author.signPublicJwk else {
                log.say("an answer from " + answeredBy + " was not taken: not listed on this Mac with that key")
                throw CloudFailure.invalidRequest
            }
            answeredBy = CloudSecretsLog.name(pinned.name); bySelf = true
        } else if !alreadyHeld {
            // Possession alone does not authenticate a server-supplied author key.
            // No local save, migration, capture or export is allowed before this answer.
            let code = try CloudSecretsCrypto.transferCode(subject: subject, approval: pending, target: device,
                authorKey: author.signPublicJwk, envelope: receipt.deviceEnvelope)
            guard try await interaction.confirmTransferCode(.init(deviceName: author.label, platform: author.platform, matchingCode: code)) else {
                // A mismatch ends this request. A hostile server cannot re-prompt the
                // person with fresh forged envelopes until they give in; a new
                // request (and a new first code) is needed.
                requestedApproval = nil; staleEnvelope = nil; possessionUnconfirmed = false
                await interaction.dismiss()
                throw CancellationError()
            }
        }
        try await permitted()
        guard pending.expiresAt > policy.now() else { throw CloudFailure.invalidRequest }
        // §6.3 step 7 order: store and read back first, then acknowledge. A failed
        // save sends nothing, so this same request stays retryable.
        if !alreadyHeld {
            try await save(root: root, epoch: receipt.epoch, version: recovery.recoveryEnvelope.version,
                           publicKey: recovery.recoveryEnvelope.publicSigningJwk, acknowledged: false,
                           recoveryWords: !recovery.recoveryEnvelope.isPlaceholder)
        }
        do { try await possess(body, version: receipt.version) }
        catch let failure as CloudFailure {
            // The server refuses a second acknowledgment from an approved device.
            // After an acknowledgment whose answer was lost, that refusal is "done".
            if case .remote(let detail) = failure, detail.code == "secrets_locked", alreadyHeld, possessionUnconfirmed {}
            else {
                if case .remote = failure {} else { possessionUnconfirmed = true }
                throw failure
            }
        } catch { possessionUnconfirmed = true; throw error }
        try await markAcknowledged()
        requestedApproval = nil; staleEnvelope = nil; possessionUnconfirmed = false
        await interaction.finishApproval()
        if !alreadyHeld { log.say((bySelf ? "opened by itself: answered by " : "opened after the codes matched: answered by ") + answeredBy) }
        return true
    }
    /// The cloud confirmed this Mac: record it with the saved key.
    private func markAcknowledged() async throws {
        guard let key = try await local.read(), key.subject == subject, key.deviceId == device.deviceId else { throw CloudFailure.secretsLocked }
        guard key.acknowledged == false else { return }
        try await save(root: key.root, epoch: key.epoch, version: key.version, publicKey: key.recoveryPublicKey, acknowledged: true,
                       recoveryWords: key.recoveryWords)
    }
    /// The sign-out guard's two facts (lean scope R5), each as it really is. `keyOnThisMac`: a saved-passwords key
    /// for this identity exists on this Mac, also when it is waiting for Cloud or cannot be read right now (a
    /// blocked key is still a key that sign-out would strand; only "no such item" is no key).
    /// `recoveryWordsOnFile`: Cloud holds the recovery copy that the confirmed recovery words open (a vault can
    /// only be created after the words were confirmed); nil when Cloud could not be asked.
    public func signOutState() async -> CloudSecretsSignOutState {
        var keyHere = true
        do {
            if let key = try await local.read() { keyHere = key.subject == subject && key.deviceId == device.deviceId }
            else { keyHere = false }
        } catch { keyHere = true }
        var words: Bool?
        // Review point 6: after a silent set-up the recovery copy is a placeholder: no words exist.
        let noWords = await recoveryWordsExist() == false
        if (try? await permitted()) != nil, let remote = try? await control.status() {
            words = remote.state == .ready && remote.recoveryReady && !noWords
        }
        return .init(keyOnThisMac: keyHere, recoveryWordsOnFile: words, withoutWords: noWords)
    }
    public func protection() async -> CloudSecretsProtection {
        guard let key = try? await local.read(), key.subject == subject, key.deviceId == device.deviceId else { return .locked }
        return key.acknowledged == false ? .waitingForCloud : .protected
    }
    /// A Mac that saved its key after "Codes match" but never got the cloud's
    /// confirmation (quit, lost answer, request ran out): send the
    /// acknowledgement directly from the waiting envelope when it opens to the
    /// exact root already held. No new request, no prompt, nothing new trusted.
    @discardableResult
    public func confirmPendingAcknowledgement() async throws -> Bool {
        try enter(); defer { busy = false }
        try await permitted()
        guard let key = try await local.read(), key.subject == subject, key.deviceId == device.deviceId,
              key.acknowledged == false else { return false }
        let receipt = try await control.envelope()
        guard receipt.epoch == key.epoch, receipt.deviceEnvelope.targetDeviceId == device.deviceId,
              receipt.deviceEnvelope.authorDeviceId != device.deviceId, receipt.deviceEnvelope.authorDeviceId != "recovery" else { return false }
        let author = try await control.registeredDevice(receipt.deviceEnvelope.authorDeviceId)
        let body = try await CloudSecretsCrypto.unwrapDevice(receipt.deviceEnvelope, sub: subject.sub, targetDeviceId: device.deviceId,
            epoch: key.epoch, version: key.version, author: author.deviceId, authorKey: author.signPublicJwk, keys: keys)
        var root = try CloudSecretsCrypto.decode(body.rootKey, count: 32)
        defer { root.resetBytes(in: 0..<root.count) }
        guard root == key.root else { return false } // a different root is never trusted here
        do { try await possess(body, version: receipt.version) }
        catch CloudFailure.remote(let detail) where detail.code == "secrets_locked" {} // already approved
        try await markAcknowledged()
        requestedApproval = nil; staleEnvelope = nil; possessionUnconfirmed = false
        return true
    }
    public func recover() async throws {
        try enter(); defer { busy = false }
        try await permitted()
        var phrase = try await interaction.recoveryWords()
        defer { phrase.removeAll(keepingCapacity: false) }
        // Checksum failure never reaches the server.
        var entropy = try await words.entropy(words: phrase)
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        let recovery = try CloudRecoveryKeys(entropy: entropy, sub: subject.sub)
        let targetHash = try CloudSecretsCrypto.keyHash(device)
        let challenge = try await control.recoveryChallenge(.init(requestId: UUID().uuidString.lowercased(), targetKeyHash: targetHash))
        guard challenge.expiresAt > policy.now(), challenge.expiresAt <= policy.now() + 300_000 else { throw CloudFailure.invalidRequest }
        let root = try recovery.open(challenge.recoveryEnvelope, sub: subject.sub, epoch: challenge.epoch, version: challenge.recoveryEnvelope.version)
        let (envelope, _) = try await CloudSecretsCrypto.wrapDevice(root: root, sub: subject.sub, target: device,
            epoch: challenge.epoch, recoveryVersion: challenge.recoveryEnvelope.version, author: "recovery", sign: recovery.sign)
        let proof = try recovery.sign(CloudSecretsProof.recovery(challenge, target: device, envelope: envelope))
        try await permitted()
        let receipt = try await control.recover(.init(requestId: UUID().uuidString.lowercased(), challengeId: challenge.challengeId,
            targetKeyHash: targetHash, expectedVersion: challenge.version, deviceEnvelope: envelope, signature: CloudSecretsCrypto.encode(proof)))
        guard receipt.epoch == challenge.epoch, receipt.version > challenge.version, receipt.deviceEnvelope == envelope,
              receipt.secretsApproved == true else { throw CloudFailure.checksumMismatch }
        let fetched = try await control.envelope()
        guard fetched.deviceEnvelope == envelope, fetched.epoch == challenge.epoch, fetched.version == receipt.version else { throw CloudFailure.checksumMismatch }
        let unwrapped = try await CloudSecretsCrypto.unwrapDevice(fetched.deviceEnvelope, sub: subject.sub, targetDeviceId: device.deviceId,
            epoch: challenge.epoch, version: challenge.recoveryEnvelope.version, author: "recovery", authorKey: recovery.publicKey, keys: keys)
        guard try CloudSecretsCrypto.decode(unwrapped.rootKey, count: 32) == root else { throw CloudFailure.checksumMismatch }
        // §6.5 recovery/complete already proves possession with the recovery signature.
        try await save(root: root, epoch: challenge.epoch, version: challenge.recoveryEnvelope.version, publicKey: recovery.publicKey,
                       recoveryWords: true)
    }
}

/// The stricter setting as the Cloud page shows it (`CloudRecoveryCoordinator.askState`).
public struct CloudSecretsAskState: Sendable, Equatable {
    public let on: Bool
    /// He switched it off on another device; it is still on here (a relayed "off" is never taken).
    public let offElsewhere: Bool
    /// On here, and the service does not carry it to his other devices.
    public let thisMacOnly: Bool
    public init(on: Bool, offElsewhere: Bool, thisMacOnly: Bool) { self.on = on; self.offElsewhere = offElsewhere; self.thisMacOnly = thisMacOnly }
}

#if DEBUG
/// Proof P3 only: what lets saved passwords run for an identity whose issuer is not production's. DEBUG BUILDS
/// ONLY; a release build compiles none of this. It cannot be made unless every condition of lane A's scratch plan
/// (`NativeCloudScratch`) holds, checked here a second time so the coordinator never depends on the caller's care:
/// the data folder is not one a person uses (nothing under any "Library/Application Support", directly, through a
/// symbolic link or in another letter case, and never a folder with the real app's own name), the service is
/// exactly the TEST worker, and the issuer is neither production's nor anything on production's own domain.
/// It then admits that ONE issuer, compared exactly, and nothing else.
public struct CloudSecretsScratchPermit: Sendable, Equatable {
    /// The one service a scratch copy may talk to.
    public static let testHost = "td-cloud-test.terminaldeck.workers.dev"
    public let issuer: String
    public init?(dataRoot: URL, base: URL, issuer: String) {
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/") else { return nil }
        let root = Self.realPath(dataRoot)
        guard root != "/", !root.contains("/library/application support/"), !root.hasSuffix("/library/application support"),
              !root.hasSuffix("/terminaldeck") else { return nil }
        guard base.scheme == "https", base.path == "/v1", Self.plainHost(base) == Self.testHost, base.port == nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { return nil }
        guard !issuer.isEmpty, Self.plain(issuer) != Self.plain(CloudWire.issuer) else { return nil }
        if let named = URL(string: issuer), let host = Self.plainHost(named) {
            guard host != "terminaldeck.dev", !host.hasSuffix(".terminaldeck.dev") else { return nil }
        }
        self.issuer = issuer
    }
    func accepts(_ subject: CloudSubject) -> Bool { subject.issuer == issuer }
    /// A path as the disk sees it: symbolic links resolved (also when the last parts do not exist yet), compared
    /// without letter case.
    static func realPath(_ url: URL) -> String {
        var tail: [String] = []
        var current = url.standardizedFileURL
        while current.path != "/", !FileManager.default.fileExists(atPath: current.path) {
            tail.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
        }
        var resolved = current.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path.lowercased()
    }
    static func plainHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
    static func plain(_ text: String) -> String {
        var value = text.lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
#endif
