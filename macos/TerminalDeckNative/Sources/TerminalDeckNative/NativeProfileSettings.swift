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
        /// The service's handle for removing this way; never shown. nil = it cannot be removed from here.
        var wayID: String? = nil
        /// The service's own word on whether it may be removed now; nil = it did not say.
        var canRemove: Bool? = nil
    }
    /// Bio, links, country… in order, once the edit slice reads them. Empty today.
    var details: [Detail] = []
    var signInRows: [SignInRow] = []
    /// The account's profile answered (15 Nov): his name and picture are changed right on the page.
    var editable = false
    /// The account lets the username be changed now (18 Nov: typed in place on Personal information).
    var usernameCanChange = true
    /// He chose this picture himself (not the sign-in's own): "Remove picture" is offered.
    var pictureRemovable = false
    /// The picture he just chose, from this Mac's own copy, until the account's address for it loads.
    var localPicture: NSImage?

    var signedIn: Bool { name != nil }
    /// The Settings list's top row: his name; with nobody signed in it invites ("Sign in"), it never says "Profile" over
    /// an empty picture (owner, 18 Nov, item 14).
    var sidebarTitle: String { name ?? NativeProfileFacts.signInTitle }
    static let signInTitle = "Sign in"

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
                      symbol: symbol(way.provider), account: way.account, connected: true, wayID: way.id, canRemove: way.canRemove)
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
        facts.usernameCanChange = profile?.usernameCanChange ?? false
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
            if letters.isEmpty {
                // Nobody signed in (18 Nov, item 14): a quiet grey picture, never the accent colour over an empty account.
                Circle().fill(DeckTokens.avatarTile)
                Image(systemName: "person.fill").font(.system(size: size * 0.46, weight: .regular)).foregroundStyle(.secondary)
            } else {
                Circle().fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                             startPoint: .top, endPoint: .bottom))
                Text(letters).font(.system(size: size * (letters.count > 1 ? 0.38 : 0.46), weight: .semibold))
                    .foregroundStyle(.white).minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Settings → Profile (owner, 15 Nov: like Apple Account): his picture 96 pt in the centre, his name (22 pt) and e-mail
/// under it; then the rows he goes into (Personal information, Sign-in, Cloud) and ONE list of his devices. Name and
/// picture change in place. Nobody signed in: the page invites (18 Nov, item 14), it never looks switched off.
struct NativeProfileSettings: View {
    var model: NativeCloudAccount = .shared
    /// The account's "Ways you sign in" step, where another way is added (tds-cloud-app-callback 2652b19).
    static let addWayPage = URL(string: "https://terminaldeck.dev/account#ways")!
    static var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    static let signedOutTitle = "Terminal Deck account"
    static let signedOutLine = "Sign in once and your sessions, memory and settings are on every device you use."
    static let signedOutPicture: CGFloat = 72
    static let nameFont = DeckSettingsLook.profileName
    /// Pictures: the photo drawn as while the pointer is over it; the long devices list drawn open.
    var fixtureHover = false
    var fixtureDevicesOpen = false
    var fixtureEdits: NativeDeviceRowEdits? = nil
    var fixtureSigningOut: Int? = nil
    @State private var feed: NativeDevicesFeed
    @Environment(\.deckSettingsOpen) private var open

