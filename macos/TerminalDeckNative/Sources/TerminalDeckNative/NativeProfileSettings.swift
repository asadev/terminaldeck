import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

/// What Settings → Profile knows about the person (owner, 14 Nov: "a profile option which should be the top one …
/// profile photo, name, username, connected accounts like GitHub, Google and email, bio, links, country"). Only what
/// this Mac already has: a fact the app does not have is left out, never shown blank. Since 15 Nov his name and picture
/// are changed in place on the page (the account's profile calls); the rest stays on the website.
struct NativeProfileFacts: Equatable {
    enum SignIn: String, CaseIterable, Identifiable {
        case github, google, apple, email
        var id: String { rawValue }
        var title: String {
            switch self { case .github: "GitHub"; case .google: "Google"; case .apple: "Apple"; case .email: "E-mail" }
        }
        var symbol: String {
            switch self {
            case .github: "chevron.left.forwardslash.chevron.right"
            case .google: "g.circle"
            case .apple: "apple.logo"
            case .email: "envelope"
            }
        }
        /// The service's word for how a person signed in ("github", "GitHub OAuth", "google-oauth2", "magic-link"…).
        static func from(_ provider: String?) -> SignIn? {
            guard let word = provider?.lowercased(), !word.isEmpty else { return nil }
            if word.contains("github") { return .github }
            if word.contains("google") { return .google }
            if word.contains("apple") { return .apple }
            if word.contains("mail") || word.contains("magic") || word.contains("otp") { return .email }
            return nil
        }
    }
    /// nil: nobody is signed in on this Mac.
    var name: String?
    var username: String?
    var email: String?
    var picture: URL?
    /// The way this Mac's sign-in was made, when the saved sign-in says it (used only without the profile API's list).
    var signedInWith: SignIn?
    /// The saved sign-in is waiting to be checked again (or Cloud did not answer): "Sign in again" is offered.
    var needsSignInAgain = false
    struct Detail: Equatable, Identifiable { let label: String; let value: String; var id: String { label } }
    /// One way to sign in, as the profile API lists it (connected) or as the live site can add it (not connected).
    struct SignInRow: Equatable, Identifiable {
        let id: String
        let title: String
        let symbol: String
        let account: String?
        let connected: Bool
    }
    /// Bio, links, country… in order, once the edit slice reads them. Empty today.
    var details: [Detail] = []
    var signInRows: [SignInRow] = []
    /// The account's profile answered (15 Nov): his name and picture are changed right on the page.
    var editable = false
    /// He chose this picture himself (not the sign-in's own): "Remove picture" is offered.
    var pictureRemovable = false
    /// The picture he just chose, from this Mac's own copy, until the account's address for it loads.
    var localPicture: NSImage?

    var signedIn: Bool { name != nil }
    /// The Settings list's top row: his name, else "Profile".
    var sidebarTitle: String { name ?? "Profile" }

    static func symbol(_ provider: String) -> String { SignIn.from(provider)?.symbol ?? "person.badge.key" }
    static func title(_ provider: String) -> String { SignIn.from(provider)?.title ?? provider.capitalized }
    /// TRUE ways only (review 14 Nov, item 3): every way the profile API lists as linked is "Connected"; "Add" only for
    /// a way the live site can add now (its provider is switched on and not linked yet). Without the profile API: only
    /// the way this Mac's saved sign-in was made, and no "Add".
    static func rows(profile: NativeCloudAccount.AccountProfile?, signedInWith: SignIn?) -> [SignInRow] {
        guard let profile else {
            guard let signedInWith else { return [] }
            return [SignInRow(id: signedInWith.rawValue, title: signedInWith.title, symbol: signedInWith.symbol, account: nil, connected: true)]
        }
        let linked = profile.ways.map { way in
            SignInRow(id: "linked:" + way.provider + ":" + (way.account ?? ""), title: way.providerName.isEmpty ? title(way.provider) : way.providerName,
                      symbol: symbol(way.provider), account: way.account, connected: true)
        }
        let have = Set(profile.ways.map(\.provider))
        let addable = profile.addable.filter { !have.contains($0) }.map { provider in
            SignInRow(id: "add:" + provider, title: title(provider), symbol: symbol(provider), account: nil, connected: false)
        }
        return linked + addable
    }

