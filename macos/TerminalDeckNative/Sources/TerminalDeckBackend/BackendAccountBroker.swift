import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// The native wire frame: TS `wireText`'s three shell lines (server.ts:760) as
/// one JSON object over the framed unix socket — `pass`, `capture`, or `exit`
/// with the code, one line of stderr and stdout.
struct BackendAccountShimAnswer: Codable, Sendable, Equatable {
    let kind: String
    let code: Int
    let stdout: String
    let stderr: String
    var lookupReceipts: [String]? = nil
    static var pass: Self { Self(kind: "pass", code: 0, stdout: "", stderr: "") }
    static var capture: Self { Self(kind: "capture", code: 0, stdout: "", stderr: "") }
    static var missing: Self { Self(kind: "exit", code: 44, stdout: "", stderr: BackendAccountShimParsing.notFoundText) }
}

public struct BackendAccountSeatSnapshot: Sendable {
    public let sessionID: String
    public let launchAccountID: String
    public let servingAccountID: String?
    public let storeDirectory: String?
    public let processPID: Int32?
}

/// A successful password result was written to the provider-owned helper's
/// stdout and acknowledged over the authenticated same-UID channel. No token,
/// ticket or credential value is carried in this event.
public struct BackendAccountCredentialLookup: Sendable {
    public let sessionID: String
    public let accountID: String
    public let slot: String
    public let processPID: Int32
    public let sequence: UInt64
    public let deliveredAt: Date
}

/// TS `onCapture` (server.ts:301): an agent signed an account in, refreshed it,
/// had it moved in, or signed it out. Ids, slot and kind only — never a value.
public struct BackendAccountLoginCaptured: Sendable, Equatable {
    public let accountID: String
    public let slot: String
    /// `sign-in`, `refresh`, `adopted` or `signed-out`.
    public let kind: String
}

/// TS `onServed` (server.ts:306): a seat was first handed a different account's login.
public struct BackendAccountSeatServed: Sendable, Equatable {
    public let sessionID: String?
    public let accountID: String
}

/// TS `runReal` / wire.ts `runSecurity`: the real `security`, with these
/// arguments and this stdin. Production runs `/usr/bin/security`; tests inject
/// a recorder and never reach a keychain.
public typealias BackendAccountSecurityRunner = @Sendable ([String], String?) async -> BackendAccountSwitchInPlace.KeychainAnswer

enum BackendAccountKeychainRequest: Sendable, Equatable {
    case locked
    case find(slot: String, suffix: String?, password: Bool)
    case add(slot: String, suffix: String?, value: String)
    case delete(slot: String, suffix: String?)
    var suffix: String? { switch self { case .locked: nil; case .find(_, let value, _), .add(_, let value, _), .delete(_, let value): value } }
    var slot: String? { switch self { case .locked: nil; case .find(let value, _, _), .add(let value, _, _), .delete(let value, _): value } }
    var isFind: Bool { if case .find = self { true } else { false } }
    var isAdd: Bool { if case .add = self { true } else { false } }
    var isDelete: Bool { if case .delete = self { true } else { false } }
    var isLocked: Bool { if case .locked = self { true } else { false } }
    var wantsPassword: Bool { if case .find(_, _, true) = self { true } else { false } }
}

enum BackendAccountShimParsing {
    /// TS keychain-requests.ts `NOT_FOUND_TEXT`: `security`'s own wording, which the CLI string-matches on delete.
    static let notFoundText = "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
    /// TS `EXIT_NOT_FOUND`.
    static let exitNotFound: Int32 = 44
    /// TS keychain-shim.ts `REAL_SECURITY`: fixed by the system, never searched for.
    static let realSecurity = "/usr/bin/security"

    static func words(_ line: String) -> [String] {
        var words: [String] = [], current = "", quoted = false, escaped = false, inWord = false
        for character in line {
            if escaped { current.append(character); escaped = false; inWord = true; continue }
            if character == "\\" { escaped = true; inWord = true; continue }
            if character == "\"" { quoted.toggle(); inWord = true; continue }
            if !quoted && (character == " " || character == "\t") { if inWord { words.append(current) }; current = ""; inWord = false }
            else { current.append(character); inWord = true }
        }
        if escaped { current.append("\\") }
        if inWord { words.append(current) }
        return words
    }
    static func service(_ service: String) -> (slot: String, suffix: String?)? {
        for pattern in [#"^Claude Code((?:-[a-z]+)*)-credentials(?:-([0-9a-f]{8}))?$"#, #"^Claude Code(?:-([0-9a-f]{8}))?$"#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: service, range: NSRange(service.startIndex..., in: service)) else { continue }
            func group(_ index: Int) -> String? { guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: service) else { return nil }; return String(service[range]) }
            if match.numberOfRanges == 3 { return ("keychain:Claude Code\(group(1) ?? "")-credentials", group(2)) }
            return ("keychain:Claude Code", group(1))
        }
        return nil
    }
    static func command(_ argv: [String]) -> BackendAccountKeychainRequest? {
        guard let command = argv.first else { return nil }
        if command == "show-keychain-info", argv.count == 1 { return .locked }
        guard ["find-generic-password", "add-generic-password", "delete-generic-password"].contains(command) else { return nil }
        let valuesFlags: Set<String> = ["-a", "-s", "-X", "-l", "-D", "-j", "-c", "-C", "-G", "-r", "-T", "-k"]
        var values: [String: String] = [:], passwordFlag = false, i = 1
        while i < argv.count {
            let flag = argv[i]
            if flag == "-w" { passwordFlag = true; if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") { values[flag] = argv[i + 1] } }
            else if valuesFlags.contains(flag), i + 1 < argv.count { values[flag] = argv[i + 1]; i += 1 }
            i += 1
        }
        guard let name = values["-s"], let service = service(name) else { return nil }
        if command == "find-generic-password" { return .find(slot: service.slot, suffix: service.suffix, password: passwordFlag) }
        if command == "delete-generic-password" { return .delete(slot: service.slot, suffix: service.suffix) }
        var value = values["-w"]
        if let hex = values["-X"] {
            guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil else { return nil }
            var bytes = Data(), index = hex.startIndex
            while index < hex.endIndex { let end = hex.index(index, offsetBy: 2); guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }; bytes.append(byte); index = end }
            value = String(decoding: bytes, as: UTF8.self)
        }
        guard let value, !value.isEmpty else { return nil }
        return .add(slot: service.slot, suffix: service.suffix, value: value)
    }
    static func call(_ argv: [String], stdin: String) -> [BackendAccountKeychainRequest]? {
        if argv == ["-i"] {
            // TS `stdin.split(/\r?\n/)`: a Swift "\r\n" is one Character, so both are named.
            let lines = stdin.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "quit" && $0 != "exit" }
            guard !lines.isEmpty else { return nil }
            var requests: [BackendAccountKeychainRequest] = []
            for line in lines { guard let value = command(words(line)) else { return nil }; requests.append(value) }
            return requests
        }
        return command(argv).map { [$0] }
    }
    static func hash(_ directory: String) -> String { SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description }
    static func suffixes(_ directory: String?) -> Set<String?> {
        guard let directory else { return [nil] }
        return [hash(directory), hash(directory.precomposedStringWithCanonicalMapping)]
    }
    static func serviceName(slot: String, directory: String?) -> String {
        let base = String(slot.dropFirst("keychain:".count))
        return directory.map { base + "-" + hash($0.precomposedStringWithCanonicalMapping) } ?? base
    }
    /// TS `keychainUser()`: the account name the CLI files its items under.
    static func keychainUser(_ environment: [String: String], fallback: () -> String = { NSUserName() }) -> String {
        var name = environment["USER"] ?? ""
        if name.isEmpty { name = fallback() }
        return name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? name : "claude-code-user"
    }
}

