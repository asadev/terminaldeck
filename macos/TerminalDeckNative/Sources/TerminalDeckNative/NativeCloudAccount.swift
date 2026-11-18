import AppKit
import ImageIO
import Network
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor @Observable
final class NativeCloudAccount {
    static let shared = NativeCloudAccount()
    /// 13 Nov: the sign-in failed silently on the owner's Macs. Every step that can stop "Sign in" before the browser
    /// opens writes ONE plain line to the app's engine.log (never a token, code, key or e-mail) and names itself on the page.
    struct SignInFailure: Equatable { let step: String; let kind: String }
    /// The app's engine.log; a test process has no app runtime to write to (tests replace this to read the lines).
    static var log: @MainActor (String) -> Void = { if !NativeCloudApplication.isTestProcess { NativeCompositionRoot.note($0) } }
    /// Why the last armed activation built no account; read once by the press that asked for it.
    private static var activationFailure: SignInFailure?
    static func recordActivationFailure(_ failure: SignInFailure) { activationFailure = failure }
    /// The error's kind only: a case name or an OS status, never its payload beyond 160 characters.
    nonisolated static func kind(_ error: any Error) -> String {
        if let failure = error as? CloudFailure, case .remote(let detail) = failure { return "remote " + detail.code }
        if let rpc = error as? NativeRPCError { return String((rpc.code + ": " + rpc.message).prefix(160)) }
        return String(String(describing: error).prefix(160))
    }
    nonisolated static func words(step: String) -> String {
        switch step {
        case "account": return "this copy of Terminal Deck could not set up its Cloud account"
        case "keychain": return "this Mac could not read its saved sign-in safely (Keychain)"
        case "saved account": return "an account is already saved on this Mac; sign out first"
        default: return "the sign-in address could not be made"
        }
    }
    private func failed(_ failure: SignInFailure) {
        Self.log("cloud sign-in: \(failure.step) failed: \(failure.kind)")
        notice = "Could not open sign-in: " + Self.words(step: failure.step) + ". Try again."
    }
    private(set) var snapshot: CloudAccountSnapshot = .signedOut
    /// Memory seat (one rule, phase 2 review point 6): how many account statuses were published; the newest wins.
    @ObservationIgnored private(set) var oneRuleMacsGeneration: UInt64 = 0
    private(set) var busy = false
    private(set) var notice: String?
    /// Status-line lane (14 Nov): the main window's one Cloud line. `online` = the network path has internet;
    /// `syncingNow` = a "Sync now" pass runs (the line shows it; a second press joins it); `storageLeft` = the account's
    /// room left as the service last said it.
    private(set) var online = true
    private(set) var syncingNow = false
    private(set) var storageLeft: Int64?
    /// The status line is on screen: this Mac's own progress is read again while it is (local only, no request).
    /// Review fix 4: one count per window that shows the line; closing one window never stops the others' re-reads.
    @ObservationIgnored private(set) var lineViews = 0
    var lineOpen: Bool { lineViews > 0 }
    func lineShown(_ shown: Bool) { lineViews = max(0, lineViews + (shown ? 1 : -1)) }
    /// Review fix 2: the line says "Everything is on your other devices" (its queue is then re-read every 10 seconds).
    @ObservationIgnored private(set) var lineLevel = false
    func lineSays(level: Bool) { lineLevel = level }
    func networkChanged(_ up: Bool) { if online != up { online = up } }
    /// The status line's "Sync now": one full pass (fetch what the Cloud holds, then send what this Mac holds), the
    /// same as Settings → Cloud's. Pressed again while it runs, nothing new starts (here, and in the account's gate).
    func syncNow() {
        guard snapshot.subscription.offers(.syncSwitches) else { return }
        guard let service, !syncingNow, snapshot.phase == .signedIn else { return }
        syncingNow = true
        Task {
            defer { syncingNow = false }
            do { try await service.sync(action: "now") }
            catch is CancellationError {}
            catch {
                CloudSyncDiagnostics.shared.report("Sync now", error)
                if !CloudSyncDiagnostics.shared.lastRefusalWasBusy {
                    notice = "Could not finish that change. " + (CloudSyncDiagnostics.shared.lastReason ?? CloudSyncDiagnostics.plainReason(error)) + " Your local work is kept."
                }
            }
            NativeCloudSecrets.shared.syncNow()
        }
    }
    /// Sync trust core review, hand-back 4: true from the moment the person starts a sign-in on this Mac until they
    /// have answered the new-Mac sheet (trusted devices, or "Not now"). While it is true this Mac's own memory is not
    /// set up: no baseline is cut or sent, so the first thing a new Mac does is never an upload nobody expected.
    private(set) var newMacPending = false
    /// Settings → Profile (owner, 14 Nov): who is signed in, as this Mac's saved sign-in says it (name, e-mail and the
    /// way they signed in). Read when the Profile page opens; nil while signed out or before that read.
    private(set) var signedInUser: CloudUserIdentity?
    /// The person's profile as the account service's profile API answers it (`GET /profile/v1/me`, read only, with this
    /// Mac's own sign-in), plus the ways the live site can add now. nil until read, or when it could not be read: the
    /// page then shows what the saved sign-in knows, never an error.
    struct AccountProfile: Equatable, Sendable {
        struct Way: Equatable, Sendable {
            let provider: String; let providerName: String; let account: String?
            /// The service's handle for removing this way (`DELETE /me/ways/<id>`); never shown. nil = it gave none.
            var id: String? = nil
            /// The service says this way may be removed now (never the last one); nil = it did not say.
            var canRemove: Bool? = nil
        }
        var name: String?
        var username: String?
        /// The service says the username may be changed now (not while it is in the address of his Store listings).
        var usernameCanChange = true
        var email: String?
        var picture: URL?
        var ways: [Way]
        /// Provider ids ("github", "google", "apple") the site's "Add another way to sign in" offers now.
        var addable: [String] = []
        /// "uploaded" (he chose it: "Remove picture" is offered), "github" / "google" (the sign-in's own), or nil.
        var pictureSource: String? = nil
    }
    private(set) var accountProfile: AccountProfile?
    nonisolated static let profileURL = URL(string: "https://api.terminaldeck.dev/profile/v1/me")!
    nonisolated static let authSettingsURL = URL(string: "https://api.terminaldeck.dev/auth/v1/settings")!
    /// The ways the site offers (its `_providers.js`): only these, and only while the sign-in service has them on.
    nonisolated static let knownWays = ["github", "google", "apple"]
    nonisolated static func parseProfile(_ data: Data) -> AccountProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let ways = (object["waysToSignIn"] as? [[String: Any]] ?? []).compactMap { way -> AccountProfile.Way? in
            guard let provider = (way["provider"] as? String)?.lowercased(), !provider.isEmpty else { return nil }
            let id = (way["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(provider: provider, providerName: way["providerName"] as? String ?? "", account: way["account"] as? String,
                         id: id?.isEmpty == false ? id : nil, canRemove: way["canRemove"] as? Bool)
        }
        let picture = text("picture").flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "api.terminaldeck.dev" ? $0 : nil }
        var profile = AccountProfile(name: text("name"), username: text("username"), email: text("email"), picture: picture, ways: ways,
                                     pictureSource: picture == nil ? nil : text("pictureSource")?.lowercased())
        profile.usernameCanChange = object["usernameCanChange"] as? Bool ?? true
        return profile
    }
    /// From the sign-in service's settings (`external.<provider> == true`), the known ways switched on.
    nonisolated static func switchedOnWays(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let external = object["external"] as? [String: Any] else { return [] }
        return knownWays.filter { external[$0] as? Bool == true }
    }
    /// Profile edit in place (15 Nov): his other devices read the profile again when the app comes to the front (at
    /// most once a minute), on each account status and every 5 minutes on the quiet timer, so a name or picture changed
    /// elsewhere shows here without opening Profile.
    func refreshProfile(minimumGap: UInt64) {
        guard service != nil else { return }
        guard lastProfileRead == 0 || monotonic() &- lastProfileRead >= minimumGap else { return }
        refreshProfile()
    }
    nonisolated static let profileQuietGap: UInt64 = 300_000_000_000
    func refreshProfile() {
        guard let service else { return } // signing out (detach) clears it
        lastProfileRead = monotonic()
        let edits = profileEdits
        Task {
            signedInUser = (try? await service.identity.existing())?.user
            guard let session = try? await service.identity.credentials() else { return }
            var request = URLRequest(url: Self.profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, var profile = Self.parseProfile(data) else { return }
            var settings = URLRequest(url: Self.authSettingsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            if let key = Bundle.main.object(forInfoDictionaryKey: "TDCloudStorePublishableKey") as? String, !key.isEmpty {
                settings.setValue(key, forHTTPHeaderField: "apikey")
            }
            if let (answer, reply) = try? await URLSession.shared.data(for: settings), (reply as? HTTPURLResponse)?.statusCode == 200 {
                profile.addable = Self.switchedOnWays(answer)
            }
            // The answer belongs to whoever is still signed in here, and never undoes an edit made while it travelled.
            guard self.service === service, edits == profileEdits, !profileSaving else { return }
            accountProfile = profile
            if localPicture?.url != nil, localPicture?.url != profile.picture { localPicture = nil }
        }
    }

    // MARK: Profile edit in place (owner's list since 13 Nov; 15 Nov)
    // His name and picture change right on Settings → Profile and go to the ACCOUNT (`PATCH /profile/v1/me`,
    // `PUT` / `DELETE /profile/v1/me/picture`, the gateway's existing calls with this Mac's own sign-in). Only these
    // three; username, bio, links and country stay on the website. No tool changes them (only he does, on the page).

    /// The one plain line under his name after a save that did not go through; cleared by the next edit.
    private(set) var profileProblem: String?
    /// A save is travelling: a profile read that lands meanwhile is not applied (it would bring the old name back).
    private(set) var profileSaving = false
    /// The picture he just chose, drawn from this Mac's own copy while it goes up and until the new address loads
    /// (`url` nil = still going up), so the page never flashes the initials.
    struct LocalPicture: Equatable { let image: NSImage; var url: URL? }
    private(set) var localPicture: LocalPicture?
    @ObservationIgnored private var profileEdits: UInt64 = 0
    @ObservationIgnored private var lastProfileRead: UInt64 = 0
    nonisolated static let pictureURL = URL(string: "https://api.terminaldeck.dev/profile/v1/me/picture")!
    nonisolated static let nameUnsaved = "Could not save your name. Check your connection."
    nonisolated static let pictureUnsaved = "Could not save your picture. Check your connection."
    nonisolated static let pictureUnremoved = "Could not remove your picture. Check your connection."
    nonisolated static let pictureUnreadable = "That picture couldn't be read. Try a PNG or JPEG."
    /// The service's own limit (60 characters); the field never takes more.
    nonisolated static let nameLimit = 60
    /// Sends one profile call; nil when the account could not be reached. Fixtures replace it.
    @ObservationIgnored var profileSend: @MainActor (URLRequest) async -> (Data, Int)? = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    /// This Mac's access token (`true` = the service refused the last one: refresh it now). Fixtures replace it.
    @ObservationIgnored var profileToken: (@MainActor (Bool) async -> String?)?
    private enum ProfileAnswer { case profile(AccountProfile), refused(String), unreachable }
    /// The service's plain sentence from an error answer (`{ code, message }`), shown as it is.
    nonisolated static func profileMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        return String(message.prefix(200))
    }
    private func token(force: Bool) async -> String? {
        if let profileToken { return await profileToken(force) }
        guard let service else { return nil }
        return try? await service.identity.credentials(force: force).accessToken
    }
    private func profileCall(_ method: String, _ url: URL, body: Data?, type: String?) async -> ProfileAnswer {
        for force in [false, true] {
            guard let token = await token(force: force) else { return .unreachable }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: body == nil ? 15 : 30)
            request.httpMethod = method
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
            guard let (data, status) = await profileSend(request) else { return .unreachable }
            if status == 200, let profile = Self.parseProfile(data) { return .profile(profile) }
            if status == 401, !force { continue } // the token is refreshed once, then the service's sentence stands
            if let message = Self.profileMessage(data) { return .refused(message) }
            return .unreachable
        }
        return .unreachable
    }
    /// Applies the service's answer, keeping what only this Mac knows (the ways the site can add).
    private func took(_ answer: AccountProfile, over before: AccountProfile) {
        var profile = answer
        profile.addable = before.addable
        accountProfile = profile
    }

    /// Return or clicking away on his name. The page shows the new name at once (here and in the side panel); when the
    /// account cannot be reached the old one comes back with one plain line. Empty = the sign-in's own name.
    @discardableResult
    func saveProfileName(_ typed: String) async -> Bool {
        guard let before = accountProfile, !profileSaving else { return false }
        let name = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        guard name != (before.name ?? "") else { return true }
        let owner = service
        profileEdits &+= 1; profileProblem = nil; profileSaving = true
        defer { profileSaving = false }
        var shown = before
        shown.name = name.isEmpty ? nil : name
        accountProfile = shown
        let body = try? JSONSerialization.data(withJSONObject: ["name": name])
        let answer = await profileCall("PATCH", Self.profileURL, body: body, type: "application/json")
        guard service === owner else { return false }
        switch answer {
        case .profile(let profile): took(profile, over: before); return true
        case .refused(let message): accountProfile = before; profileProblem = message
        case .unreachable: accountProfile = before; profileProblem = Self.nameUnsaved
        }
        return false
    }

    // MARK: Username and ways to sign in, in place (owner, 18 Nov, items 26 and 28: "Just give everything here and
    // editable directly from here, not from website"; "Sign-ins should be able to control here, not just look at them")
    // The gateway's existing calls with this Mac's own sign-in: `PATCH /profile/v1/me` with `username`,
    // `DELETE /profile/v1/me/ways/<id>`. Both answer the new profile; a refusal is the service's own sentence.

    nonisolated static let usernameLimit = 40
    nonisolated static let usernameUnsaved = "Could not save your username. Check your connection."
    nonisolated static let wayUnremoved = "Could not disconnect it. Check your connection."
    nonisolated static func wayURL(_ id: String) -> URL {
        profileURL.appendingPathComponent("ways").appendingPathComponent(id)
    }
    /// What goes to the account as a username: no "@" in front, no spaces around, at most 40 characters (the service
    /// lower-cases and checks the rest and answers its own sentence).
    nonisolated static func cleanedUsername(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("@") { text.removeFirst() }
        return String(text.prefix(usernameLimit))
    }
    /// Enter or clicking away on his username. Answers nil when the account took it (or nothing changed), else the ONE
    /// sentence to show: the service's own ("That username is taken.") or the no-connection line. The page keeps the
    /// old username until the account answers (the service cleans what was typed, so it is never shown ahead).
    func saveProfileUsername(_ typed: String) async -> String? {
        guard let before = accountProfile, !profileSaving else { return Self.usernameUnsaved }
        let username = Self.cleanedUsername(typed)
        guard username != (before.username ?? "") else { return nil }
        let owner = service
        profileEdits &+= 1; profileProblem = nil; profileSaving = true
        defer { profileSaving = false }
        let body = try? JSONSerialization.data(withJSONObject: ["username": username])
        let answer = await profileCall("PATCH", Self.profileURL, body: body, type: "application/json")
        guard service === owner else { return Self.usernameUnsaved }
        switch answer {
        case .profile(let profile): took(profile, over: before); return nil
        case .refused(let message): return message
        case .unreachable: return Self.usernameUnsaved
        }
    }
    /// "Disconnect" on a way to sign in (after its 5-second Undo): the account removes it. nil = removed, else the one
    /// sentence to show (the service refuses the last way: "This is your only way to sign in …").
    func removeSignInWay(_ id: String) async -> String? {
        guard let before = accountProfile, !profileSaving, !id.isEmpty else { return Self.wayUnremoved }
        let owner = service
        profileEdits &+= 1; profileSaving = true
        defer { profileSaving = false }
        let answer = await profileCall("DELETE", Self.wayURL(id), body: nil, type: nil)
        guard service === owner else { return Self.wayUnremoved }
        switch answer {
        case .profile(let profile): took(profile, over: before); return nil
        case .refused(let message): return message
        case .unreachable: return Self.wayUnremoved
        }
    }

    /// A picture he chose (file) or dropped (file or picture data): cropped to the middle square, drawn upright at
    /// 512 x 512 and saved as a JPEG under 500 KB (the service takes 512 KB at most), then sent to the account.
    @discardableResult
    func saveProfilePicture(_ data: Data) async -> Bool {
        guard let before = accountProfile, !profileSaving else { return false }
        profileEdits &+= 1; profileProblem = nil; profileSaving = true
        defer { profileSaving = false }
        let owner = service
        guard data.count <= Self.pictureSourceLimit,
              let small = await Task.detached(priority: .userInitiated, operation: { Self.profilePictureBytes(data) }).value,
              let image = NSImage(data: small) else { profileProblem = Self.pictureUnreadable; return false }
        localPicture = LocalPicture(image: image, url: nil)
        let answer = await profileCall("PUT", Self.pictureURL, body: small, type: "image/jpeg")
        guard service === owner else { return false }
        switch answer {
        case .profile(let profile):
            took(profile, over: before)
            localPicture = profile.picture.map { LocalPicture(image: image, url: $0) }
            return true
        case .refused(let message): localPicture = nil; profileProblem = message
        case .unreachable: localPicture = nil; profileProblem = Self.pictureUnsaved
        }
        return false
    }

    /// "Remove picture": back to the sign-in's own picture, or his initials.
    @discardableResult
    func removeProfilePicture() async -> Bool {
        guard let before = accountProfile, !profileSaving else { return false }
        profileEdits &+= 1; profileProblem = nil; profileSaving = true
        defer { profileSaving = false }
        let owner = service
        let answer = await profileCall("DELETE", Self.pictureURL, body: nil, type: nil)
        guard service === owner else { return false }
        switch answer {
        case .profile(let profile): localPicture = nil; took(profile, over: before); return true
        case .refused(let message): profileProblem = message
        case .unreachable: profileProblem = Self.pictureUnremoved
        }
        return false
    }

    /// A file bigger than this is not opened at all (a phone photo is 2-12 MB).
    nonisolated static let pictureSourceLimit = 64 * 1024 * 1024
    nonisolated static let pictureSide = 512
    nonisolated static let pictureMaxBytes = 500_000
    /// Any picture macOS can read → the middle square, upright (the file's orientation applied), 512 x 512 on white,
    /// JPEG at quality 0.85 (then 0.7, 0.5 if it is still over 500 KB). nil when it cannot be read.
    nonisolated static func profilePictureBytes(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width >= 1, height >= 1 else { return nil }
        let side = Double(pictureSide)
        let long = max(width, height), short = min(width, height)
        // Large enough that the short side is still 512 after the crop; never larger than the file, never past 8192.
        let longest = min(long, 8192, max(side, (side * long / short).rounded(.up)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(longest)]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(upright.width, upright.height)
        guard edge > 0, let square = upright.cropping(to: CGRect(x: (upright.width - edge) / 2, y: (upright.height - edge) / 2,
                                                                 width: edge, height: edge)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pictureSide, height: pictureSide, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: pictureSide, height: pictureSide)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(canvas)
        context.interpolationQuality = .high
        context.draw(square, in: canvas)
        guard let flat = context.makeImage() else { return nil }
        for quality in [0.85, 0.7, 0.5] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if out.length <= pictureMaxBytes { return out as Data }
        }
        return nil
    }
    /// §10 / N6: this identity's choice to include this Mac's memory; nil until asked.
    var memoryIncluded: Bool?
    @ObservationIgnored private var service: BackendCloudAccount?
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var wake: NSObjectProtocol?
    @ObservationIgnored private var lastRenewRequest: UInt64 = 0
    @ObservationIgnored private var path: NWPathMonitor?
    /// Device list watch (two-Mac proof, 13 Nov): a joined or removed device shows within a minute without a restart.
    @ObservationIgnored private var deviceWatch: Task<Void, Never>?
    @ObservationIgnored private var progressWatch: Task<Void, Never>?
    @ObservationIgnored private var becameActive: NSObjectProtocol?
    @ObservationIgnored private var lastDeviceCheck: UInt64 = 0
    /// The Cloud page is on screen (its own appear and disappear).
    @ObservationIgnored private(set) var pageOpen = false
    /// A `terminaldeck://cloud/signin` link from the website starts at most one sign-in every 30 seconds.
    @ObservationIgnored private var quietUntil: UInt64 = 0
    /// "How this Mac trusts your other devices" (owner, 13 Nov). The composition sets it from this Mac's setting
    /// (default "Automatically, with my account"); a model nobody set stays on the stricter "ask".
    private(set) var trustMode: BackendCloudTrustMode = .ask
    @ObservationIgnored private var saveTrustMode: (@MainActor (BackendCloudTrustMode) -> Void)?
    /// Automatic trust: "joined your account" notices the person has already seen and answered in this run.
    private(set) var dismissedJoins: Set<String> = []
    /// How long a "joined your account" notice stays on the page (this Mac's clock).
    nonisolated static let joinedNoticeDays: Int64 = 7
    @ObservationIgnored var monotonic: @MainActor () -> UInt64 = { BackendCloudAccount.monotonicNow() }
    /// The armed link belongs to a dormant account (signed in, Cloud not allowed): a link only re-checks, quietly (N3).
    private var armedDormant = false
    /// The Cloud page's own "Sign in" is between the press and the browser opening.
    private(set) var pressing = false
    /// Native questions; fixtures replace them so no modal sheet can block a test.
    @ObservationIgnored var asker: @MainActor (String, String, String) async -> Bool = { await NativeCloudAccount.ask($0, $1, yes: $2, no: NativeCloudAccount.refusal(forYes: $2)) }
    @ObservationIgnored var informer: @MainActor (String, String) -> Void = { NativeCloudAccount.inform($0, $1) }
    /// What a Sign in press starts once the account exists; fixtures record it instead of opening a browser.
    @ObservationIgnored var starter: (@MainActor () async -> Void)?
    @ObservationIgnored private var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Dormant data folders hold only this closure: no service, observer, task, tool, file or request exists until the person opens the sign-in link.
    @ObservationIgnored private var activation: (@MainActor () async -> BackendCloudAccount?)?
    var visible: Bool {
        // Lazy re-check by the reader (N2): at most one request a minute from here; the account decides if one is due.
        // Only an open Cloud page re-checks: the always-shown Sign in page (signed out, signing in, dormant) sends nothing.
        let now = monotonic()
        if let service, snapshot.visible(at: 0), now &- lastRenewRequest > 60_000_000_000 {
            lastRenewRequest = now
            Task { await service.renewIfDue() }
        }
        return snapshot.subscription.offers(.settingsCloud, existing: snapshot.visible(at: 0))
    }
    init() {}
    func arm(_ activate: @escaping @MainActor () async -> BackendCloudAccount?, dormant: Bool = false) { activation = activate; armedDormant = dormant }
    func detach() {
        activation = nil; armedDormant = false
        NativeCloudTrustSheets.shared.closeAll()
        newMacPending = false
        // What other lanes reported for the summary belongs to the identity that is going away.
        NativeCloudFeatureParts.shared.clear()
        observing?.cancel(); service = nil; snapshot = .signedOut; dismissedJoins = []; signedInUser = nil; accountProfile = nil
        profileEdits &+= 1; lastProfileRead = 0; localPicture = nil; profileProblem = nil
        storageLeft = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }; wake = nil
        path?.cancel(); path = nil
        stopDeviceWatch()
        NativeCloudDisplayGate.shared.subscription(.init())
        NativeCloudDisplayGate.shared.set(false)
    }
    /// How often the device list is asked while signed in: about once a minute with the Cloud page open, every five
    /// minutes otherwise.
    nonisolated static func deviceCheckInterval(pageOpen: Bool) -> UInt64 { (pageOpen ? 60 : 300) * 1_000_000_000 }
    /// The watch's tick (every 15 seconds, no request of its own) asks only when signed in and the interval is over.
    nonisolated static func deviceCheckDue(phase: CloudAccountSnapshot.Phase, pageOpen: Bool, sinceLast: UInt64) -> Bool {
        (phase == .signedIn || phase == .paused) && sinceLast >= deviceCheckInterval(pageOpen: pageOpen)
    }
    /// Page-names 3 (real check 4: Settings → Cloud opened with "5 changes … still going up" while nothing waited): the
    /// snapshot's queue, first-copy and feed numbers are only re-read while the page is open, so on opening they are
    /// from an earlier read. false from the page's opening until its first read of this Mac's progress; the page then
    /// says "Checking…" with no number. At most about 2 seconds.
    private(set) var progressRead = true
    @ObservationIgnored private var progressReadTask: Task<Void, Never>?
    /// The Cloud page appeared or went away.
    func pageShown(_ open: Bool) {
        let opening = open && !pageOpen
        pageOpen = open
        guard opening else {
            if !open { progressReadTask?.cancel(); progressReadTask = nil; progressRead = true }
            return
        }
        guard let service, snapshot.phase == .signedIn || snapshot.phase == .paused else { progressRead = true; return }
        progressRead = false
        progressReadTask?.cancel()
        progressReadTask = Task { [weak self] in
            // One read now. When it cannot run (a full status read is under way, and that publishes by itself), the
            // page waits at most 2 seconds before showing the numbers it has.
            if !(await service.refreshLocalProgress()) { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled, let self else { return }
            self.progressRead = true
        }
    }
    /// Asks the account whether its device list changed, at most once per `minimumGap`. Never while signed out.
    func checkDevices(minimumGap: UInt64) {
        guard snapshot.subscription.offers(.devices) else { return }
        guard let service, snapshot.phase == .signedIn || snapshot.phase == .paused else { return }
        let now = monotonic()
        guard lastDeviceCheck == 0 || now &- lastDeviceCheck >= minimumGap else { return }
        lastDeviceCheck = now
        Task { _ = try? await service.refreshDevicesIfChanged() }
    }
    /// The service's `devices` event (it arrives on the sync core's socket): the list is asked at once.
    nonisolated static func devicesEvent() { Task { @MainActor in NativeCloudAccount.shared.checkDevices(minimumGap: 5_000_000_000) } }
    private func startDeviceWatch() {
        stopDeviceWatch()
        lastDeviceCheck = monotonic()
        deviceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                if let service, snapshot.phase != .signedOut, snapshot.phase != .signingIn {
                    await service.refreshSubscriptionIfDue()
                }
                if Self.deviceCheckDue(phase: snapshot.phase, pageOpen: pageOpen, sinceLast: monotonic() &- lastDeviceCheck) {
                    checkDevices(minimumGap: 0)
                }
                if snapshot.phase == .signedIn || snapshot.phase == .paused { refreshProfile(minimumGap: Self.profileQuietGap) }
            }
        }
        // Proof 3 (13 Nov): with the Cloud page open, this Mac's own progress (the first copy, what is still going up,
        // what is still to fetch) is read again every two seconds while something moves, every ten otherwise. Local
        // only: no request to the service.
        progressWatch = Task { [weak self] in
            var last: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                let now = monotonic()
                guard Self.progressCheckDue(snapshot: snapshot, pageOpen: pageOpen, lineShown: lineOpen, lineLevel: lineLevel, sinceLast: now &- last), let service else { continue }
                last = now
                await service.refreshLocalProgress()
            }
        }
        // Owner, 13 Nov (two-Mac proof): bringing the app to the front also asks, at most once in 30 seconds.
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                NativeCloudAccount.shared.checkDevices(minimumGap: 30_000_000_000)
                NativeCloudAccount.shared.refreshProfile(minimumGap: 60_000_000_000)
            }
        }
    }
    /// Proof 3: the page's own progress is read again only while the page is open: every 2 seconds while the first copy
    /// is prepared or sent, something is still going up or still to fetch; every 10 seconds otherwise.
    /// Status-line lane: the always-shown line counts too, every 2 seconds while something moves and every 30 seconds
    /// otherwise (10 with the page open). Local reads of this Mac's own queue only: no request, no Cloud row.
    /// Review fix 2: the sync core has no notice when something is queued, so while the line says "Everything is…" it
    /// is re-read every 10 seconds (a saved note shows as "Sending…" within 10 seconds, never 30).
    nonisolated static func progressCheckDue(snapshot: CloudAccountSnapshot, pageOpen: Bool, lineShown: Bool = false, lineLevel: Bool = false,
                                             sinceLast: UInt64) -> Bool {
        guard pageOpen || lineShown, snapshot.phase == .signedIn || snapshot.phase == .paused else { return false }
        let moving = snapshot.baseline != nil || snapshot.waitingRecords > 0 || snapshot.catchingUp == true || snapshot.blockedRecords > 0
        let quiet: UInt64 = pageOpen || (lineShown && lineLevel) ? 10 : 30
        return sinceLast >= (moving ? 2 : quiet) * 1_000_000_000 - 100_000_000
    }
    private func stopDeviceWatch() {
        progressWatch?.cancel(); progressWatch = nil
        deviceWatch?.cancel(); deviceWatch = nil
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }; becameActive = nil
    }
    func reportFailure() { notice = "Could not read Cloud status. Try again." }
    /// Design B4: "Signed out from <device> on <date>. Everything on this Mac is kept; ..." on Profile until he signs in.
    func signedOutElsewhere(_ line: String) { notice = line }
    func attach(_ service: BackendCloudAccount, openURL: (@MainActor (URL) -> Void)? = nil) {
        observing?.cancel()
        self.service = service
        // Security review S8: from here on a trust or approval sheet can exist, so this process holds the name of
        // the remote-input record (one written by the Mac reach helper is then kept after the helper exits).
        BackendRemoteInputMark.keepRecord()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        // Spec §10: the full status read runs at sign-in, wake and token refresh. Since the two-Mac proof (13 Nov) the
        // device list alone is also asked on a quiet timer, on the app becoming active and on the `devices` event.
        startDeviceWatch()
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { try? await service.resume() }
        }
        // N2: when the network path comes back, a failed check is retried at once instead of waiting for back-off.
        path?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { update in
            let up = update.status == .satisfied
            if up { Task { await service.networkReturned() } }
            // Status-line lane: "Waiting for the internet" while the path has none.
            Task { @MainActor in NativeCloudAccount.shared.networkChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "cloud-network-path"))
        path = monitor
        if let openURL { self.openURL = openURL }
        observing = Task { [weak self] in
            for await value in await service.events() {
                guard !Task.isCancelled, let self else { return }
                snapshot = value
                // Status-line lane: the account's room left, from the same status read.
                let left = await service.storageLeft()
                if storageLeft != left { storageLeft = left }
                // Memory seat (one rule, phase 2): removals travel only while every Mac of the account says it understands
                // them; the account's Macs come from this device list (phones and browsers never count).
                // Phase 2 review, point 6: each status is numbered here, in the order it was published; the store keeps
                // only the newest number, so a list that lands late never replaces a newer one.
                oneRuleMacsGeneration &+= 1
                if DeckMemoryCenter.shared.isReady, let store = DeckMemoryCenter.shared.store as? DeckMemoryStore {
                    let macs = DeckMemoryStore.oneRuleAccountMacs(value), generation = oneRuleMacsGeneration
                    let devices = value.devices
                    Task {
                        await store.cloudOneRuleSetAccountMacs(macs, generation: generation)
                        try? await store.cloudDeleteSetDevices(devices)
                    }
                }
                // Page-names 3: a published snapshot carries a current read of this Mac's progress.
                if !progressRead { progressRead = true }
                NativeCloudDisplayGate.shared.subscription(value.subscription)
                NativeCloudDisplayGate.shared.set(snapshot.visible(at: 0))
                // R1: a trust sheet closes when the device list it was drawn from changes.
                NativeCloudTrustSheets.shared.deviceListChanged(value.trust)
                // Profile edit in place: the side panel's name and picture are the account's from the first status on.
                if value.phase == .signedIn || value.phase == .paused || value.phase == .dormant { refreshProfile(minimumGap: Self.profileQuietGap) }
            }
        }
    }
    /// Links (owner, 13 Nov). Two links reach Cloud, both from the official website:
    /// - `terminaldeck://cloud/return/<token>?code&state` finishes a sign-in AUTOMATICALLY, with no question and no
    ///   sheet, but ONLY when it answers the sign-in this app itself started (token and state of the pending one,
    ///   within its lifetime, once). Any other return link changes nothing and is logged as one plain line.
    /// - `terminaldeck://cloud/signin` starts this app's own sign-in (opens the browser) without asking, at most once
    ///   every 30 seconds, and only while no account is signed in and no sign-in is under way.
    /// A link never closes the gate, never changes a saved session and never shows a sheet.
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "terminaldeck", url.host == "cloud" else { return false }
        if url.path.hasPrefix("/return/") { handleReturn(url); return true }
        guard url.path == "/signin" else { return false }
        if let service {
            if snapshot.phase == .signedIn || snapshot.phase == .paused {
                notice = "A sign-in link was opened. This Mac is already signed in to Cloud; to use another account, sign out first."
                return true
            }
            if snapshot.phase == .dormant { Task { try? await service.refresh() }; return true }
            guard !pressing, !busy, monotonic() >= quietUntil else { return true }
            quietUntil = monotonic() &+ 30_000_000_000
            Task {
                // A sign-in this app already started is waiting for its return: the link starts nothing new.
                guard await service.hasPendingSignIn() == false else { return }
                await signIn()
            }
            return true
        }
        guard let activate = activation else { return false }
        if armedDormant {
            activation = nil
            Task { if let account = await activate() { try? await account.resume() } else if service == nil { activation = activate } }
            return true
        }
        guard monotonic() >= quietUntil else { return true }
        quietUntil = monotonic() &+ 30_000_000_000
        pressSignIn()
        return true
    }
    /// The return from the official website. Only the parts are read here; the account decides whether they answer
    /// its own pending sign-in. Never a sheet, never a question.
    private func handleReturn(_ url: URL) {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = items.map(\.name)
        guard parts.count == 3, parts[1] == "return", Set(names) == ["code", "state"], names.count == 2,
              let code = items.first(where: { $0.name == "code" })?.value, let state = items.first(where: { $0.name == "state" })?.value,
              let service else {
            Self.log("cloud sign-in: return link ignored: " + (service == nil ? "no sign-in on this Mac" : "not a sign-in link"))
            return
        }
        let token = String(parts[2])
        Task {
            do {
                guard try await service.finishAppReturn(token: token, code: code, state: state) else {
                    Self.log("cloud sign-in: return link ignored: not this app's sign-in")
                    return
                }
                finishNotice(nil)
                await offerSetup()
            } catch is CancellationError { finishNotice(nil); await service.abandonSignIn() }
            catch CloudFailure.gateClosed { finishNotice(NativeCloudSignInPage.notOpen(nil)) }
            catch {
                // The page names the stage the finish stopped at (the app's log has one line per stage).
                let stage = await service.lastFinishFailure
                finishNotice(stage.map { "Could not sign in (stopped at: \($0)). Try again." } ?? "Could not sign in. Try again.")
            }
        }
    }
    /// The Sign in page's state: nothing is read from disk or the service, only what this model already holds.
    /// `reaching`: a sign-in is saved on this Mac and Cloud is being reached (or did not answer yet). Not signed out
    /// (13 Nov: a launch whose first status read was refused showed the Sign in page, and pressing it would have
    /// started a whole new sign-in).
    enum SignInStage: Equatable { case signedOut(waiting: Bool), notOpen(name: String?), unchecked, reaching(name: String) }
    var signInStage: SignInStage {
        switch snapshot.phase {
        case .signedIn, .paused, .dormant: return .notOpen(name: snapshot.displayName)
        case .signingIn: return .signedOut(waiting: true)
        case .needsSignIn where service != nil && !pressing && snapshot.displayName != nil:
            return .reaching(name: snapshot.displayName ?? "")
        case .signedOut, .needsSignIn:
            if service == nil, armedDormant, activation != nil { return .unchecked }
            return .signedOut(waiting: pressing || busy)
        }
    }
    /// The Cloud page's "Sign in" (or "Check again" for a dormant account), and the website's sign-in link. The
    /// account is built through the armed activation and the browser opens; the account is named on the website's
    /// page, so no sheet follows here (owner, 13 Nov). Agent tools never call this.
    /// "Check again" while a saved sign-in waits for Cloud: the same status read as a launch or a wake. No new sign-in.
    func pressCheckAgain() {
        guard let service, !busy else { return }
        notice = nil
        Task { try? await service.resume() }
    }
    func pressSignIn() {
        guard !pressing, !busy, snapshot.phase != .signingIn else { return }
        if service != nil {
            guard snapshot.phase == .signedOut || snapshot.phase == .needsSignIn else { return }
            pressing = true
            Task { if let starter { await starter() } else { await signIn() }; pressing = false }
            return
        }
        guard let activate = activation else { return }
        let dormant = armedDormant
        activation = nil; pressing = true; notice = nil
        Self.activationFailure = nil
        let started = monotonic()
        Task {
            defer { pressing = false }
            let account = await activate()
            // Two-Mac proof (13 Nov): setting up the account must never hold the browser back; a slow one is said.
            let took = (monotonic() &- started) / 1_000_000
            if took > 2_000 { Self.log("cloud sign-in: setting up the account took \(took) ms") }
            guard let account else {
                if service == nil { activation = activate }
                failed(Self.activationFailure ?? .init(step: "account", kind: "no account was built"))
                Self.activationFailure = nil
                return
            }
            if dormant { try? await account.resume() } else if let starter { await starter() } else { await signIn() }
        }
    }
    /// R5: the warning before signing out of the only Mac that can open saved passwords. "Cancel" is the default
    /// button and answers Return; "Sign out" has no key equivalent and takes a click.
    static func lastSignOutAlert(wordsOnFile: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sign out of the only Mac that can open your saved passwords?"
        alert.informativeText = lastSignOutText(wordsOnFile: wordsOnFile)
        let refuse = alert.addButton(withTitle: "Cancel")
        refuse.keyEquivalent = "\r"
        alert.addButton(withTitle: "Sign out")
        NativeCloudSheetGuard.harden(alert, accept: lastSignOutAccept)
        return alert
    }
    static let lastSignOutAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    /// The truth for each kind of account: an older account with recovery words can open the copy again with them;
    /// an account set up without words cannot.
    static func lastSignOutText(wordsOnFile: Bool) -> String {
        wordsOnFile
            ? "This is the last device that can open the Cloud copy of your saved passwords. If you sign out, only your recovery words can open it again. Your logins stay on this Mac."
            : "This is the last device that can open the Cloud copy of your saved passwords. If you sign out, that copy is lost. Your logins stay on this Mac."
    }
    /// Shown in this Mac's window; without a window nothing is signed out. A press that follows the app's own remote
    /// input is a refusal, and the sheet closes when remote control starts or ends (R3).
    static func confirmLastSignOut() async -> Bool {
        NativeFront.onlyForPerson("Cloud: sign out of the last Mac") { NSApp.activate() }
        let words = await NativeCloudSecrets.recoveryWordsOnFile()
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        return await NativeCloudSheetGuard.shared.present(lastSignOutAlert(wordsOnFile: words), on: window, accept: lastSignOutAccept).taken
    }
    /// A yes-or-no question of the account. Owner, 13 Nov: sign-in and joining ask nothing any more; this stays the
    /// one guarded way a Cloud question is shown. Security review S9: "Cancel" is the default button and answers Return; the accepting
    /// button takes a click, and the question sits behind the same remote-input guard as the trust sheets.
    static func questionAlert(_ title: String, _ text: String, yes: String, no: String = "Cancel") -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = text
        let refuse = alert.addButton(withTitle: no)
        refuse.keyEquivalent = "\r"
        alert.addButton(withTitle: yes)
        NativeCloudSheetGuard.harden(alert, accept: questionAccept)
        return alert
    }
    static let questionAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    /// Review B-M4: the Cloud-on-this-Mac question refuses with "Not now", so the button says what was chosen; the
    /// account's other questions keep "Cancel".
    nonisolated static func refusal(forYes yes: String) -> String { yes == NativeCloudLaunch.cloudHereYes ? NativeCloudLaunch.cloudHereNo : "Cancel" }
    static func ask(_ title: String, _ text: String, yes: String, no: String = "Cancel") async -> Bool {
        let alert = questionAlert(title, text, yes: yes, no: no)
        NativeFront.onlyForPerson("Cloud question: " + title) { NSApp.activate() }
        let answer: NativeCloudSheetAnswer
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            answer = await NativeCloudSheetGuard.shared.present(alert, on: window, accept: questionAccept)
        } else {
            answer = NativeCloudSheetGuard.shared.presentWithoutWindow(alert, accept: questionAccept)
        }
        if answer.chose, !answer.taken { NativeCloudAccount.shared.say(remoteAnswerRefused) }
        return answer.taken
    }
    static let remoteAnswerRefused = "This Mac was just being controlled from another device, so that answer was not taken. Wait a moment and answer again yourself."
    static func inform(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "OK")
        NativeCloudSheetGuard.shared.notice(alert)
    }
    func signIn(provider: String? = nil) async {
        guard let service else { return }
        // Set before anything of Cloud can start; cleared by the person's answer to the new-Mac sheet (ask mode), at
        // once in automatic mode or when the account has no other device, and at sign-out.
        newMacPending = true
        busy = true; notice = nil
        var step = "start address"
        do {
            // Owner, 13 Nov: no loopback listener. The browser comes back through the official website to
            // `terminaldeck://cloud/return/<token>`, which `handle(_:)` finishes.
            let url = try await service.beginAppSignIn(provider: provider)
            Self.log("cloud sign-in: start ok")
            step = "browser"
            openURL(url)
            busy = false // the browser has the flow now; the page is never left disabled (finding 23)
        } catch {
            if error is NativeRPCError { step = "keychain" } else if case CloudFailure.idReused? = error as? CloudFailure { step = "saved account" }
            busy = false; failed(.init(step: step, kind: Self.kind(error)))
            await service.abandonSignIn()
        }
    }
    private func finishNotice(_ problem: String?) {
        busy = false; notice = problem
        // Sign-in failure is visible even though an ineligible Cloud page stays absent.
        if let problem {
            let alert = NSAlert()
            alert.messageText = "Sign-in did not finish"
            alert.informativeText = problem
            alert.addButton(withTitle: "OK")
            NativeCloudSheetGuard.shared.notice(alert)
        }
    }
    /// Two-Mac proof (13 Nov): sign-out said nothing about what stays. One plain question first; "Cancel" is the
    /// default button and answers Return (the account's guarded question). The last-Mac warning for saved
    /// passwords (R5) still follows where it applies.
    nonisolated static let signOutTitle = "Sign out of Cloud on this Mac?"
    nonisolated static let signOutText = "Your work stays on this Mac. It stops syncing with your other devices until you sign in again."
    nonisolated static let signOutYes = "Sign out"
    /// The page's "Sign out". True when the person chose "Sign out" and the sign-out was started.
    @discardableResult
    func pressSignOut() async -> Bool {
        guard !busy else { return false }
        guard await asker(Self.signOutTitle, Self.signOutText, Self.signOutYes) else { return false }
        change("signout")
        return true
    }
    func change(_ action: String) {
        guard action == "signout" || action == "refresh" || snapshot.subscription.offers(.syncSwitches) else { return }
        guard let service else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                if action == "signout" { try await service.signOut() }
                else if action == "refresh" { try await service.refresh() }
                else { try await service.sync(action: action) }
            } catch let refusal as BackendCloudSignOutRefusal { notice = refusal.words }
            catch is CancellationError { notice = nil }
            catch {
                // 13 Nov blocker: say why, on the page and in engine.log.
                let what = action == "signout" ? "sign out" : action == "now" ? "Sync now" : action
                CloudSyncDiagnostics.shared.report(what, error)
                // Proof 3: this Mac busy with its own first copy (or another step of its own) is not a failure.
                if CloudSyncDiagnostics.shared.lastRefusalWasBusy {
                    notice = BackendCloudOverviewWords.syncNowWhilePreparing(snapshot.baseline) ; return
                }
                notice = "Could not finish that change. " + (CloudSyncDiagnostics.shared.lastReason ?? CloudSyncDiagnostics.plainReason(error)) + " Your local work is kept."
            }
        }
    }
    /// Device trust (lean scope item 4). Trust is given only from the two sheets below, in this Mac's own window.
    /// The page asks for the device list when it opens (design 3.1).
    func refreshDevices() {
        guard let service else { return }
        Task { try? await service.refresh() }
    }
    /// The trust sheet for one new device.
    func openTrust(_ row: CloudDeviceTrustRow) {
        Task { await NativeCloudTrustSheets.shared.ask(row, model: self) }
    }
    /// The new-Mac sheet (design 5.3): once, after the person's own sign-in, when the account already has other
    /// devices this Mac does not trust. Nothing is ticked; "Not now" leaves them on the Devices list.
    private func offerSetup() async {
        guard let service else { return }
        // One read for both the sheet's rows and its "list as drawn" (security review S14).
        let all = await service.state().trust
        // 13 Nov leftover: stale earlier entries and removed devices are never offered.
        let rows = all.filter { $0.standing == .new && !$0.stale && !$0.removed }
        // No other device to choose from: there is nothing to answer, and this Mac's memory may be set up.
        // Automatic trust: the account's devices were trusted by the status read itself; no sheet is shown.
        guard !rows.isEmpty, trustMode == .ask else { answerNewMac(); return }
        NativeFront.onlyForPerson("Cloud: new-Mac sheet") { NSApp.activate() }
        NativeCloudTrustSheets.shared.setUp(rows, all: all, model: self)
    }
    /// The Cloud page's way back to the new-Mac sheet when it closed without an answer.
    func reopenSetup() { Task { await offerSetup() } }
    /// The person answered the new-Mac sheet ("Not now", or the ticked devices were trusted): only now may this
    /// Mac's own memory be set up.
    func answerNewMac() {
        guard newMacPending else { return }
        newMacPending = false
        NativeCloudBrainRegistration.newMacAnswered()
    }
    /// "Use the ticked devices": an answer only if the trust was really stored.
    func useTicked(_ captured: [BackendCloudTrustCapture]) async {
        if await trust(captured, restore: true) { answerNewMac() }
    }
    #if DEBUG
    func fixtureBeginNewMac() { newMacPending = true }
    #endif
    #if DEBUG
    /// Proof P3's scratch plan only: where the sign-in address goes instead of a browser.
    func useSignInOpener(_ open: @escaping @MainActor (URL) -> Void) { openURL = open }
    #endif
    /// One plain line on the Cloud page.
    func say(_ text: String) { notice = text }
    /// The composition hands over this Mac's setting and where a change of it is kept.
    func useTrustMode(_ mode: BackendCloudTrustMode, save: (@MainActor (BackendCloudTrustMode) -> Void)? = nil) {
        trustMode = mode
        if let save { saveTrustMode = save }
    }
    /// The Cloud page's choice, a guarded page press only. The account, boot files and the page follow at once.
    func changeTrustMode(_ mode: BackendCloudTrustMode) {
        guard mode != trustMode else { return }
        trustMode = mode
        saveTrustMode?(mode)
        Self.log("cloud trust mode: " + mode.rawValue)
        guard let service else { return }
        Task {
            await service.setTrustMode(mode)
            try? await service.refresh()
            NativeCloudBrainRegistration.pageOpened()
        }
    }
    /// Automatic trust: the devices whose "joined your account" notice is shown now: trusted by the account, within
    /// the last week on this Mac's clock, and not answered in this run.
    func joinedNotices(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String] {
        guard trustMode == .account else { return [] }
        let window = Self.joinedNoticeDays * 86_400_000
        return snapshot.trust.filter { $0.byAccount && !$0.removed && !$0.stale && !dismissedJoins.contains($0.deviceId) && now &- ($0.knownSince ?? 0) < window }.map(\.deviceId)
    }
    /// "Remove" on a "joined your account" notice: this Mac stops taking that device's changes.
    func removeJoined(_ deviceId: String) {
        guard let service else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do { try await service.stopTrusting(deviceId: deviceId); dismissedJoins.insert(deviceId) }
            catch is BackendReachLinkFailure {
                dismissedJoins.insert(deviceId)
                notice = "This Mac no longer takes that device's changes, but it could not be removed from Reach yet. Choose \(NativeDevicesSettings.signOutTitle) on Settings → Devices."
            }
            catch let refusal as BackendCloudTrustRefusal { notice = refusal.words }
            catch { notice = "Could not finish that change. Nothing was changed." }
        }
    }
    /// Settings → Devices "Sign out this device" and `devices.remove` (14 Nov): the Cloud ends that device's sign-in.
    /// Throws `BackendDeviceSignOutRefusal` (nothing changed) or the Cloud's own failure.
    func signOutDevice(_ deviceId: String) async throws -> BackendDeviceSignOutOutcome {
        guard let service else { throw BackendDeviceSignOutRefusal.notSignedIn }
        return try await service.signOutDevice(deviceId)
    }
    /// A device's page "Name" (owner, 15 Nov): the Cloud renames that device. Throws when it did not.
    func renameDevice(_ deviceId: String, name: String) async throws {
        guard let service else { throw BackendDeviceSignOutRefusal.notSignedIn }
        try await service.renameDevice(deviceId, name: name)
    }
    /// The one button for a device whose reported key changed (automatic mode).
    func trustAgain(_ deviceId: String) {
        guard let service, let row = snapshot.trust.first(where: { $0.deviceId == deviceId && $0.keyChanged }) else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do { try await service.trustChangedKey(row) }
            catch let refusal as BackendCloudTrustRefusal { notice = refusal.words }
            catch { notice = "Could not finish that change. Nothing was trusted." }
        }
    }
    /// The press on a trust sheet. `captured` is what that sheet showed when it was drawn (R1).
    /// True only when the trust was stored.
    @discardableResult
    func trust(_ captured: [BackendCloudTrustCapture], restore: Bool) async -> Bool {
        guard let service, !captured.isEmpty else { return false }
        busy = true; notice = nil
        defer { busy = false }
        do { try await service.trustDevices(captured, restore: restore); return true }
        catch let refusal as BackendCloudTrustRefusal { notice = refusal.words }
        catch { notice = "Could not finish that change. Nothing was trusted." }
        return false
    }
    #if DEBUG
    func fixture(_ snapshot: CloudAccountSnapshot) { self.snapshot = snapshot; NativeCloudDisplayGate.shared.subscription(snapshot.subscription); NativeCloudDisplayGate.shared.set(snapshot.visible(at: 0)) }
    /// A model of a fixture's own: its state only, without opening the app-wide Cloud page gate.
    func fixtureSnapshot(_ snapshot: CloudAccountSnapshot, memoryIncluded: Bool? = nil) { self.snapshot = snapshot; self.memoryIncluded = memoryIncluded }
    func fixtureUser(_ user: CloudUserIdentity?) { signedInUser = user }
    func fixtureProfile(_ profile: AccountProfile?) { accountProfile = profile }
    func fixtureProfileProblem(_ line: String?) { profileProblem = line }
    func fixtureLocalPicture(_ image: NSImage?) { localPicture = image.map { LocalPicture(image: $0, url: nil) } }
    #endif
}

