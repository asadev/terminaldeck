import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// All key access is injected and occurs only after explicit open/use. No
/// plaintext fallback exists. The app may adapt BackendAccountKeychainCipher
/// with the original brand identity after taking exclusive backend ownership.
public struct BackendBrowserPasswordsCipher: Sendable {
    public let available: @Sendable () throws -> Bool
    public let decrypt: @Sendable (Data) throws -> String
    public let encrypt: @Sendable (String, Bool) throws -> Data
    public init(available: @escaping @Sendable () throws -> Bool,
                decrypt: @escaping @Sendable (Data) throws -> String,
                encrypt: @escaping @Sendable (String, Bool) throws -> Data) {
        self.available = available; self.decrypt = decrypt; self.encrypt = encrypt
    }
    public static func keychain(_ cipher: BackendAccountKeychainCipher,
                                available: @escaping @Sendable () throws -> Bool) -> Self {
        Self(available: available,
            decrypt: { try cipher.decrypt($0) }, encrypt: { try cipher.encrypt($0, existingVault: $1) })
    }
}

public struct BackendBrowserLoginSummary: Sendable, Equatable {
    public let profileID: String
    public let origin: String
    public let username: String
    public let updatedAt: Double
    public var wireValue: NativeRPCValue {
        .object([.init("profileId", .string(profileID)), .init("origin", .string(origin)), .init("username", .string(username)), .init("updatedAt", .number(updatedAt))])
    }
}

public struct BackendBrowserPasswordOutcome: Sendable {
    public let ok: Bool
    public let message: String
    /// Public so the app's native password sheet (NativeCompositionBrowser) can answer.
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
    public var wireValue: NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
}

/// This comes from native WebKit/tab ownership, never a page-supplied URL or
/// raw remote tab identifier. documentID must change on committed navigation.
public struct BackendBrowserPasswordTab: Sendable, Equatable {
    public let tabID: String
    public let profileID: String
    public let committedURL: String
    public let documentID: String
    public let isolated: Bool
    public let agentHolding: Bool
    public let documentFromAgent: Bool
    public let hasSignInForm: Bool
    public init(tabID: String, profileID: String, committedURL: String, documentID: String,
                isolated: Bool, agentHolding: Bool, documentFromAgent: Bool, hasSignInForm: Bool) {
        self.tabID = tabID; self.profileID = profileID; self.committedURL = committedURL; self.documentID = documentID
        self.isolated = isolated; self.agentHolding = agentHolding; self.documentFromAgent = documentFromAgent; self.hasSignInForm = hasSignInForm
    }
    public var origin: String? { BackendBrowserPasswords.origin(committedURL) }
}

public struct BackendBrowserPasswordFill: Sendable, Equatable {
    public let tabID: String
    public let profileID: String
    public let origin: String
    public let documentID: String
    public let username: String
    public var wireValue: NativeRPCValue {
        .object([.init("tabId", .string(tabID)), .init("origin", .string(origin)), .init("usernames", .array([.string(username)]))])
    }
}

public struct BackendBrowserPasswordOffer: Sendable {
    public let id: UUID
    public let tabID: String
    public let login: BackendBrowserLoginSummary
    public var wireValue: NativeRPCValue { login.wireValue }
}

/// The only sinks for cleartext passwords. These callbacks must remain native
/// app-internal; no RPC, logging, MCP structured output or Node bridge.
public struct BackendBrowserPasswordsHost: Sendable {
    public let tab: @Sendable (String) async throws -> BackendBrowserPasswordTab?
    public let fill: @Sendable (BackendBrowserPasswordFill, String, Bool) async throws -> Bool
    public let copy: @Sendable (String) async throws -> Void
    public let reveal: @Sendable (URL) async throws -> Void
    public init(tab: @escaping @Sendable (String) async throws -> BackendBrowserPasswordTab?,
                fill: @escaping @Sendable (BackendBrowserPasswordFill, String, Bool) async throws -> Bool,
                copy: @escaping @Sendable (String) async throws -> Void,
                reveal: @escaping @Sendable (URL) async throws -> Void) {
        self.tab = tab; self.fill = fill; self.copy = copy; self.reveal = reveal
    }
}