/* ---------------------------------------------------------------- tickets -- */

/// TS server.ts `TicketBook`: every ticket this run minted. A seat per session
/// (minted for one launch, bound to its session, retargeted by an account
/// switch, released when the process ends) and a ticket per account for the
/// short-lived probes. Thread-safe: the broker actor and the request path share it.
public final class BackendAccountTicketBook: @unchecked Sendable {
    /// TS `Seat.launchDir`: `undefined` (the launch account's own folder, read
    /// when asked), `null` (the machine's own install: no hash), or a folder.
    public enum LaunchNaming: Sendable, Equatable { case launchAccount, unsuffixed, folder(String) }
    /// TS `Seat`, plus the native process binding used for credential receipts.
    public struct Seat: Sendable, Equatable {
        public let launch: String
        public let launchDir: LaunchNaming
        public let storeDir: String?
        public fileprivate(set) var serving: String?
        public fileprivate(set) var lastServed: String?
        public fileprivate(set) var sessionID: String?
        public fileprivate(set) var processPID: Int32?
    }
    private let lock = NSLock()
    private var seats: [String: Seat] = [:]
    private var byAccount: [String: String] = [:]
    private var bySession: [String: String] = [:]
    public init() {}

    /// TS `randomBytes(24).toString('hex')`. Caller holds the lock.
    private func mint(_ seat: Seat) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        arc4random_buf(&bytes, bytes.count)
        let ticket = bytes.map { String(format: "%02x", $0) }.joined()
        seats[ticket] = seat
        return ticket
    }
    /// TS `ticketFor`: this account's own ticket, minted the first time it is asked for.
    public func ticketFor(_ accountID: String) -> String {
        lock.withLock {
            if let held = byAccount[accountID], seats[held] != nil { return held }
            let ticket = mint(Seat(launch: accountID, launchDir: .launchAccount, storeDir: nil, serving: accountID, lastServed: accountID))
            byAccount[accountID] = ticket
            return ticket
        }
    }
    /// TS `seat`: started as `launch`, naming its keychain items after `launchDir` (nil: no hash), served as `serving`.
    public func seat(launch: String, launchDir: String?, serving: String? = nil, storeDir: String? = nil) -> String {
        lock.withLock {
            mint(Seat(launch: launch, launchDir: launchDir.map(LaunchNaming.folder) ?? .unsuffixed, storeDir: storeDir,
                      serving: serving ?? launch, lastServed: serving ?? launch))
        }
    }
    /// TS `bind`: a per-account ticket is never tied. Native also refuses to re-tie a bound seat.
    @discardableResult
    public func bind(_ ticket: String, sessionID: String) -> Bool {
        lock.withLock {
            guard var seat = seats[ticket], byAccount[seat.launch] != ticket, seat.sessionID == nil else { return false }
            seat.sessionID = sessionID; seats[ticket] = seat; bySession[sessionID] = ticket
            return true
        }
    }
    /// The minted ticket equal to `value`, compared in constant time against each candidate. Caller holds the lock.
    private func match(_ value: String) -> String? {
        let input = Array(value.utf8)
        guard input.count == 48, input.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        var found: String?
        for candidate in seats.keys {
            let other = Array(candidate.utf8)
            guard other.count == input.count else { continue }
            var difference: UInt8 = 0
            for index in input.indices { difference |= input[index] ^ other[index] }
            if difference == 0 { found = candidate }
        }
        return found
    }
    /// TS `seatOf`.
    public func seatOf(_ ticket: String) -> Seat? { lock.withLock { match(ticket).flatMap { seats[$0] } } }
    func canonical(_ ticket: String) -> String? { lock.withLock { match(ticket) } }
    /// TS `accountFor`: which account a ticket is answered as now.
    public func accountFor(_ ticket: String) -> String? { seatOf(ticket)?.serving }
    /// TS `sessionSeat`.
    public func sessionSeat(_ sessionID: String) -> Seat? { lock.withLock { bySession[sessionID].flatMap { seats[$0] } } }
    /// TS `retarget`: serve this session as another account from its next lookup on.
    @discardableResult
    public func retarget(_ sessionID: String, to accountID: String) -> Bool {
        lock.withLock {
            guard let ticket = bySession[sessionID], seats[ticket] != nil else { return false }
            seats[ticket]?.serving = accountID
            return true
        }
    }
    /// TS `noteServed`. Answers the seat as it was before (nil: no seat has this ticket).
    func noteServed(_ ticket: String, accountID: String) -> Seat? {
        lock.withLock {
            guard let before = seats[ticket] else { return nil }
            seats[ticket]?.lastServed = accountID
            return before
        }
    }
    /// TS `release`: the process has ended.
    public func release(_ sessionID: String) {
        lock.withLock { if let ticket = bySession.removeValue(forKey: sessionID) { seats[ticket] = nil } }
    }
    /// TS `revoke`: stop answering for this account.
    public func revoke(_ accountID: String) {
        lock.withLock {
            if let ticket = byAccount.removeValue(forKey: accountID) { seats[ticket] = nil }
            for ticket in Array(seats.keys) {
                if seats[ticket]?.serving == accountID { seats[ticket]?.serving = nil }
                if seats[ticket]?.lastServed == accountID { seats[ticket]?.lastServed = nil }
            }
        }
    }
    /// Native: a launch that never started gives its seat back.
    func abandon(_ ticket: String) {
        lock.withLock {
            guard let seat = seats.removeValue(forKey: ticket) else { return }
            if let session = seat.sessionID, bySession[session] == ticket { bySession[session] = nil }
            if byAccount[seat.launch] == ticket { byAccount[seat.launch] = nil }
        }
    }
    /// Native: the actual provider process a bound seat belongs to (for credential receipts).
    func bindProcess(sessionID: String, pid: Int32) -> Bool {
        lock.withLock {
            guard pid > 0, let ticket = bySession[sessionID], seats[ticket] != nil else { return false }
            seats[ticket]?.processPID = pid
            return true
        }
    }
    func clear() { lock.withLock { seats.removeAll(); byAccount.removeAll(); bySession.removeAll() } }
}

/* ---------------------------------------------------------------- answers -- */

/// TS server.ts: everything the socket decides, as functions of the request and
/// the deps, so the whole contract is tested without a socket.
enum BackendAccountVaultServer {
    typealias Answer = BackendAccountSwitchInPlace.KeychainAnswer
    typealias LoginSource = BackendAccountSwitchInPlace.LoginSource