/// Thread-safe, read-only eligibility projection for static navigation inventories.
final class NativeCloudDisplayGate: @unchecked Sendable {
    static let shared = NativeCloudDisplayGate()
    private let lock = NSLock()
    private var allowed = false
    private var offered = false
    private var payment: CloudSubscriptionSnapshot = .init()
    func subscription(_ value: CloudSubscriptionSnapshot) { lock.withLock { payment = value }; CloudSubscriptionOffers.shared.update(value) }
    func offers(_ place: CloudPaidPlace) -> Bool { lock.withLock { payment.offers(place) } }
    var showsSubscription: Bool { lock.withLock { payment.showsSubscription } }
    var accountShows: Bool { lock.withLock { allowed || offered } }
    func get() -> Bool { lock.withLock { payment.offers(.settingsCloud, existing: allowed) } }
    func set(_ value: Bool) { lock.withLock { allowed = value } }
    /// This copy of the app can sign in at all (`NativeCloudApplication.canSignIn`): the Settings section is listed
    /// with its Sign in button. Setting it constructs nothing.
    func offer(_ value: Bool) { lock.withLock { offered = value } }
    /// The "Cloud" Settings section is listed: an open Cloud page, or a copy that offers sign-in.
    var shows: Bool { lock.withLock { payment.offers(.sidebarCloud, existing: allowed || offered) } }
}