    /// The facts from the Cloud account model: the profile API's answer when it came (name, username, e-mail,
    /// picture, ways), else the account's state and the saved sign-in. A name that is the e-mail is not said twice.
    @MainActor static func current(_ model: NativeCloudAccount = .shared) -> Self {
        let phase = model.snapshot.phase
        guard phase != .signedOut, phase != .signingIn,
              let saved = (model.snapshot.displayName ?? model.signedInUser?.displayName)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !saved.isEmpty else { return Self() }
        let profile = model.accountProfile
        let raw = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? saved
        let user = model.signedInUser
        let email = (profile?.email ?? user?.email)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let way = SignIn.from(user?.provider)
        var facts = Self(name: raw, username: profile?.username?.nonEmpty,
                         email: email?.isEmpty == false && email?.lowercased() != raw.lowercased() ? email : nil,
                         picture: profile?.picture, signedInWith: way, needsSignInAgain: phase == .needsSignIn)
        facts.signInRows = rows(profile: profile, signedInWith: way)
        facts.editable = profile != nil
        facts.pictureRemovable = profile?.pictureSource == "uploaded" && profile?.picture != nil
        if let local = model.localPicture, local.url == nil || local.url == profile?.picture { facts.localPicture = local.image }
        return facts
    }

    /// One or two letters for the picture: "Asad Ali" → "AA", "person@example.com" → "P".
    static func initials(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        let base = name.contains("@") ? String(name.split(separator: "@").first ?? "") : name
        let words = base.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }).filter { !$0.isEmpty }
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// His picture from the profile API when it has one, else his initials on the accent colour. `local`: the picture he
/// just chose, drawn from this Mac's copy while the account's address for it loads (never the initials in between).
struct NativeProfileAvatar: View {
    let name: String?
    var picture: URL? = nil
    var local: NSImage? = nil
    let size: CGFloat
    var body: some View {
        if let local {
            Image(nsImage: local).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else if let picture {
            AsyncImage(url: picture) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { initials }
            }
            .frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .accessibilityHidden(true)
        } else {
            initials
        }
    }
    private var initials: some View {
        let letters = NativeProfileFacts.initials(name)
        return ZStack {
            Circle().fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                         startPoint: .top, endPoint: .bottom))
            if letters.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white)
            } else {
                Text(letters).font(.system(size: size * (letters.count > 1 ? 0.38 : 0.46), weight: .semibold))
                    .foregroundStyle(.white).minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Settings → Profile (owner, 15 Nov: like Apple Account; DESIGN.md section 2): his picture 96 pt in the centre, his
/// name (22 pt) and e-mail under it; then the rows he goes into (Personal information, Sign-in, Cloud) and his devices.
/// Name and picture change in place, here (15 Nov, lane/profile-edit). Signed out: one sentence and Sign in.
struct NativeProfileSettings: View {
    var model: NativeCloudAccount = .shared
    /// The website's account page: username, bio, links, country (and everything while the profile could not be read).
    static let accountPage = URL(string: "https://terminaldeck.dev/account")!
    /// The live site's "Ways you sign in" section, where "Add another way to sign in" is (tds-cloud-app-callback 2652b19).
    static let addWayPage = URL(string: "https://terminaldeck.dev/account#ways")!
    static var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    static func openAccountPage() { openURL(accountPage) }
    static let signedOutLine = "Sign in with your Terminal Deck account to see your profile and keep your work on all your devices."
    /// Once his name and picture change here, the website keeps only the rest (username, bio, links, country).
    static let moreButton = "More on the website"
    static let nameFont = DeckSettingsLook.profileName
    @State private var feed: NativeDevicesFeed
    @Environment(\.deckSettingsOpen) private var open

    init(model: NativeCloudAccount = .shared, devicesFixture: NativeDevicesFixture? = nil) {
        self.model = model
        _feed = State(initialValue: NativeDevicesFeed(account: model, fixture: devicesFixture))
    }

    var body: some View {
        let facts = NativeProfileFacts.current(model)
        DeckSettingsScaffold(title: "Profile") {
            if facts.signedIn { signedIn(facts) } else { signedOut }
        }
        .disabled(model.busy)
        .onAppear { model.refreshProfile() }
        .task { if facts.signedIn { await feed.start() } }
        .onDisappear { feed.stop() }
    }

    @ViewBuilder private func signedIn(_ facts: NativeProfileFacts) -> some View {
        VStack(spacing: DeckTokens.Spacing.s4) {
            NativeProfilePicture(model: model, facts: facts, size: DeckSettingsLook.profilePicture)
                .padding(.bottom, DeckTokens.Spacing.s8)
            if facts.editable {
                NativeProfileNameField(model: model, alignment: .center, font: Self.nameFont)
            } else {
                Text(facts.name ?? "").font(Self.nameFont).lineLimit(1).truncationMode(.middle)
            }
            if let email = facts.email {
                Text(email).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            // A save that did not go through: ONE plain line, until the next edit.
            if let problem = model.profileProblem {
                Text(problem).font(DeckSettingsLook.rowTitle).foregroundStyle(DeckTokens.warn).lineLimit(2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        DeckSettingsGroup {
            DeckSettingsLinkRow(title: "Personal information", symbol: "person.text.rectangle.fill", tint: .gray) {
                open(NativeSettingsNavigation.personalID)
            }
            DeckSettingsLinkRow(title: "Sign-in", symbol: "lock.shield.fill", tint: .gray,
                                value: facts.needsSignInAgain ? "Sign in again" : nil, valueColor: DeckTokens.warn) {
                open(NativeSettingsNavigation.signInID)
            }
            DeckSettingsLinkRow(title: "Cloud", symbol: "cloud.fill", tint: .blue) { open(NativeSettingsNavigation.cloudID) }
        }
        if !feed.groups.main.isEmpty || !feed.groups.older.isEmpty {
            NativeDevicesGroup(feed: feed)
        }
        if let notice = model.notice { DeckSettingsGroup { DeckSettingsProblem(text: notice, warn: false) } }
    }

    @ViewBuilder private var signedOut: some View {
        let stage = model.signInStage
        let content = NativeCloudSignInPage.content(stage)
        VStack(spacing: DeckTokens.Spacing.s12) {
            NativeProfileAvatar(name: nil, size: DeckSettingsLook.profilePicture).opacity(0.55)
            Text(Self.line(stage)).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            Button(content.button) {
                if case .notOpen = stage { Task { await model.pressSignOut() } }
                else if case .reaching = stage { model.pressCheckAgain() }
                else { model.pressSignIn() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!content.enabled || model.busy)
            if let text = model.notice { Text(text).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DeckTokens.Spacing.s16)
    }

    /// Signed out: the one sentence of this page; the other in-between states say what the Cloud page says.
    static func line(_ stage: NativeCloudAccount.SignInStage) -> String {
        if case .signedOut = stage { return signedOutLine }
        return NativeCloudSignInPage.content(stage).line
    }

    static let dropTypes: [UTType] = [.fileURL, .image]

    /// The standard macOS picture chooser.
    static func choosePicture(_ model: NativeCloudAccount) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for your profile."
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await savePicture(at: url, model) }
        }
    }

    /// A file's bytes (never one over 64 MB), then the model crops, shrinks and sends it.
    static func savePicture(at url: URL, _ model: NativeCloudAccount) async {
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= NativeCloudAccount.pictureSourceLimit else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        await model.saveProfilePicture(data ?? Data())
    }

    /// A dropped picture file, or a picture dragged from another app (its data).
    static func take(_ providers: [NSItemProvider], _ model: NativeCloudAccount) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in await savePicture(at: url, model) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in await model.saveProfilePicture(data) }
            }
            return true
        }
        return false
    }
}