    init(model: NativeCloudAccount = .shared, devicesFixture: NativeDevicesFixture? = nil, fixtureHover: Bool = false,
         fixtureDevicesOpen: Bool = false, fixtureEdits: NativeDeviceRowEdits? = nil, fixtureSigningOut: Int? = nil) {
        self.model = model
        self.fixtureHover = fixtureHover; self.fixtureDevicesOpen = fixtureDevicesOpen; self.fixtureEdits = fixtureEdits
        self.fixtureSigningOut = fixtureSigningOut
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
            NativeProfilePicture(model: model, facts: facts, size: DeckSettingsLook.profilePicture, fixtureHover: fixtureHover)
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
            let plan = NativeCloudPlanSeam.shown()
            if model.snapshot.subscription.offers(.settingsCloud) {
                DeckSettingsLinkRow(title: "Cloud", symbol: "cloud.fill", tint: .blue) { open(NativeSettingsNavigation.cloudID) }
            }
            if let plan { NativeCloudPlanRow(facts: plan) { open(NativeSettingsNavigation.planID) } }
        }
        if model.snapshot.subscription.offers(.devices), !feed.rows.isEmpty {
            NativeDevicesGroup(feed: feed, fixtureOpen: fixtureDevicesOpen, fixtureEdits: fixtureEdits, fixtureSigningOut: fixtureSigningOut)
        }
        if let notice = model.notice { DeckSettingsGroup { DeckSettingsProblem(text: notice, warn: false) } }
    }

    /// Nobody signed in (owner, 18 Nov, item 14: the profile stays in Settings "so they can feel it", in a form that
    /// invites and does not nag): a quiet picture, what the account is, ONE sentence and the one blue button. Nothing
    /// is dimmed, nothing is orange, no word about versions or paying.
    @ViewBuilder private var signedOut: some View {
        let stage = model.signInStage
        let content = NativeCloudSignInPage.content(stage)
        VStack(spacing: DeckTokens.Spacing.s8) {
            NativeProfileAvatar(name: nil, size: Self.signedOutPicture)
                .padding(.bottom, DeckTokens.Spacing.s4)
            Text(Self.signedOutTitle).font(.system(size: 17, weight: .semibold))
            Text(Self.line(stage)).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            Button(content.button) {
                if case .notOpen = stage { Task { await model.pressSignOut() } }
                else if case .reaching = stage { model.pressCheckAgain() }
                else { model.pressSignIn() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!content.enabled || model.busy)
            .padding(.top, DeckTokens.Spacing.s8)
            if let text = model.notice { Text(text).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DeckTokens.Spacing.s24)
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

/// What the pointer over his picture shows (owner, 18 Nov, item 27: "when you hover over, it should show you that,
/// okay, you can change it"): a dark band across the bottom third of the circle with a camera and the word "Change",
/// and the faintest veil over the rest. The band never sits on his face or on the initials. Nothing moves or grows.
struct NativeProfilePictureVeil: View {
    let size: CGFloat
    static let title = "Change"
    /// The whole picture, faintly; the band's own ink; the band's share of the picture's height.
    static let veil: Double = 0.12
    static let band: Double = 0.6
    static let bandShare: CGFloat = 0.34
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(Self.veil)
            HStack(spacing: 4) {
                Image(systemName: "camera.fill").font(.system(size: 10, weight: .medium))
                Text(Self.title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            // The circle narrows towards its bottom: the words sit a little above the band's middle.
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, minHeight: size * Self.bandShare, maxHeight: size * Self.bandShare)
            .background(Color.black.opacity(Self.band))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// His picture, changed in place: the pointer over it shows that it can be changed; only a CLICK opens the picture
/// chooser (or, once he chose one himself, a menu with "Choose picture…" and "Remove picture"); a picture dragged onto
/// it is taken too.
struct NativeProfilePicture: View {
    let model: NativeCloudAccount
    let facts: NativeProfileFacts
    let size: CGFloat
    /// Pictures: drawn as while the pointer is over it.
    var fixtureHover = false
    @State private var dropping = false
    @State private var hovering = false
    @State private var menuOpen = false

    var body: some View {
        let uploading = model.localPicture != nil && model.localPicture?.url == nil
        let avatar = NativeProfileAvatar(name: facts.name, picture: facts.picture, local: facts.localPicture, size: size)
            .overlay { if uploading { ProgressView().controlSize(.small) } }
            .overlay {
                NativeProfilePictureVeil(size: size)
                    .opacity(facts.editable && (hovering || fixtureHover) && !uploading ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).opacity(dropping ? 1 : 0))
            .contentShape(Circle())
        if !facts.editable {
            avatar
        } else {
            // No picture of his own yet: the click opens the chooser. Once he chose one: the app's menu (DeckMenu) with
            // "Choose picture…" and "Remove picture".
            Button {
                if facts.pictureRemovable { menuOpen.toggle() } else { NativeProfileSettings.choosePicture(model) }
            } label: { avatar }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .accessibilityLabel("Change your picture")
            .onDrop(of: NativeProfileSettings.dropTypes, isTargeted: $dropping) { NativeProfileSettings.take($0, model) }
            .deckMenu(isPresented: $menuOpen, alignment: .center) { NativeProfilePictureMenu(model: model) }
        }
    }
}

/// The picture's menu once he chose one himself.
struct NativeProfilePictureMenu: View {
    let model: NativeCloudAccount
    static let choose = "Choose picture…"
    static let remove = "Remove picture"
    var body: some View {
        DeckMenuRow(Self.choose, symbol: "photo") { NativeProfileSettings.choosePicture(model) }
        DeckMenuRow(Self.remove, symbol: "trash", role: .destructive) { Task { await model.removeProfilePicture() } }
    }
}

/// His name as a plain field he clicks and types into (Profile's big name, Personal information's Name row). Return or
/// clicking away saves; Escape puts the name back; leaving the page while typing saves too. Never more than the
/// service takes (60 characters). `onSaved` is told when the account took a CHANGED name (the row's small check).
struct NativeProfileNameField: View {
    let model: NativeCloudAccount
    var alignment: TextAlignment = .leading
    var font: Font = DeckSettingsLook.rowTitle
    var onSaved: (@MainActor () -> Void)? = nil
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
        let typed = draft, model = model, onSaved = onSaved
        let before = NativeProfileFacts.current(model).name ?? ""
        Task {
            let took = await model.saveProfileName(typed)
            // Saved: the account's cleaned name; not saved: the old name is back.
            let after = NativeProfileFacts.current(model).name ?? ""
            if !nameFocused { draft = after }
            if took, after != before { onSaved?() }
        }
    }
}

/// His username as a field (18 Nov, item 28): "@" in front, Enter or clicking away saves it to the account, Escape puts
/// the old one back. `save` answers nil when the account took it, else the one sentence to show.
struct NativeProfileUsernameField: View {
    let current: String
    let save: @MainActor (String) async -> String?
    var onSaved: @MainActor () -> Void = {}
    var onProblem: @MainActor (String?) -> Void = { _ in }
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    /// What goes to the account: no "@" in front, no spaces, at most 40 characters (the service cleans the rest).
    static func cleaned(_ typed: String) -> String { NativeCloudAccount.cleanedUsername(typed) }

    /// The field's own text: the username with its "@" in front, always (typing over it puts it back).
    static func shown(_ username: String) -> String { "@" + cleaned(username) }

    var body: some View {
        NativeSessionTextField("@username", text: $draft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .sessionFocused($focused)
            .onSubmit { commit(); focused = false }
            .onExitCommand { draft = Self.shown(current); focused = false }
            .font(DeckSettingsLook.rowTitle)
            .multilineTextAlignment(.trailing)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: draft) { _, text in
                let kept = Self.shown(text)
                if kept != text { draft = kept }
            }
            .onChange(of: current) { _, value in if !focused { draft = Self.shown(value) } }
            .onAppear { draft = Self.shown(current) }
            .disabled(saving)
            .accessibilityLabel("Your username")
    }

    private func commit() {
        let typed = Self.cleaned(draft)
        guard !saving, typed != current else { draft = Self.shown(current); return }
        saving = true
        let save = save, onSaved = onSaved, onProblem = onProblem, current = current
        Task {
            let problem = await save(typed)
            saving = false
            if let problem { draft = Self.shown(current); onProblem(problem) } else { onProblem(nil); onSaved() }
        }
    }
}

/// The look of a value he can type into on a Settings row (18 Nov): it reads as "type here" without a hover. 220 pt
/// wide, 24 pt high, the group's fill one step darker, radius 6, no outline.
struct NativeProfileQuietField: ViewModifier {
    static let width: CGFloat = 220
    static let height: CGFloat = 24
    static let line: CGFloat = 17
    func body(content: Content) -> some View {
        content
            // The field keeps its own line height and is centred in the 24 pt box (it drew its text at the box's top).
            .frame(height: Self.line)
            .padding(.horizontal, 8)
            .frame(width: Self.width, height: Self.height)
            .background(DeckSettingsQuietField.fill, in: RoundedRectangle(cornerRadius: DeckSettingsQuietField.radius))
    }
}

/// The small green check a field shows for a moment after the account took its value.
struct NativeProfileSavedCheck: View {
    let shown: Bool
    static let shows: Duration = .milliseconds(1600)
    var body: some View {
        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DeckTokens.good)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: shown)
            .accessibilityLabel("Saved").accessibilityHidden(!shown)
    }
}

/// Profile › Personal information (owner, 18 Nov, item 28: "why it is taking you to more on website? We don't need this
/// option. Just give everything here and editable directly from here"): Name and Username typed in place, the e-mail
/// shown. Nothing sends him to the website.
struct NativeProfilePersonalPage: View {
    var model: NativeCloudAccount = .shared
    enum Field: Equatable { case name, username }
    /// The username is typed in place when the account's profile answered and lets it change; otherwise it is text.
    static func usernameIsField(_ facts: NativeProfileFacts) -> Bool { facts.editable && facts.usernameCanChange }
    /// Pictures: a field drawn right after its value was saved.
    var fixtureSaved: Field? = nil
    @State private var saved: Field?
    @State private var usernameProblem: String?
    @State private var checkTimer: Task<Void, Never>?

    var body: some View {
        let facts = NativeProfileFacts.current(model)
        let shownCheck = saved ?? fixtureSaved
        DeckSettingsScaffold(title: "Personal information") {
            DeckSettingsGroup {
                DeckSettingsRow("Name") {
                    if facts.editable {
                        HStack(spacing: DeckTokens.Spacing.s8) {
                            NativeProfileSavedCheck(shown: shownCheck == .name)
                            NativeProfileNameField(model: model, alignment: .trailing, onSaved: { flash(.name) })
                                .modifier(NativeProfileQuietField())
                        }
                    } else {
                        Text(facts.name ?? "").foregroundStyle(.secondary)
                    }
                }
                if Self.usernameIsField(facts) {
                    DeckSettingsRow("Username") {
                        HStack(spacing: DeckTokens.Spacing.s8) {
                            NativeProfileSavedCheck(shown: shownCheck == .username)
                            NativeProfileUsernameField(current: facts.username ?? "", save: { await model.saveProfileUsername($0) },
                                                       onSaved: { flash(.username) }, onProblem: { usernameProblem = $0 })
                                .modifier(NativeProfileQuietField())
                        }
                    }
                } else if let username = facts.username {
                    // The account does not let it change now (it is in the address of his Store listings): plain text.
                    DeckSettingsRow("Username", state: "@" + username)
                }
                if let email = facts.email {
                    DeckSettingsRow("E-mail") { Text(email).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                }
                ForEach(facts.details) { row in DeckSettingsRow(row.label, state: row.value) }
            }
            if let problem = model.profileProblem ?? usernameProblem { DeckSettingsGroup { DeckSettingsProblem(text: problem) } }
        }
        .disabled(model.busy)
        .onAppear { model.refreshProfile() }
        .onDisappear { checkTimer?.cancel() }
    }

    private func flash(_ field: Field) {
        saved = field
        checkTimer?.cancel()
        checkTimer = Task {
            try? await Task.sleep(for: NativeProfileSavedCheck.shows)
            guard !Task.isCancelled else { return }
            saved = nil
        }
    }
}

/// "Disconnect" on a way to sign in, with the app's 5-second Undo (no sheet): the row says "Disconnecting…" with Undo,
/// then the way is removed once. Undo and leaving the page cancel it; nothing is saved, so it never fires later.
@MainActor @Observable
final class NativeSignInWayRemoval {
    nonisolated static let undoDelay: Duration = .seconds(5)
    static let pendingWord = "Disconnecting…"
    /// Rows waiting behind Undo, and rows whose removal is travelling (no Undo any more).
    private(set) var pending: Set<String> = []
    private(set) var removing: Set<String> = []
    /// The one sentence after a removal the account refused.
    private(set) var problem: String?
    private let wait: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started: [Task<Void, Never>] = []

    init(wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) { self.wait = wait }

    func choose(_ row: NativeProfileFacts.SignInRow, remove: @escaping @MainActor (NativeProfileFacts.SignInRow) async -> String?) {
        guard timers[row.id] == nil, !removing.contains(row.id) else { return }
        let id = row.id, wait = wait
        pending.insert(id); problem = nil
        let timer = Task { [weak self] in
            do { try await wait(Self.undoDelay) } catch { return }
            guard !Task.isCancelled, let self, self.pending.contains(id) else { return }
            self.pending.remove(id); self.timers[id] = nil
            self.removing.insert(id)
            let answer = await remove(row)
            self.removing.remove(id)
            self.problem = answer
        }
        timers[id] = timer
        started.append(timer)
    }
    func undo(_ id: String) {
        timers[id]?.cancel(); timers[id] = nil
        pending.remove(id)
    }
    func cancelAll() { for id in Array(pending) + Array(timers.keys) { undo(id) } }
    /// Tests: every chosen removal has finished or was cancelled.
    func settle() async { for task in started { await task.value } }
    /// Pictures: a row drawn while it waits behind Undo.
    func fixture(pending ids: Set<String>) { pending = ids }
}

/// Profile › Sign-in (owner, 18 Nov, item 26: "Sign-ins should be able to control here, not just look at them"): each
/// way he signs in with can be acted on in its row: Disconnect while another way remains, Connect when it is not
/// connected. Then Sign out on its own (the only red text on the page).
struct NativeProfileSignInPage: View {
    var model: NativeCloudAccount = .shared
    var fixtureRemoval: NativeSignInWayRemoval? = nil
    @State private var removal = NativeSignInWayRemoval()
    static let connected = "Connected"
    static let disconnect = "Disconnect"
    static let connect = "Connect"

    /// The ONE control at a row's right end.
    enum Control: Equatable { case undo, removing, disconnect, connected, connect }
    static func control(_ row: NativeProfileFacts.SignInRow, among rows: [NativeProfileFacts.SignInRow],
                        pending: Set<String>, removing: Set<String>) -> Control {
        if pending.contains(row.id) { return .undo }
        if removing.contains(row.id) { return .removing }
        guard row.connected else { return .connect }
        return canDisconnect(row, among: rows) ? .disconnect : .connected
    }
    /// A connected way can be disconnected while another connected way remains (the account refuses the last one), the
    /// account gave its handle, and the account does not say it may not be removed.
    static func canDisconnect(_ row: NativeProfileFacts.SignInRow, among rows: [NativeProfileFacts.SignInRow]) -> Bool {
        row.connected && row.wayID != nil && row.canRemove != false && rows.filter(\.connected).count > 1
    }

    var body: some View {
        let facts = NativeProfileFacts.current(model)
        let removal = fixtureRemoval ?? self.removal
        DeckSettingsScaffold(title: "Sign-in") {
            if !facts.signInRows.isEmpty {
                DeckSettingsGroup(separatorInset: DeckSettingsLook.rowPadding + DeckSettingsLook.rowTile + DeckTokens.Spacing.s8 + 2) {
                    ForEach(facts.signInRows) { row in
                        let control = Self.control(row, among: facts.signInRows, pending: removal.pending, removing: removal.removing)
                        DeckSettingsRow(row.title, subtitle: control == .undo || control == .removing ? NativeSignInWayRemoval.pendingWord : row.account) {
                            switch control {
                            case .undo: Button("Undo") { removal.undo(row.id) }.controlSize(.small)
                            case .removing: ProgressView().controlSize(.small)
                            case .disconnect:
                                Button(Self.disconnect) {
                                    removal.choose(row) { row in await model.removeSignInWay(row.wayID ?? "") }
                                }
                                .controlSize(.small)
                            case .connected: Text(Self.connected).foregroundStyle(.secondary)
                            // Adding a way is the account's own step in the browser (it signs him in at Google, GitHub or Apple).
                            case .connect: Button(Self.connect) { NativeProfileSettings.openURL(NativeProfileSettings.addWayPage) }.controlSize(.small)
                            }
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
            if let problem = removal.problem { DeckSettingsGroup { DeckSettingsProblem(text: problem) } }
            if let notice = model.notice { DeckSettingsGroup { DeckSettingsProblem(text: notice, warn: false) } }
        }
        .disabled(model.busy)
        .onAppear { model.refreshProfile() }
        .onDisappear { removal.cancelAll() }
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