/// Compatible encrypted browser-logins.bin with v1 upgrade and v2 integrity
/// verification over ordered, uncleaned entries. Every public result is a
/// summary or boolean. Private entries never cross the native RPC seam.
public actor BackendBrowserPasswords {
    private struct Login: Sendable {
        let summary: BackendBrowserLoginSummary
        let password: String
        var value: NativeRPCValue {
            // Keep source field order: JSON.stringify(entries) is the digest.
            .object([.init("profileId", .string(summary.profileID)), .init("origin", .string(summary.origin)),
                .init("username", .string(summary.username)), .init("password", .string(password)), .init("updatedAt", .number(summary.updatedAt))])
        }
    }
    public enum Fault: String, Sendable { case none, tampered, unreadable }
    public nonisolated let file: URL
    private let cipher: BackendBrowserPasswordsCipher
    private let requireWriter: BackendBrowserProfiles.RequireWriter
    private let host: BackendBrowserPasswordsHost
    private let requireProfile: @Sendable (String) async throws -> Void
    private var opened = false
    private var entries: [Login] = []
    private var fault: Fault = .none
    private var pending: (offer: BackendBrowserPasswordOffer, login: Login)?
    private var forms: [String: BackendBrowserPasswordTab] = [:]
    private var revision: UInt64 = 0
    public init(dataRoot: URL, cipher: BackendBrowserPasswordsCipher, host: BackendBrowserPasswordsHost,
                requireWriter: @escaping BackendBrowserProfiles.RequireWriter,
                requireProfile: @escaping @Sendable (String) async throws -> Void) throws {
        try BackendBrowserProfilesFiles.validateRoot(dataRoot)
        file = dataRoot.standardizedFileURL.appendingPathComponent("browser-logins.bin")
        self.cipher = cipher; self.host = host; self.requireWriter = requireWriter; self.requireProfile = requireProfile
    }
    public func open(upgradeLegacy: Bool = true) throws {
        guard !opened else { return }
        guard let raw = try BackendBrowserProfilesFiles.read(file, maximum: 8 * 1024 * 1024) else { opened = true; return }
        var legacy = false
        do {
            let text = try decryptBlob(raw)
            let value = try NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 8 * 1024 * 1024)
            guard value.fields != nil, (value["version"].number ?? 1) <= 2 else { throw NativeRPCError.malformed("Unsupported saved-login format.") }
            let savedRows = value["entries"].elements ?? []
            let expected = value["digest"].string ?? ""
            if !expected.isEmpty, expected != Self.digest(.array(savedRows)) { fault = .tampered; opened = true; return }
            legacy = expected.isEmpty
            entries = savedRows.compactMap { row in
                guard let origin = Self.origin(row["origin"].string ?? "") else { return nil }
                let password = Self.cleanField(row["password"].string ?? "")
                guard !password.isEmpty else { return nil }
                let profile = row["profileId"].string ?? "default"
                guard BackendBrowserProfiles.validID(profile) else { return nil }
                return Login(summary: .init(profileID: profile, origin: origin, username: Self.cleanField(row["username"].string ?? ""),
                    updatedAt: row["updatedAt"].number ?? 0), password: password)
            }
            opened = true
        } catch {
            entries = []; fault = .unreadable; opened = true
        }
        // An upgrade is an opt-in write, guarded by the same owner as saving.
        // Failure keeps the original bytes and readable entries, with no fake
        // "upgraded" state. The next explicit save can carry them forward.
        if legacy && upgradeLegacy && !entries.isEmpty { _ = try? persist(entries) }
    }
    public func available() throws -> Bool { (try? cipher.available()) == true }
    public func storeState() throws -> NativeRPCValue {
        try requireOpen()
        return .object([.init("available", .bool(try available())), .init("path", .string(file.path)),
            .init("exists", .bool(FileManager.default.fileExists(atPath: file.path))), .init("fault", .string(fault.rawValue)),
            .init("message", .string(fault == .tampered ? Self.tamperedMessage : fault == .unreadable ? Self.unreadableMessage : ""))])
    }
    public func summaries(profileID: String) async throws -> [BackendBrowserLoginSummary] {
        try requireOpen(); try await requireProfile(profileID)
        return entries.filter { $0.summary.profileID == profileID }.map(\.summary).sorted {
            $0.origin == $1.origin ? $0.username.localizedCompare($1.username) == .orderedAscending : $0.origin.localizedCompare($1.origin) == .orderedAscending
        }
    }
    public func forget(profileID: String, origin: String, username: String) async throws -> BackendBrowserPasswordOutcome {
        try requireOpen(); try await requireProfile(profileID)
        return try persist(entries.filter { !($0.summary.profileID == profileID && $0.summary.origin == origin && $0.summary.username == username) })
    }
    public func forgetAll() throws -> BackendBrowserPasswordOutcome {
        try requireOpen(); try requireWriter()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        entries = []; fault = .none; pending = nil; forms = [:]; revision &+= 1
        return .init(ok: true, message: "Cleared.")
    }
    public func reveal() async throws -> Bool {
        try requireOpen()
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        try await host.reveal(file); return true
    }
    /// Native UI only. Channel registration below rejects remote/session/page
    /// callers. MCP deliberately has no copy action.
    public func copy(profileID: String, origin: String, username: String) async throws -> Bool {
        try requireOpen(); try await requireProfile(profileID)
        guard let login = entries.first(where: { $0.summary.profileID == profileID && $0.summary.origin == origin && $0.summary.username == username }) else { return false }
        try await host.copy(login.password); return true
    }
    public func pendingOffer() throws -> BackendBrowserPasswordOffer? { try requireOpen(); return pending?.offer }
    public func answer(keep: Bool, expectedOffer: UUID) throws -> BackendBrowserPasswordOutcome {
        try requireOpen()
        guard let current = pending, current.offer.id == expectedOffer else { return .init(ok: false, message: "The offered login changed. Nothing was saved.") }
        pending = nil
        if !keep { return .init(ok: true, message: "Not saved.") }
        let key = current.login.summary
        let next = entries.filter { !($0.summary.profileID == key.profileID && $0.summary.origin == key.origin && $0.summary.username == key.username) } + [current.login]
        return try persist(next)
    }
    /// Called only by the native isolated-world WKScriptMessageHandler after
    /// top-frame/security-origin verification. No caller-provided origin.
    public func offerFromPage(tabID: String, documentID: String, username: String, password: String) async throws -> BackendBrowserPasswordOffer? {
        try requireOpen()
        guard let tab = try await host.tab(tabID), !tab.isolated, tab.documentID == documentID, let origin = tab.origin else { return nil }
        try await requireProfile(tab.profileID)
        guard let still = try await host.tab(tabID), still.documentID == documentID, still.origin == origin, still.profileID == tab.profileID, !still.isolated else { return nil }
        let cleanPassword = Self.cleanField(password), user = Self.cleanField(username)
        guard !cleanPassword.isEmpty, !entries.contains(where: { $0.summary.profileID == tab.profileID && $0.summary.origin == origin && $0.summary.username == user && $0.password == cleanPassword }) else { return nil }
        let login = Login(summary: .init(profileID: tab.profileID, origin: origin, username: user, updatedAt: Date().timeIntervalSince1970 * 1000), password: cleanPassword)
        let offer = BackendBrowserPasswordOffer(id: UUID(), tabID: tabID, login: login.summary)
        pending = (offer, login); return offer
    }
    public func formAvailable(tabID: String, documentID: String) async throws -> NativeRPCValue? {
        try requireOpen()
        guard let tab = try await host.tab(tabID), !tab.isolated, tab.hasSignInForm, tab.documentID == documentID,
              let origin = tab.origin else { forms[tabID] = nil; return nil }
        try await requireProfile(tab.profileID)
        let ranked = matches(profileID: tab.profileID, origin: origin)
        guard !ranked.isEmpty else { forms[tabID] = nil; return nil }
        forms[tabID] = tab
        let message = Self.autofillMessage(tab)
        var autoFilled = false
        if message.isEmpty, let request = try await prepareFill(tabID: tabID, username: ranked.first?.summary.username) {
            autoFilled = try await fill(request, automatic: true)
        }
        return .object([.init("origin", .string(origin)), .init("usernames", .array(ranked.map { .string($0.summary.username) })),
            .init("message", .string(message)), .init("autoFilled", .bool(autoFilled))])
    }
    public func formOffer(tabID: String) async throws -> NativeRPCValue? {
        try requireOpen()
        guard let tab = try await currentForm(tabID), let origin = tab.origin else { return nil }
        return .object([.init("origin", .string(origin)), .init("usernames", .array(matches(profileID: tab.profileID, origin: origin).map { .string($0.summary.username) }))])
    }
    public func prepareFill(tabID: String, username: String? = nil) async throws -> BackendBrowserPasswordFill? {
        try requireOpen()
        guard let tab = try await currentForm(tabID), let origin = tab.origin else { return nil }
        let candidates = matches(profileID: tab.profileID, origin: origin)
        let chosen = username == nil ? candidates.first : candidates.first(where: { $0.summary.username == username })
        guard let chosen else { return nil }
        return .init(tabID: tabID, profileID: tab.profileID, origin: origin, documentID: tab.documentID, username: chosen.summary.username)
    }
    /// Tool/UI gate authorizes an exact prepareFill result, then this operation
    /// rechecks the current document and invokes the native fill sink.
    public func fill(_ request: BackendBrowserPasswordFill, automatic: Bool = false) async throws -> Bool {
        try requireOpen()
        let currentRevision = revision
        guard let tab = try await currentForm(request.tabID), tab.profileID == request.profileID, tab.origin == request.origin,
              tab.documentID == request.documentID, !automatic || Self.autofillMessage(tab).isEmpty,
              let login = matches(profileID: request.profileID, origin: request.origin).first(where: { $0.summary.username == request.username }) else { return false }
        try Task.checkCancellation()
        guard revision == currentRevision else { return false }
        return try await host.fill(request, login.password, !automatic)
    }
    public func documentChanged(tabID: String) { forms[tabID] = nil }
    public func tabClosed(tabID: String) { forms[tabID] = nil; if pending?.offer.tabID == tabID { pending = nil } }
    public func close() { entries = []; pending = nil; forms = [:]; opened = false; fault = .none; revision &+= 1 }
    private func currentForm(_ tabID: String) async throws -> BackendBrowserPasswordTab? {
        guard let announced = forms[tabID], let live = try await host.tab(tabID), !live.isolated, live.hasSignInForm,
              live.documentID == announced.documentID, live.profileID == announced.profileID, live.origin == announced.origin else { forms[tabID] = nil; return nil }
        try await requireProfile(live.profileID)
        return live
    }
    private func matches(profileID: String, origin: String) -> [Login] {
        entries.filter { $0.summary.profileID == profileID && $0.summary.origin == origin }.sorted { $0.summary.updatedAt > $1.summary.updatedAt }
    }
    private func requireOpen() throws {
        guard opened else { throw NativeRPCError(code: "password-store-not-open", message: "Open the saved-login store explicitly before using it.") }
    }
    private func persist(_ next: [Login]) throws -> BackendBrowserPasswordOutcome {
        try requireWriter()
        guard fault != .tampered else { return .init(ok: false, message: Self.tamperedMessage) }
        guard (try? cipher.available()) == true else { return .init(ok: false, message: Self.noSecureStoreMessage) }
        let rows = NativeRPCValue.array(next.map(\.value))
        let value = NativeRPCValue.object([.init("version", .number(2)), .init("entries", rows), .init("digest", .string(Self.digest(rows)))])
        // Encrypt before opening a temporary file, so a denied Keychain read
        // cannot replace existing ciphertext with an empty file.
        let blob = try cipher.encrypt(value.compact, FileManager.default.fileExists(atPath: file.path))
        let data = Data(blob.base64EncodedString().utf8)
        guard !blob.isEmpty, data.count <= 8 * 1024 * 1024 else { throw NativeRPCError(code: "password-store-size", message: "The encrypted saved-login store exceeds its size limit.") }
        try BackendBrowserProfilesFiles.write(data, to: file, secret: true)
        entries = next; fault = .none; revision &+= 1
        return .init(ok: true, message: "Saved.")
    }
    private func decryptBlob(_ raw: Data) throws -> String {
        if let text = String(data: raw, encoding: .utf8), text.range(of: #"^[A-Za-z0-9+/\r\n]+={0,2}\s*$"#, options: .regularExpression) != nil,
           let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters), let result = try? cipher.decrypt(decoded) { return result }
        return try cipher.decrypt(raw)
    }
    private static func digest(_ rows: NativeRPCValue) -> String { SHA256.hash(data: Data(rows.compact.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func cleanField(_ value: String) -> String {
        String(value.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression).prefix(512))
    }
    public static func origin(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        var origin = URLComponents(); origin.scheme = scheme; origin.host = host
        if let port = parts.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) { origin.port = port }
        return origin.string
    }
    private static func autofillMessage(_ tab: BackendBrowserPasswordTab) -> String {
        if tab.isolated { return "This tab is Isolated, so it has no profile and no saved logins. Open the site in a normal tab to use one." }
        if tab.agentHolding || tab.documentFromAgent { return "An agent opened this page, so the saved login was not filled in automatically. Fill it yourself if you meant to sign in here." }
        return ""
    }
    public static let noSecureStoreMessage = "This machine has no secure store available, so logins cannot be saved here. Unlock its Keychain and try again."
    public static let tamperedMessage = "The saved-login file on this machine did not verify. Nothing has been used from it and nothing has been deleted. Look at the file, or forget every saved password and start again."
    public static let unreadableMessage = "There is a saved-login file here that this app cannot open. Its original encryption key may be missing or locked. The file was kept unchanged. Saving a new password will replace it."
}