/// His picture, changed in place: a click opens the picture chooser (or, once he chose one himself, a menu with
/// "Choose picture…" and "Remove picture"); a picture dragged onto it is taken too.
struct NativeProfilePicture: View {
    let model: NativeCloudAccount
    let facts: NativeProfileFacts
    let size: CGFloat
    @State private var dropping = false

    var body: some View {
        let avatar = NativeProfileAvatar(name: facts.name, picture: facts.picture, local: facts.localPicture, size: size)
            .overlay {
                if model.localPicture != nil, model.localPicture?.url == nil { ProgressView().controlSize(.small) }
            }
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).opacity(dropping ? 1 : 0))
        if !facts.editable {
            avatar
        } else if facts.pictureRemovable {
            Menu {
                Button("Choose picture…") { NativeProfileSettings.choosePicture(model) }
                Button("Remove picture") { Task { await model.removeProfilePicture() } }
            } label: { avatar }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Change your picture")
            .onDrop(of: NativeProfileSettings.dropTypes, isTargeted: $dropping) { NativeProfileSettings.take($0, model) }
        } else {
            Button { NativeProfileSettings.choosePicture(model) } label: { avatar }
                .buttonStyle(.plain)
                .help("Choose a picture")
                .accessibilityLabel("Choose a picture")
                .onDrop(of: NativeProfileSettings.dropTypes, isTargeted: $dropping) { NativeProfileSettings.take($0, model) }
        }
    }
}