    /// TS `VaultServerDeps`. Production builds these from the profile store
    /// (`BackendAccountBroker.productionDeps`); tests inject the TS fixtures.
    struct Deps: Sendable {
        var vault: BackendAccountVault
        var tickets: BackendAccountTicketBook
        var providerOf: @Sendable (String) async -> String?
        var configDirOf: @Sendable (String) async -> String?
        var adopting: @Sendable (String, String) async -> Bool
        var markKept: @Sendable (String, String) async -> Void
        var sourceOf: (@Sendable (String) async -> LoginSource?)? = nil
        var runReal: BackendAccountSecurityRunner? = nil
        var onCapture: (@Sendable (BackendAccountLoginCaptured) -> Void)? = nil
        var onServed: (@Sendable (BackendAccountSeatServed) -> Void)? = nil
    }
    /// TS `readBody`'s result: ticket, argv (at most 64), stdin.
    struct Request: Sendable, Equatable {
        let ticket: String
        let argv: [String]
        let stdin: String
    }
    /// TS `/keychain/captured` body: ticket, the real command's exit code, argv, its stdout.
    struct CaptureReport: Sendable, Equatable {
        let ticket: String
        let code: Int
        let argv: [String]
        let stdout: String
    }
    /// TS `KeychainStep` / `VaultStep`.
    struct Step: Sendable, Equatable {
        enum Via: Sendable, Equatable { case vault, keychain(service: String, adopt: Bool) }
        let via: Via
        let account: String
        let request: BackendAccountKeychainRequest
    }
    /// TS `WireAnswer`. `steps` never reaches the wire: the broker runs them first.
    enum WireAnswer: Sendable, Equatable {
        case pass, capture
        case exit(Answer)
        case steps(ticket: String, steps: [Step])
    }
    /// Native: a password handed to a seat, for which a credential receipt may be issued. Never the value.
    struct Delivery: Sendable, Equatable {
        let account: String
        let slot: String
    }

    static let ok = Answer(code: 0, stdout: "", stderr: "")
    static var notFound: Answer { Answer(code: BackendAccountShimParsing.exitNotFound, stdout: "", stderr: BackendAccountShimParsing.notFoundText) }

    /// TS `readBody` over the native JSON frame: nil for anything that is not a request.
    static func readBody(_ raw: NativeRPCValue) -> Request? {
        guard let elements = raw["argv"].elements, elements.count <= 64 else { return nil }
        let argv = elements.compactMap(\.string)
        guard argv.count == elements.count else { return nil }
        return Request(ticket: raw["ticket"].string ?? "", argv: argv, stdin: raw["stdin"].string ?? "")
    }

    /// TS `attributes`: the listing `find-generic-password` prints without `-w`.
    static func attributes(_ slot: String) -> String {
        let service = slot.hasPrefix("keychain:") ? String(slot.dropFirst("keychain:".count)) : slot
        return ["keychain: \"vault\"", "class: \"genp\"", "attributes:", "    \"svce\"<blob>=\"\(service)\""].joined(separator: "\n")
    }

    /// TS `answerOne`.
    static func answerOne(_ request: BackendAccountKeychainRequest, account: String, provider: String, deps: Deps) async -> Answer {
        switch request {
        case .locked:
            // Never locked: a "locked" here would make the agent skip a write the vault can take.
            return ok
        case .find(let slot, _, let password):
            guard let value = await deps.vault.readSlot(account, slot: slot) else { return notFound }
            return Answer(code: 0, stdout: password ? value : attributes(slot), stderr: "")
        case .add(let slot, _, let value):
            let held = await deps.vault.readSlot(account, slot: slot) != nil
            let kind = held ? "refresh" : "sign-in"
            let written = await deps.vault.write(accountID: account, provider: provider, slot: slot, value: value, source: kind)
            // Not the keychain's "locked" code: a plain failure lets the agent fall back to its own file.
            guard written.ok else { return Answer(code: 1, stdout: "", stderr: "security: \(written.message)") }
            await deps.markKept(account, slot)
            if written.changed { deps.onCapture?(BackendAccountLoginCaptured(accountID: account, slot: slot, kind: kind)) }
            return ok
        case .delete(let slot, _):
            // A sign-out settles the slot: an empty slot is an answer, and it must stay the answer.
            let held = await deps.vault.readSlot(account, slot: slot) != nil
            await deps.markKept(account, slot)
            guard held else { return notFound }
            let dropped = await deps.vault.dropSlot(account, slot: slot)
            guard dropped.ok else { return Answer(code: 1, stdout: "", stderr: "security: \(dropped.message)") }
            deps.onCapture?(BackendAccountLoginCaptured(accountID: account, slot: slot, kind: "signed-out"))
            return ok
        }
    }

    /// TS's `string | null | undefined` naming, compared by `sameNaming`.
    private enum Naming: Equatable { case unknown, unsuffixed, folder(String) }
    private static func naming(_ directory: String?) -> Naming { directory.map(Naming.folder) ?? .unknown }
    /// TS `ownSuffixes`: the directory hashes a seat's own lookups carry (`nil`: the unsuffixed name).
    private static func ownSuffixes(_ seat: BackendAccountTicketBook.Seat, deps: Deps) async -> Set<String?> {
        switch seat.launchDir {
        case .unsuffixed: return [nil]
        case .folder(let directory): return BackendAccountShimParsing.suffixes(directory)
        case .launchAccount:
            guard let directory = await deps.configDirOf(seat.launch) else { return [] }
            return BackendAccountShimParsing.suffixes(directory)
        }
    }
    /// TS `seatNaming`.
    private static func seatNaming(_ seat: BackendAccountTicketBook.Seat, deps: Deps) async -> Naming {
        switch seat.launchDir {
        case .unsuffixed: return .unsuffixed
        case .folder(let directory): return .folder(directory)
        case .launchAccount: return naming(await deps.configDirOf(seat.launch))
        }
    }
    /// TS `accountNaming`.
    private static func accountNaming(_ account: String, source: LoginSource?, deps: Deps) async -> Naming {
        switch source {
        case nil: return .unknown
        case .keychain(let directory)?: return directory.map(Naming.folder) ?? .unsuffixed
        case .vault?: return naming(await deps.configDirOf(account))
        }
    }
    /// TS `sameNaming`: two namings the CLI would hash the same.
    private static func sameNaming(_ a: Naming, _ b: Naming) -> Bool {
        switch (a, b) {
        case (.unknown, _), (_, .unknown): return false
        case (.unsuffixed, .unsuffixed): return true
        case (.folder(let x), .folder(let y)): return x.precomposedStringWithCanonicalMapping == y.precomposedStringWithCanonicalMapping
        default: return false
        }
    }
    /// TS `carriesOwnHash`.
    private static func carriesOwnHash(_ request: BackendAccountKeychainRequest, _ own: Set<String?>) -> Bool {
        request.isLocked || own.contains(request.suffix)
    }
    /// TS `sourceFor`: where a login is served from, defaulting to the vault.
    static func sourceFor(_ account: String, deps: Deps) async -> LoginSource? {
        guard let sourceOf = deps.sourceOf else { return .vault }
        return await sourceOf(account)
    }
    /// TS `served`: record whose login a lookup was answered with, and say so when it changed.
    private static func served(_ ticket: String, seat: BackendAccountTicketBook.Seat, account: String, deps: Deps) {
        let before = deps.tickets.noteServed(ticket, accountID: account) ?? seat
        if before.lastServed != account { deps.onServed?(BackendAccountSeatServed(sessionID: before.sessionID, accountID: account)) }
    }