/// His name as a plain field he clicks and types into (Profile's big name, Personal information's Name row). Return or
/// clicking away saves; Escape puts the name back; leaving the page while typing saves too. Never more than the
/// service takes (60 characters).
struct NativeProfileNameField: View {
    let model: NativeCloudAccount
    var alignment: TextAlignment = .leading
    var font: Font = DeckSettingsLook.rowTitle
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let name = NativeProfileFacts.current(model).name
        NativeSessionTextField("Your name", text: $draft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .sessionFocused($nameFocused)
            .onSubmit { commitName(); nameFocused = false }
            .onExitCommand { draft = name ?? ""; nameFocused = false }
            .font(font)
            .multilineTextAlignment(alignment)
            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            .onChange(of: draft) { _, text in
                if text.count > NativeCloudAccount.nameLimit { draft = String(text.prefix(NativeCloudAccount.nameLimit)) }
            }
            .onChange(of: name) { _, name in if !nameFocused { draft = name ?? "" } }
            .onAppear { draft = name ?? "" }
            .onDisappear { commitName() }
            .help("Click to change your name")
            .accessibilityLabel("Your name")
    }

    private func commitName() {
        let typed = draft, model = model
        Task {
            await model.saveProfileName(typed)
            // Saved: the account's cleaned name; not saved: the old name is back.
            if !nameFocused { draft = NativeProfileFacts.current(model).name ?? "" }
        }
    }
}

/// Profile › Personal information: Name (typed in place), Username, E-mail, and "More on the website" as the last row.
struct NativeProfilePersonalPage: View {
    var model: NativeCloudAccount = .shared
    var body: some View {
        let facts = NativeProfileFacts.current(model)
        DeckSettingsScaffold(title: "Personal information") {
            DeckSettingsGroup {
                DeckSettingsRow("Name") {
                    if facts.editable {
                        NativeProfileNameField(model: model, alignment: .trailing).frame(maxWidth: 260)
                    } else {
                        Text(facts.name ?? "").foregroundStyle(.secondary)
                    }
                }
                if let username = facts.username { DeckSettingsRow("Username", state: "@" + username) }
                if let email = facts.email { DeckSettingsRow("E-mail", state: email) }
                ForEach(facts.details) { row in DeckSettingsRow(row.label, state: row.value) }
                // Name and picture change right here; the website keeps the rest (and everything while the account's
                // profile could not be read).
                DeckSettingsLinkRow(title: facts.editable ? NativeProfileSettings.moreButton : "Edit profile on the website") {
                    NativeProfileSettings.openAccountPage()
                }
            }
            if let problem = model.profileProblem { DeckSettingsGroup { DeckSettingsProblem(text: problem) } }
        }
        .disabled(model.busy)
        .onAppear { model.refreshProfile() }
    }
}

/// Profile › Sign-in: the ways he signs in (their marks, "Connected" or Add), then Sign out on its own (the only red
/// text on the page).
struct NativeProfileSignInPage: View {
    var model: NativeCloudAccount = .shared
    var body: some View {
        let facts = NativeProfileFacts.current(model)
        DeckSettingsScaffold(title: "Sign-in") {
            if !facts.signInRows.isEmpty {
                DeckSettingsGroup {
                    ForEach(facts.signInRows) { row in
                        DeckSettingsRow(row.title, subtitle: row.account) {
                            if row.connected { Text("Connected").foregroundStyle(.secondary) }
                            else { Button("Add") { NativeProfileSettings.openURL(NativeProfileSettings.addWayPage) } }
                        }
                        .modifier(NativeSignInMarkLeading(id: row.id))
                    }
                }
            }
            DeckSettingsGroup {
                if facts.needsSignInAgain {
                    // Review 14 Nov, item 8: the saved sign-in is checked again; if the account refuses it, this Mac is
                    // signed out and the page shows Sign in.
                    DeckSettingsButtonRow(title: "Sign in again") { model.pressCheckAgain() }
                }
                DeckSettingsButtonRow(title: "Sign out", role: .destructive) { Task { await model.pressSignOut() } }
            }
            if let notice = model.notice { DeckSettingsGroup { DeckSettingsProblem(text: notice, warn: false) } }
        }
        .disabled(model.busy)
        .onAppear { model.refreshProfile() }
    }
}

/// A way to sign in's mark in front of its row: Google's coloured G, GitHub's dark tile, Apple's logo, e-mail's envelope.
private struct NativeSignInMarkLeading: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            NativeSignInMark(provider: id).padding(.leading, DeckSettingsLook.rowPadding)
            content.padding(.leading, -2)
        }
    }
}

struct NativeSignInMark: View {
    /// The row's id ("linked:github:@sam", "add:google", "github").
    let provider: String
    var body: some View {
        let way = NativeProfileFacts.SignIn.from(provider)
        ZStack {
            switch way {
            case .google:
                RoundedRectangle(cornerRadius: DeckSettingsLook.rowTileRadius).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: DeckSettingsLook.rowTileRadius).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                Image(nsImage: NativeSignInMarks.google).resizable().interpolation(.high)
                    .frame(width: DeckSettingsLook.rowGlyph + 2, height: DeckSettingsLook.rowGlyph + 2)
            case .github:
                RoundedRectangle(cornerRadius: DeckSettingsLook.rowTileRadius).fill(Color(white: 0.12))
                Image(nsImage: NativeSignInMarks.github).renderingMode(.template).resizable().interpolation(.high)
                    .foregroundStyle(.white)
                    .frame(width: DeckSettingsLook.rowGlyph + 2, height: DeckSettingsLook.rowGlyph + 2)
            case .apple:
                RoundedRectangle(cornerRadius: DeckSettingsLook.rowTileRadius).fill(Color.black)
                Image(systemName: "apple.logo").font(.system(size: 14)).foregroundStyle(.white)
            default:
                RoundedRectangle(cornerRadius: DeckSettingsLook.rowTileRadius).fill(Color.blue)
                Image(systemName: "envelope.fill").font(.system(size: 12)).foregroundStyle(.white)
            }
        }
        .frame(width: DeckSettingsLook.rowTile, height: DeckSettingsLook.rowTile)
        .accessibilityHidden(true)
    }
}

/// The real Google "G" and GitHub mark, as vectors (the same marks terminaldeck.dev's sign-in page draws), made into
/// images once. Apple's is the SF Symbol `apple.logo`.
enum NativeSignInMarks {
    static let googleSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">\
    <path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.7-1.57 2.68-3.88 2.68-6.62Z"/>\
    <path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.8.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.33A9 9 0 0 0 9 18Z"/>\
    <path fill="#FBBC05" d="M3.97 10.72a5.4 5.4 0 0 1 0-3.44V4.95H.96a9 9 0 0 0 0 8.1l3.01-2.33Z"/>\
    <path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58C13.46.89 11.43 0 9 0A9 9 0 0 0 .96 4.95l3.01 2.33C4.68 5.16 6.66 3.58 9 3.58Z"/>\
    </svg>
    """
    static let githubSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\
    <path fill="#000000" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.4 7.4 0 0 1 2-.27c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/>\
    </svg>
    """
    static let google: NSImage = image(googleSVG, template: false)
    static let github: NSImage = image(githubSVG, template: true)
    /// An image from the SVG text (AppKit draws SVG as a vector); an empty image if it ever cannot.
    static func image(_ svg: String, template: Bool) -> NSImage {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = template
        return image
    }
}