    /// TS `answerShim`.
    static func answerShim(_ request: Request?, deps: Deps) async -> WireAnswer {
        var delivered: [Delivery] = []
        return await answerShim(request, deps: deps, delivered: &delivered)
    }
    static func answerShim(_ request: Request?, deps: Deps, delivered: inout [Delivery]) async -> WireAnswer {
        guard let request, let requests = BackendAccountShimParsing.call(request.argv, stdin: request.stdin) else { return .pass }
        let found = deps.tickets.seatOf(request.ticket)
        let serving = found?.serving
        var provider: String?
        if let serving { provider = await deps.providerOf(serving) }
        // A ticket this run did not mint, or an account that has been deleted:
        // "not found", never somebody else's token, and never the real keychain.
        guard let seat = found, let serving, let provider else {
            return .exit(requests.allSatisfy(\.isLocked) ? ok : notFound)
        }
        // Somebody else's lookup carrying this seat's inherited ticket (a nested
        // agent with its own folder): the real command, untouched.
        let own = await ownSuffixes(seat, deps: deps)
        guard requests.allSatisfy({ carriesOwnHash($0, own) }) else { return .pass }
        // Native: a write after the account last read was deleted would put that
        // account's tokens into whichever login is served now. Refused instead.
        var lastKnown = seat.lastServed
        for item in requests {
            if item.isFind { lastKnown = serving }
            else if item.isAdd || item.isDelete, lastKnown == nil {
                return .exit(Answer(code: 1, stdout: "", stderr: "security: the account used for the last credential lookup was removed. Read the current login again before writing."))
            }
        }
        // A lookup is answered as the account being served; a write or a
        // sign-out goes to the account whose login the process last read.
        func accountOf(_ item: BackendAccountKeychainRequest) -> String { item.isFind ? serving : (seat.lastServed ?? serving) }
        let seatNamed = await seatNaming(seat, deps: deps)
        func ownNames(_ account: String) async -> Bool {
            let source = await sourceFor(account, deps: deps)
            return sameNaming(seatNamed, await accountNaming(account, source: source, deps: deps))
        }
        func launchKeychain(_ account: String) async -> Bool {
            guard account == seat.launch, case .keychain? = await sourceFor(account, deps: deps) else { return false }
            return await ownNames(account)
        }

        // The agent's own login, on the seat it was started on: the real command, untouched.
        var allLaunch = true
        for item in requests {
            let launched = await launchKeychain(item.isLocked ? serving : accountOf(item))
            if !launched { allLaunch = false; break }
        }
        if allLaunch {
            if requests.contains(where: \.isFind) { served(request.ticket, seat: seat, account: serving, deps: deps) }
            return .pass
        }

        // A slot still on its pre-vault login, on the seat started as that account.
        if requests.count == 1, let only = requests.first, let slot = only.slot, !only.isAdd,
           accountOf(only) == seat.launch, await ownNames(seat.launch),
           await deps.adopting(seat.launch, slot), await deps.vault.readSlot(seat.launch, slot: slot) == nil {
            if only.isDelete {
                await deps.markKept(seat.launch, slot)
                return .pass
            }
            served(request.ticket, seat: seat, account: seat.launch, deps: deps)
            // `acceptCapture` is handed the argv and output, not stdin: an
            // interactive-mode lookup could never be kept, so it passes as what it is.
            let interactive = request.argv == ["-i"]
            return only.wantsPassword && !interactive ? .capture : .pass
        }

        // The steps: each request answered from wherever its account's login lives.
        var steps: [Step] = []
        for item in requests {
            guard let slot = item.slot else { steps.append(Step(via: .vault, account: serving, request: item)); continue }
            let account = accountOf(item)
            guard let source = await sourceFor(account, deps: deps) else {
                return .exit(item.isFind ? notFound : Answer(code: 1, stdout: "", stderr: "security: the app that keeps this login cannot reach it right now."))
            }
            if case .keychain(let directory) = source {
                steps.append(Step(via: .keychain(service: BackendAccountShimParsing.serviceName(slot: slot, directory: directory), adopt: false), account: account, request: item))
                continue
            }
            if !item.isAdd {
                let launchOwn = account == seat.launch ? await ownNames(account) : false
                if !launchOwn, await deps.adopting(account, slot), await deps.vault.readSlot(account, slot: slot) == nil,
                   let directory = await deps.configDirOf(account) {
                    steps.append(Step(via: .keychain(service: BackendAccountShimParsing.serviceName(slot: slot, directory: directory), adopt: true), account: account, request: item))
                    continue
                }
            }
            steps.append(Step(via: .vault, account: account, request: item))
        }
        if steps.contains(where: { $0.via != .vault }) { return .steps(ticket: request.ticket, steps: steps) }

        var last = ok
        var out: [String] = []
        for step in steps {
            let stepProvider = await deps.providerOf(step.account) ?? provider
            last = await answerOne(step.request, account: step.account, provider: stepProvider, deps: deps)
            if step.request.isFind { served(request.ticket, seat: seat, account: step.account, deps: deps) }
            if step.request.wantsPassword, last.code == 0, !last.stdout.isEmpty, let slot = step.request.slot { delivered.append(Delivery(account: step.account, slot: slot)) }
            if !last.stdout.isEmpty { out.append(last.stdout) }
        }
        return .exit(Answer(code: last.code, stdout: out.joined(separator: "\n"), stderr: last.stderr))
    }

    /// TS `keychainCommand`: the argv and stdin for one keychain step — the CLI's own commands.
    static func keychainCommand(_ request: BackendAccountKeychainRequest, service: String, user: String) -> (argv: [String], stdin: String?) {
        switch request {
        case .find(_, _, let password):
            return (["find-generic-password", "-a", user] + (password ? ["-w"] : []) + ["-s", service], nil)
        case .delete:
            return (["delete-generic-password", "-a", user, "-s", service], nil)
        case .add(_, _, let value):
            // Over stdin in interactive mode, never on a command line: argv is visible to every process.
            let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
            return (["-i"], "add-generic-password -U -a \"\(user)\" -s \"\(service)\" -X \"\(hex)\"\n")
        case .locked:
            return (["show-keychain-info"], nil)
        }
    }

    /// TS `runSteps`: each keychain step through the real `security`, each vault step from the vault.
    static func runSteps(ticket: String, steps: [Step], deps: Deps, user: String) async -> Answer {
        var delivered: [Delivery] = []
        return await runSteps(ticket: ticket, steps: steps, deps: deps, user: user, delivered: &delivered)
    }
    static func runSteps(ticket: String, steps: [Step], deps: Deps, user: String, delivered: inout [Delivery]) async -> Answer {
        let seat = deps.tickets.seatOf(ticket)
        var last = ok
        var out: [String] = []
        for step in steps {
            switch step.via {
            case .vault:
                guard let provider = await deps.providerOf(step.account) else { return notFound }
                last = await answerOne(step.request, account: step.account, provider: provider, deps: deps)
            case .keychain(let service, let adopt):
                guard let runReal = deps.runReal else {
                    return step.request.isFind ? notFound : Answer(code: 1, stdout: "", stderr: "security: nothing here can reach the keychain.")
                }
                let command = keychainCommand(step.request, service: service, user: user)
                last = await runReal(command.argv, command.stdin)
                if adopt, let slot = step.request.slot {
                    let provider = await deps.providerOf(step.account)
                    let value = last.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if step.request.wantsPassword, last.code == 0, !value.isEmpty, let provider {
                        let written = await deps.vault.write(accountID: step.account, provider: provider, slot: slot, value: value, source: "adopted")
                        if written.ok {
                            await deps.markKept(step.account, slot)
                            deps.onCapture?(BackendAccountLoginCaptured(accountID: step.account, slot: slot, kind: "adopted"))
                        }
                    } else if last.code == BackendAccountShimParsing.exitNotFound || step.request.isDelete {
                        await deps.markKept(step.account, slot)
                    }
                }
            }
            if step.request.isFind, let seat { served(ticket, seat: seat, account: step.account, deps: deps) }
            if step.request.wantsPassword, last.code == 0, !last.stdout.isEmpty, let slot = step.request.slot { delivered.append(Delivery(account: step.account, slot: slot)) }
            if !last.stdout.isEmpty { out.append(last.stdout.hasSuffix("\n") ? String(last.stdout.dropLast()) : last.stdout) }
        }
        return Answer(code: last.code, stdout: out.joined(separator: "\n"), stderr: last.stderr)
    }

    /// TS `acceptCapture`: kept only when the real command succeeded and printed something.
    static func acceptCapture(_ report: CaptureReport, deps: Deps) async -> Bool {
        guard report.argv.count <= 64, let seat = deps.tickets.seatOf(report.ticket), let serving = seat.serving, serving == seat.launch else { return false }
        // Only on the seat started as the account, under that account's own names.
        guard sameNaming(await seatNaming(seat, deps: deps), naming(await deps.configDirOf(seat.launch))) else { return false }
        let account = seat.launch
        guard let provider = await deps.providerOf(account) else { return false }
        guard let requests = BackendAccountShimParsing.call(report.argv, stdin: ""), requests.count == 1,
              let request = requests.first, request.wantsPassword, let slot = request.slot else { return false }
        guard await deps.adopting(account, slot) else { return false }
        guard carriesOwnHash(request, await ownSuffixes(seat, deps: deps)) else { return false }
        // "Not found" settles the slot; any other failure (36, locked) settles nothing.
        if report.code == Int(BackendAccountShimParsing.exitNotFound) {
            await deps.markKept(account, slot)
            return true
        }
        guard report.code == 0 else { return false }
        let value = report.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let written = await deps.vault.write(accountID: account, provider: provider, slot: slot, value: value, source: "adopted")
        guard written.ok else { return false }
        await deps.markKept(account, slot)
        deps.onCapture?(BackendAccountLoginCaptured(accountID: account, slot: slot, kind: "adopted"))
        return true
    }

    /// TS `wireText` as the native frame: stderr is one line (CR/LF runs become a space).
    static func wire(_ answer: WireAnswer) -> BackendAccountShimAnswer {
        switch answer {
        case .pass: return .pass
        case .capture: return .capture
        case .exit(let result):
            return BackendAccountShimAnswer(kind: "exit", code: Int(result.code), stdout: result.stdout,
                stderr: result.stderr.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression))
        case .steps: return wire(.exit(notFound))
        }
    }
}

/// TS `runSecurity` (wire.ts): run the real `security` once, never through a
/// shell, with this stdin, and hand back what it said. Five seconds at most.
public enum BackendAccountRealSecurity {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
    private final class Bytes: @unchecked Sendable {
        private let lock = NSLock(); private var value = Data()
        func set(_ data: Data) { lock.withLock { value = data } }
        var data: Data { lock.withLock { value } }
    }
    public static let runner: BackendAccountSecurityRunner = { argv, stdin in await BackendAccountRealSecurity.run(argv, stdin: stdin) }
    public static func run(_ argv: [String], stdin: String?, executable: String = "/usr/bin/security",
                           timeout: TimeInterval = 5) async -> BackendAccountSwitchInPlace.KeychainAnswer {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(argv, stdin: stdin, executable: executable, timeout: timeout))
            }
        }
    }
    static func runBlocking(_ argv: [String], stdin: String?, executable: String, timeout: TimeInterval) -> BackendAccountSwitchInPlace.KeychainAnswer {
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = argv
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        do { try child.run() } catch { return .init(code: 1, stdout: "", stderr: "security: \(error.localizedDescription)") }
        let timedOut = Flag(), stderrBytes = Bytes(), group = DispatchGroup()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if child.isRunning { timedOut.set(); child.terminate() } }
        timer.resume()
        let writer = input.fileHandleForWriting, body = Data((stdin ?? "").utf8)
        group.enter()
        DispatchQueue.global(qos: .utility).async { try? writer.write(contentsOf: body); try? writer.close(); group.leave() }
        let errorReader = errors.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .utility).async { stderrBytes.set(errorReader.readDataToEndOfFile()); group.leave() }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        group.wait(); child.waitUntilExit(); timer.cancel()
        if timedOut.isSet { return .init(code: 1, stdout: "", stderr: "security: the keychain did not answer in time.") }
        let code: Int32 = child.terminationReason == .exit ? child.terminationStatus : 1
        return .init(code: code, stdout: String(decoding: stdout, as: UTF8.self),
                     stderr: String(decoding: stderrBytes.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Listeners for the broker's TS `onCapture` / `onServed` events.
final class BackendAccountBrokerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: [UUID: @Sendable (BackendAccountLoginCaptured) -> Void] = [:]
    private var served: [UUID: @Sendable (BackendAccountSeatServed) -> Void] = [:]
    func onCapture(_ listener: @escaping @Sendable (BackendAccountLoginCaptured) -> Void) -> UUID { let id = UUID(); lock.withLock { capture[id] = listener }; return id }
    func onServed(_ listener: @escaping @Sendable (BackendAccountSeatServed) -> Void) -> UUID { let id = UUID(); lock.withLock { served[id] = listener }; return id }
    func remove(_ id: UUID) { lock.withLock { capture[id] = nil; served[id] = nil } }
    func removeAll() { lock.withLock { capture.removeAll(); served.removeAll() } }
    func captured(_ event: BackendAccountLoginCaptured) { for listener in lock.withLock({ Array(capture.values) }) { listener(event) } }
    func wasServed(_ event: BackendAccountSeatServed) { for listener in lock.withLock({ Array(served.values) }) { listener(event) } }
}

/// Concrete native broker. Its factory returns only after a real socket and
/// shim exist, the helper advertises the protocol, and the vault can encrypt.
public actor BackendAccountBroker {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    public nonisolated let socketPath: String
    /// TS `vaultShimDir`: beside the vault, never inside it, and not called `bin`
    /// (a confined session's plan grants a `bin` entry's parent too).
    public nonisolated let shimDirectory: String
    /// TS `TicketBook`: every seat and per-account ticket this run minted.
    public nonisolated let tickets: BackendAccountTicketBook
    /// The real `security` (TS `runtime.keychain`).
    public nonisolated let realSecurity: BackendAccountSecurityRunner
    nonisolated let deps: BackendAccountVaultServer.Deps
    private nonisolated let events: BackendAccountBrokerEvents
    private struct PendingReceipt: Sendable {
        let ticket: String
        let sessionID: String
        let accountID: String
        let slot: String
        let created: Date
    }
    private nonisolated let configuration: BackendAccountConfiguration
    private nonisolated let profiles: BackendAccountProfileStore
    private nonisolated let vault: BackendAccountVault
    private var server: BackendAccountUnixServer?
    private var receipts: [String: PendingReceipt] = [:]
    private var sequence: UInt64 = 0
    private var lookupListeners: [UUID: @Sendable (BackendAccountCredentialLookup) -> Void] = [:]

    private init(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore, vault: BackendAccountVault,
                 runner: @escaping BackendAccountSecurityRunner, deps: BackendAccountVaultServer.Deps?) {
        self.configuration = configuration; self.profiles = profiles; self.vault = vault; self.realSecurity = runner
        socketPath = Self.vaultSocketPath(vaultDirectory: configuration.dataDirectory.appendingPathComponent(BackendAccountVault.directoryName).path,
                                          home: configuration.homeDirectory.path, brand: configuration.appID)
        shimDirectory = configuration.dataDirectory.appendingPathComponent("account-vault-shim", isDirectory: true).path
        let events = BackendAccountBrokerEvents()
        self.events = events
        let book = deps?.tickets ?? BackendAccountTicketBook()
        tickets = book
        self.deps = deps ?? Self.productionDeps(configuration: configuration, profiles: profiles, vault: vault, tickets: book, runner: runner, events: events)
    }
    /// TS wire.ts `vaultSocketPath`: `<vault dir>/vault.sock`, or — when that would not fit a unix socket
    /// path (kept under 100 bytes, as the hook server's is) — `~/.<brand>/vault-<sha256(dir)[0..16]>.sock`.
    static func vaultSocketPath(vaultDirectory: String, home: String, brand: String) -> String {
        let natural = (vaultDirectory as NSString).appendingPathComponent("vault.sock")
        if natural.utf8.count <= 100 { return natural }
        let digest = String(BackendAccountSwitchInPlace.sha256Hex(vaultDirectory).prefix(16))
        // TS answers null when even this does not fit (the vault stays off); the socket bind then refuses.
        return ((home as NSString).appendingPathComponent("." + brand) as NSString).appendingPathComponent("vault-\(digest).sock")
    }
    public static func start(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore,
                             vault: BackendAccountVault) async throws -> BackendAccountBroker {
        try await launch(configuration: configuration, profiles: profiles, vault: vault, runner: BackendAccountRealSecurity.runner, deps: nil, verifyHelper: true)
    }
    /// D11 / TS wire.ts:163 (`return null`): the saved logins would not unlock, so there is no
    /// vault runtime: no socket, no shim, nothing served. Every broker call that needs the live
    /// socket refuses (`server == nil`), app-kept accounts read UNAVAILABLE_SENTENCE upstream, and
    /// the vault file is left exactly as it is. Only `BackendAccountLaunchAdapter.start` uses it.
    static func vaultOff(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore, vault: BackendAccountVault) -> BackendAccountBroker {
        BackendAccountBroker(configuration: configuration, profiles: profiles, vault: vault, runner: BackendAccountRealSecurity.runner, deps: nil)
    }
    /// The same broker, socket and shim without verifying or running the bundled
    /// helper. `deps` replaces the profile-store answers (TS `VaultServerDeps`).
    static func offline(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore, vault: BackendAccountVault,
                        runner: @escaping BackendAccountSecurityRunner, deps: BackendAccountVaultServer.Deps? = nil) async throws -> BackendAccountBroker {
        try await launch(configuration: configuration, profiles: profiles, vault: vault, runner: runner, deps: deps, verifyHelper: false)
    }
    private static func launch(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore, vault: BackendAccountVault,
                               runner: @escaping BackendAccountSecurityRunner, deps: BackendAccountVaultServer.Deps?, verifyHelper: Bool) async throws -> BackendAccountBroker {
        guard profiles.readiness == .ready, vault.readiness == .ready else { throw BackendAccountFailure("The full native facade must own profiles and vault before its broker starts.") }
        if verifyHelper { try BackendAccountSecurityShimClient.verifyHelper(configuration.helperExecutable) }
        try await vault.prepareForWrites()
        let broker = BackendAccountBroker(configuration: configuration, profiles: profiles, vault: vault, runner: runner, deps: deps)
        let socket = try BackendAccountUnixServer(path: broker.socketPath) { body, peerPID in await broker.handle(body, peerPID: peerPID) }
        await broker.install(socket)
        do { try broker.writeShim() } catch { await broker.close(); throw error }
        return broker
    }

    /// The helper's leading arguments: three environment key names, then this
    /// run's socket (TS keychain-shim.ts rule 1, `VAULT=`). Never a value or secret.
    public nonisolated var shimArguments: [String] {
        [configuration.socketEnvironment, configuration.ticketEnvironment, configuration.homeEnvironment,
         BackendAccountSecurityShimClient.socketMarker + socketPath]
    }
    nonisolated var shimScript: String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "#!/bin/sh\n# Written at every start and deleted at quit. Do not edit: this file is regenerated.\n"
            + "exec \(quoted(configuration.helperExecutable.path)) vault:security \(shimArguments.map(quoted).joined(separator: " ")) \"$@\"\n"
    }
    /// TS `writeSecurityShim`: replace the folder, holding nothing but `security`.
    private nonisolated func writeShim() throws {
        let directory = URL(fileURLWithPath: shimDirectory, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        // Earlier native builds kept it inside the vault's folder.
        try? FileManager.default.removeItem(at: configuration.dataDirectory.appendingPathComponent("account-vault/shim", isDirectory: true))
        guard FileManager.default.isExecutableFile(atPath: BackendAccountShimParsing.realSecurity) else {
            throw BackendAccountFailure("This Mac has no system security command, so Claude Code logins stay with the agent.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("security")
        try BackendAccountFiles.writeAtomic(Data(shimScript.utf8), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    private func install(_ server: BackendAccountUnixServer) { self.server = server }
    public func isActive() -> Bool { server != nil }

    /// TS wire.ts deps: answered from the profile store, exactly as `runtime.ts` rules them.
    static func productionDeps(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore, vault: BackendAccountVault,
                               tickets: BackendAccountTicketBook, runner: @escaping BackendAccountSecurityRunner,
                               events: BackendAccountBrokerEvents) -> BackendAccountVaultServer.Deps {
        let inherited = configuration.inheritedEnvironment
        @Sendable func profile(_ id: String) async -> BackendAccountProfile? { try? await profiles.find(id) }
        // TS `usable()`: a vault that is available and not locked (the shim exists while the broker runs).
        @Sendable func usable() async -> Bool {
            let available = await vault.available(), state = await vault.state()
            return available && state != .locked
        }
        return BackendAccountVaultServer.Deps(
            vault: vault, tickets: tickets,
            providerOf: { await profile($0)?.provider },
            configDirOf: { await profile($0)?.configDir },
            adopting: { id, slot in
                guard let account = await profile(id) else { return false }
                let managed = await profiles.managed(account), ready = await usable()
                return slotAdopting(account, managed: managed, slot: slot, usable: ready)
            },
            markKept: { id, slot in try? await profiles.markSlotKept(id: id, slot: slot) },
            sourceOf: { id in
                guard let account = await profile(id) else { return nil }
                let managed = await profiles.managed(account), ready = await usable()
                return loginSource(account, managed: managed, usable: ready, inherited: inherited)
            },
            runReal: runner,
            onCapture: { events.captured($0) },
            onServed: { events.wasServed($0) })
    }
    /// TS runtime.ts `slotAdopting`.
    static func slotAdopting(_ account: BackendAccountProfile, managed: Bool, slot: String, usable: Bool) -> Bool {
        let kept = BackendSessionSwitchKeptLogin.keptBy(account, managed: managed, usable: usable)
        guard kept == .app || kept == .adopting else { return false }
        if account.provider != "claude" || account.loginStore == "app" { return false }
        return !(account.keptSlots ?? []).contains(slot)
    }
    /// TS runtime.ts `loginSource`.
    static func loginSource(_ account: BackendAccountProfile, managed: Bool, usable: Bool,
                            inherited: [String: String]) -> BackendAccountSwitchInPlace.LoginSource? {
        guard account.provider == "claude" else { return nil }
        switch BackendSessionSwitchKeptLogin.keptBy(account, managed: managed, usable: usable) {
        case .app, .adopting: return .vault
        case .unavailable: return nil
        case .agent: return .keychain(directory: agentLaunchDir(account, inherited: inherited))
        }
    }
    /// TS runtime.ts `agentLaunchDir`.
    static func agentLaunchDir(_ account: BackendAccountProfile, inherited: [String: String]) -> String? {
        if !account.system { return account.configDir }
        let value = inherited["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
    /// TS `keychainUser(process.env, () => userInfo().username)`.
    nonisolated var keychainUser: String { BackendAccountShimParsing.keychainUser(configuration.inheritedEnvironment) }

    public func onCredentialLookup(_ listener: @escaping @Sendable (BackendAccountCredentialLookup) -> Void) -> UUID {
        let id = UUID(); lookupListeners[id] = listener; return id
    }
    public func removeCredentialLookupListener(_ id: UUID) { lookupListeners[id] = nil }
    /// TS `onCapture`: a login was kept, refreshed, moved in or signed out. Never a value.
    public nonisolated func onLoginCaptured(_ listener: @escaping @Sendable (BackendAccountLoginCaptured) -> Void) -> UUID { events.onCapture(listener) }
    /// TS `onServed`: a seat was first handed a different account's login.
    public nonisolated func onSeatServed(_ listener: @escaping @Sendable (BackendAccountSeatServed) -> Void) -> UUID { events.onServed(listener) }
    public nonisolated func removeEventListener(_ id: UUID) { events.remove(id) }

    public func bindProcess(sessionID: String, pid: Int32) throws {
        guard tickets.bindProcess(sessionID: sessionID, pid: pid) else { throw BackendAccountFailure("This live session has no account seat to bind to its actual process.") }
    }
    public func seatSnapshot(sessionID: String) -> BackendAccountSeatSnapshot? {
        guard let seat = tickets.sessionSeat(sessionID) else { return nil }
        return BackendAccountSeatSnapshot(sessionID: sessionID, launchAccountID: seat.launch, servingAccountID: seat.serving,
            storeDirectory: seat.storeDir, processPID: seat.processPID)
    }
    public func credentialSequence() -> UInt64 { sequence }
    /// Verifies a login can actually be served, adopting a legacy slot first
    /// (TS switch-in-place.ts `readyToServe`, both slots). Only the result is
    /// exposed, never the secret retrieved during adoption.
    public func readyToServe(accountID: String) async throws -> Bool {
        guard server != nil, let profile = try await profiles.find(accountID), profile.provider == "claude" else {
            throw BackendAccountFailure("This account cannot be served by the live Claude credential broker.")
        }
        guard let source = await BackendAccountVaultServer.sourceFor(profile.id, deps: deps) else {
            throw BackendAccountFailure("The selected account's login cannot be reached from here right now.")
        }
        for slot in ["keychain:Claude Code-credentials", "keychain:Claude Code"] {
            switch source {
            case .keychain(let directory):
                // Asked without `-w`: whether the item exists, never the secret itself.
                let service = BackendAccountShimParsing.serviceName(slot: slot, directory: directory)
                let asked = await realSecurity(["find-generic-password", "-a", keychainUser, "-s", service], nil)
                if asked.code == 0 { return true }
                if asked.code != BackendAccountShimParsing.exitNotFound { throw BackendAccountFailure("The selected account's login could not be read: " + asked.stderr) }
            case .vault:
                if try await vault.read(accountID: profile.id, slot: slot) != nil { return true }
                guard await deps.adopting(profile.id, slot) else { continue }
                let service = BackendAccountShimParsing.serviceName(slot: slot, directory: profile.configDir)
                let read = await realSecurity(["find-generic-password", "-a", keychainUser, "-w", "-s", service], nil)
                let value = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if read.code == 0, !value.isEmpty {
                    let written = await vault.write(accountID: profile.id, provider: profile.provider, slot: slot, value: value, source: "adopted")
                    guard written.ok else { throw BackendAccountFailure("The selected account's login could not be saved here: " + written.message) }
                    await deps.markKept(profile.id, slot)
                    deps.onCapture?(BackendAccountLoginCaptured(accountID: profile.id, slot: slot, kind: "adopted"))
                    return true
                }
                guard read.code == BackendAccountShimParsing.exitNotFound else { throw BackendAccountFailure("The selected account's existing login could not be read: " + read.stderr) }
                await deps.markKept(profile.id, slot)
            }
        }
        return false
    }
    public func allocateAccount(_ profile: BackendAccountProfile) throws -> (ticket: String, environment: [String: String]) {
        guard server != nil, !profile.system, profile.provider == "claude" else { throw BackendAccountFailure("An account probe ticket needs the live native broker and a named Claude account.") }
        let ticket = tickets.ticketFor(profile.id)
        return (ticket, [configuration.socketEnvironment: socketPath, configuration.ticketEnvironment: ticket])
    }
    public func allocate(home: BackendAccountProfile, serving: BackendAccountProfile) async throws -> (ticket: String, environment: [String: String]) {
        guard server != nil else { throw BackendAccountFailure("The native account socket has stopped.") }
        let managed = await profiles.managed(home)
        let launchDirectory: String
        let storeDirectory: String
        var environment: [String: String] = [:]
        if managed { launchDirectory = home.configDir; storeDirectory = home.configDir }
        else {
            let name = home.id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            let store = configuration.dataDirectory.appendingPathComponent("account-vault/store")  /* TS wire.ts:233 join(vaultDir, "store") */.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            launchDirectory = store; storeDirectory = store
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = store
        }
        let ticket = tickets.seat(launch: home.id, launchDir: launchDirectory, serving: serving.id, storeDir: storeDirectory)
        environment[configuration.socketEnvironment] = socketPath
        environment[configuration.ticketEnvironment] = ticket
        return (ticket, environment)
    }
    public func bind(ticket: String, sessionID: String) throws {
        guard tickets.bind(ticket, sessionID: sessionID) else { throw BackendAccountFailure("The native account launch ticket is absent or already bound.") }
    }
    public func abandon(ticket: String) { tickets.abandon(ticket); receipts = receipts.filter { $0.value.ticket != ticket } }
    public func release(sessionID: String) { tickets.release(sessionID); receipts = receipts.filter { $0.value.sessionID != sessionID } }
    public func retarget(sessionID: String, accountID: String) async throws -> Bool {
        guard let profile = try await profiles.find(accountID), profile.provider == "claude", tickets.sessionSeat(sessionID) != nil else { return false }
        try await vault.open()
        return tickets.retarget(sessionID, to: accountID)
    }
    public func revoke(accountID: String) { tickets.revoke(accountID) }

    /// TS session-switch-run.ts `liveInPlace()`: the switch-in-place deps over this broker.
    public nonisolated func switchInPlaceDependencies() -> BackendAccountSwitchInPlace.Dependencies {
        let tickets = tickets, deps = deps, vault = vault
        return BackendAccountSwitchInPlace.Dependencies(
            seat: { sessionID in
                tickets.sessionSeat(sessionID).map { seat in
                    var launchDirectory: String?
                    if case .folder(let directory) = seat.launchDir { launchDirectory = directory }
                    return BackendAccountSwitchInPlace.SeatView(launchAccountID: seat.launch, launchDirectory: launchDirectory, storeDirectory: seat.storeDir)
                }
            },
            source: { id in await BackendAccountVaultServer.sourceFor(id, deps: deps) },
            adopting: { id, slot in await deps.adopting(id, slot) },
            held: { id in await vault.has(id) },
            keep: { id, slot, value in
                guard let provider = await deps.providerOf(id) else { return false }
                if let value {
                    let written = await vault.write(accountID: id, provider: provider, slot: slot, value: value, source: "adopted")
                    guard written.ok else { return false }
                }
                await deps.markKept(id, slot)
                return true
            },
            keychain: realSecurity, user: keychainUser,
            retarget: { [self] sessionID, accountID in (try? await self.retarget(sessionID: sessionID, accountID: accountID)) ?? false },
            // The app-owned folder the process keeps its credential files in, and only that.
            launchDir: { $0.storeDirectory })
    }

    private func handle(_ body: Data, peerPID: Int32) async -> Data {
        let answer: BackendAccountShimAnswer
        do {
            // TS `readBody` null: not a request this app answers — the real command.
            guard let raw = try? NativeRPCValue.parseJSON(body, maximumBytes: 1024 * 1024) else { return Self.encode(.pass) }
            switch raw["operation"] {
            case .missing:
                answer = try await keychain(raw, peerPID: peerPID)
            case .string("lookup-ack"):
                try acknowledge(raw, peerPID: peerPID)
                answer = BackendAccountShimAnswer(kind: "exit", code: 0, stdout: "", stderr: "")
            case .string("captured"):
                // TS `/keychain/captured`: `ok` / `no`; the shim ignores which.
                answer = BackendAccountShimAnswer(kind: "exit", code: await captured(raw) ? 0 : 1, stdout: "", stderr: "")
            default:
                answer = .pass
            }
        } catch {
            // Never an error trace down a socket a session can read: "not found"
            // is the safe answer for anything that was about a login.
            answer = BackendAccountVaultServer.wire(.exit(BackendAccountVaultServer.notFound))
        }
        return Self.encode(answer)
    }
    private static func encode(_ answer: BackendAccountShimAnswer) -> Data { (try? JSONEncoder().encode(answer)) ?? Data("{}".utf8) }
    private func keychain(_ raw: NativeRPCValue, peerPID: Int32) async throws -> BackendAccountShimAnswer {
        var delivered: [BackendAccountVaultServer.Delivery] = []
        let request = BackendAccountVaultServer.readBody(raw)
        var wire = await BackendAccountVaultServer.answerShim(request, deps: deps, delivered: &delivered)
        if case .steps(let ticket, let steps) = wire {
            wire = .exit(await BackendAccountVaultServer.runSteps(ticket: ticket, steps: steps, deps: deps, user: keychainUser, delivered: &delivered))
        }
        var reply = BackendAccountVaultServer.wire(wire)
        if reply.kind == "exit", reply.code == 0, let request, !delivered.isEmpty {
            reply.lookupReceipts = try issueReceipts(delivered, ticket: request.ticket, peerPID: peerPID)
        }
        return reply
    }
    private func captured(_ raw: NativeRPCValue) async -> Bool {
        guard let elements = raw["argv"].elements, elements.count <= 64, let code = raw["code"].number, code == code.rounded(),
              abs(code) < 1_000_000 else { return false }
        let argv = elements.compactMap(\.string)
        guard argv.count == elements.count else { return false }
        let report = BackendAccountVaultServer.CaptureReport(ticket: raw["ticket"].string ?? "", code: Int(code), argv: argv, stdout: raw["stdout"].string ?? "")
        return await BackendAccountVaultServer.acceptCapture(report, deps: deps)
    }
    /// Native: a receipt per password delivered to the seat's own provider process tree.
    private func issueReceipts(_ delivered: [BackendAccountVaultServer.Delivery], ticket: String, peerPID: Int32) throws -> [String]? {
        guard let token = tickets.canonical(ticket), let seat = tickets.seatOf(token), let sessionID = seat.sessionID,
              let processPID = seat.processPID, Self.isDescendant(peerPID, of: processPID) else { return nil }
        var issued: [String] = []
        for delivery in delivered where BackendAccountProfile.loginSlot(delivery.slot) || delivery.slot == "keychain:Claude Code" {
            receipts = receipts.filter { Date().timeIntervalSince($0.value.created) < 30 }
            guard receipts.count < 512 else { throw BackendAccountFailure("Too many unacknowledged credential lookups are outstanding.") }
            let receipt = UUID().uuidString.lowercased()
            receipts[receipt] = PendingReceipt(ticket: token, sessionID: sessionID, accountID: delivery.account, slot: delivery.slot, created: Date())
            issued.append(receipt)
        }
        return issued.isEmpty ? nil : issued
    }
    private func acknowledge(_ raw: NativeRPCValue, peerPID: Int32) throws {
        guard let token = raw["ticket"].string.flatMap(tickets.canonical), let seat = tickets.seatOf(token), let processPID = seat.processPID,
              Self.isDescendant(peerPID, of: processPID), let values = raw["receipts"].elements, !values.isEmpty, values.count <= 64 else {
            throw BackendAccountFailure("The credential receipt does not belong to this live provider process.")
        }
        var accepted: [(String, PendingReceipt)] = []
        var seen = Set<String>()
        for value in values {
            guard let id = value.string, let receipt = receipts[id], receipt.ticket == token,
                  seen.insert(id).inserted, Date().timeIntervalSince(receipt.created) < 30, receipt.sessionID == seat.sessionID else {
                throw BackendAccountFailure("A credential receipt was absent, expired, or belonged to another session.")
            }
            accepted.append((id, receipt))
        }
        for (id, receipt) in accepted {
            receipts[id] = nil; sequence &+= 1
            let event = BackendAccountCredentialLookup(sessionID: receipt.sessionID, accountID: receipt.accountID, slot: receipt.slot,
                processPID: processPID, sequence: sequence, deliveredAt: Date())
            for listener in lookupListeners.values { listener(event) }
        }
    }
    private static func isDescendant(_ child: Int32, of root: Int32) -> Bool {
        var current = child, seen = Set<Int32>()
        for _ in 0..<64 {
            if current == root { return true }
            guard current > 1, seen.insert(current).inserted else { return false }
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            var info = kinfo_proc(), length = MemoryLayout<kinfo_proc>.size
            let count = u_int(query.count)
            guard sysctl(&query, count, &info, &length, nil, 0) == 0, length > 0 else { return false }
            current = info.kp_eproc.e_ppid
        }
        return false
    }
    public func close() {
        server?.stop(); server = nil; tickets.clear(); receipts.removeAll(); lookupListeners.removeAll(); events.removeAll()
        // TS `removeSecurityShim`: the whole folder, which holds nothing but the shim.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: shimDirectory, isDirectory: true))
    }
}
