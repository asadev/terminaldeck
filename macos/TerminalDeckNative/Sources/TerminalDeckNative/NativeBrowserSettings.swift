import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Browser, drawn in Swift — `BrowserSection.tsx` one-to-one: Where
/// new tabs open (the start page, and taking one from a browser you already
/// use), Cookies and sign-ins (keep them between runs, import from another
/// browser, clear what was imported), Profiles, Saved passwords, What the
/// browser has kept; then the status line. Every control calls the engine
/// channel the page section calls.
struct NativeBrowserSettings: View {
    @State private var model = NativeBrowserSettingsModel()
    private let values = NativeSettingsValues.shared

    var body: some View {
        NativeSettingsPage(sectionId: "browser") {
            whereNewTabsOpen
            cookies
            if let notice = AppModel.shared.websiteMigrationNotice {
                Section("Saved website sign-ins") {
                    NativeCodingAINotice(tone: .info, text: notice)
                    Button("Try moving saved sign-ins again") { AppModel.shared.retryWebsiteMigration() }
                        .disabled(AppModel.shared.preparingSavedData)
                }
            }
            profiles
            passwords
            kept
            if let status = model.status {
                Section { NativeCodingAINotice(tone: .info, text: status) }
            }
        }
        .task { model.load() }
    }

    // MARK: Where new tabs open

    private var whereNewTabsOpen: some View {
        Section("Where new tabs open") {
            NativeSettingsList(section: "browser", omit: ["browser.persistSession"])
            NativeSettingsProse(text: "The browser uses Safari’s WebKit engine.")
        }
    }

    private var cookies: some View {
        Section("Cookies and sign-ins") {
            NativeSettingsList(section: "browser", omit: ["browser.startUrl"])
            NativeSettingsProse(text: "Sign in inside the browser. Each profile keeps its own Safari website data.")
        }
    }

    // MARK: Profiles

    private var profiles: some View {
        Section("Profiles") {
            NativeSettingsProse(text: "A profile is a separate set of logins and cookies. A site you sign into in one stays signed out in the others.")
            ForEach(model.profiles?.profiles ?? []) { profile in
                NativeBrowserSettingsProfileRow(profile: profile, model: model)
            }
            if let note = model.profileNote {
                NativeCodingAINotice(tone: .info, text: note)
            }
            if model.adding {
                HStack {
                    TextField("", text: $model.draft, prompt: Text("Work"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name for the new profile")
                        .onSubmit(model.createProfile)
                        .onExitCommand { model.adding = false }
                    Button("Add", action: model.createProfile).buttonStyle(.borderedProminent)
                    Button("Cancel") { model.adding = false }
                }
            } else {
                Button("Add a profile") { model.adding = true }
            }
            Text("One tab can also have its own, thrown away on quit — the tab’s **Shared / Isolated** switch. Switching reopens the page.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Saved passwords

    private var passwords: some View {
        Section("Saved passwords") {
            NativeSettingsProse(text: "Kept in this machine’s secure store, and offered back only on the site they came from. A page an agent opened is never filled in automatically — the browser offers the login on the page instead, and it goes in when you press it.")
            if let store = model.store, !store.path.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One file, encrypted with a key held in this machine’s login keychain: ")
                        + Text(store.path).font(.callout.monospaced())
                        + Text(". It holds the site, the username and the password of every saved login, in every profile, and nothing else.")
                    if store.exists {
                        Button("Show me the file", action: model.showFile)
                    }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            if let store = model.store, store.fault != .none {
                NativeCodingAINotice(tone: .warn, text: store.message)
            }
            if model.canStore == false {
                NativeCodingAINotice(tone: .warn, text: "This machine has no secure store available, so nothing can be saved here. Passwords are never written to a plain file instead.")
            }
            if let active = model.profiles?.active, let logins = model.logins, model.store?.fault != .tampered {
                NativeSettingsProse(text: BrowserSettings.savedSummary(logins.count, profileName: active.name))
            }
            ForEach(model.logins ?? []) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BrowserSettings.loginLabel(entry))
                        if entry.updatedAt > 0 {
                            Text("Saved \(BrowserSettings.whenImported(entry.updatedAt, now: Date().timeIntervalSince1970 * 1000))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // Copy, never Reveal: the engine writes the clipboard; the password never comes here.
                    Button("Copy") { model.copyLogin(entry) }
                        .help("Put this password on the clipboard. It is not shown here.")
                    Button("Forget", role: .destructive) { model.forgetLogin(entry) }
                }
            }
            if let note = model.loginNote {
                NativeCodingAINotice(tone: .info, text: note)
            }
            let faulted = model.store?.fault == .tampered
            if model.confirmForgetAll {
                NativeBrowserSettingsConfirm(text: BrowserSettings.forgetAllConfirm(model.loginTotal, faulted: faulted),
                                             yes: "Forget them all", no: "Keep them",
                                             onYes: model.forgetAllLogins, onNo: { model.confirmForgetAll = false })
            } else {
                Button("Forget all saved passwords", role: .destructive) { model.confirmForgetAll = true }
                    .disabled(model.loginTotal == 0 && !faulted)
                    .help(BrowserSettings.forgetAllHelp(model.loginTotal, faulted: faulted))
            }
        }
    }

    // MARK: What the browser has kept

    private var kept: some View {
        Section("What the browser has kept") {
            if let stored = model.stored {
                NativeSettingsProse(text: BrowserSettings.keptSummary(stored))
            }
            NativeSettingsProse(text: "Clearing signs you out of everything in the browser tab, and cannot be undone.")
            if model.confirmClear {
                NativeBrowserSettingsConfirm(text: "Clear cookies, storage and cache for the browser tab?",
                                             yes: "Clear it", no: "Keep it",
                                             onYes: model.clear, onNo: { model.confirmClear = false })
            } else {
                Button("Clear stored browsing data", role: .destructive) { model.confirmClear = true }
            }
        }
    }
}

/// One profile: its name and caption (or the rename form), In use / Use it,
/// Rename, Delete (not on the default one), and the delete confirmation.
private struct NativeBrowserSettingsProfileRow: View {
    let profile: BrowserSettingsProfile
    @Bindable var model: NativeBrowserSettingsModel

    var body: some View {
        let active = profile.id == model.profiles?.activeId
        VStack(alignment: .leading, spacing: 6) {
            if model.renaming?.id == profile.id {
                HStack {
                    TextField("", text: Binding(get: { model.renaming?.name ?? "" },
                                                    set: { model.renaming = (profile.id, $0) }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name for \(profile.name)")
                        .onSubmit { model.rename(profile.id) }
                        .onExitCommand { model.renaming = nil }
                    Button("Save") { model.rename(profile.id) }.buttonStyle(.borderedProminent)
                    Button("Cancel") { model.renaming = nil }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        let caption = BrowserSettings.profileCaption(profile, activeId: model.profiles?.activeId ?? "")
                        if !caption.isEmpty { Text(caption).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(active ? "In use" : "Use it") { model.activate(profile.id) }
                        .disabled(active)
                        .help(active ? "New tabs already open in this profile." : "New tabs will open in this profile.")
                    Button("Rename") { model.renaming = (profile.id, profile.name) }
                    if !profile.isDefault {
                        Button("Delete", role: .destructive) { model.confirmDelete = profile.id }
                            .help("Delete this profile and everything signed in inside it")
                    }
                }
            }
            if model.confirmDelete == profile.id {
                NativeBrowserSettingsConfirm(text: "Delete \(profile.name)? Everything signed in inside it is signed out, and this cannot be undone.",
                                             yes: "Delete it", no: "Keep it",
                                             onYes: { model.delete(profile.id) }, onNo: { model.confirmDelete = nil })
            }
        }
    }
}

/// `settings-confirm`: the question, the red answer, the way back.
struct NativeBrowserSettingsConfirm: View {
    let text: String
    let yes: String
    let no: String
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        HStack {
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(yes, role: .destructive, action: onYes)
            Button(no, action: onNo)
        }
    }
}

@MainActor
@Observable
final class NativeBrowserSettingsModel {
    var status: String?
    // Kept
    private(set) var stored: BrowserSettingsStored?
    var confirmClear = false
    // Profiles
    private(set) var profiles: BrowserSettingsProfiles?
    var renaming: (id: String, name: String)?
    var adding = false
    var draft = ""
    var confirmDelete: String?
    private(set) var profileNote: String?
    // Passwords
    private(set) var logins: [BrowserSettingsLogin]?
    private(set) var loginTotal = 0
    private(set) var canStore: Bool?
    private(set) var store: BrowserSettingsPasswordStore?
    var confirmForgetAll = false
    private(set) var loginNote: String?

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    private func said(_ error: Error, _ fallback: String) -> String {
        BrowserSettings.errorText((error as? EngineWireError)?.description ?? "", fallback: fallback)
    }

    func load() {
        refreshStored()
        loadProfiles()
        Task {
            if let raw = try? await call("browser-password:state") {
                store = BrowserSettings.passwordStore(raw)
                canStore = store?.available
            }
        }
    }

    // Kept

    func refreshStored() {
        Task { stored = (try? await call("browser-session:info")).map(BrowserSettings.stored) }
    }

    func clear() {
        confirmClear = false
        Task {
            do {
                status = BrowserSettings.clearMessage(try await call("settings:clear-browser-data"))
                refreshStored()
            } catch {
                status = said(error, "Could not clear the browsing data.")
            }
        }
    }

    // Profiles — every answer is the engine's new list, applied as it is.

    func loadProfiles() {
        Task {
            profiles = (try? await call("browser-profile:list")).flatMap(BrowserSettings.profiles)
            loadLogins()
        }
    }

    private func apply(_ raw: CodingAIJSON) -> BrowserSettingsProfiles? {
        guard let next = BrowserSettings.profiles(raw) else {
            loadProfiles()
            return nil
        }
        profiles = next
        loadLogins()
        return next
    }

    func activate(_ id: String) {
        profileNote = nil
        Task {
            do {
                let next = apply(try await call("browser-profile:activate", [id]))
                let name = next?.profiles.first { $0.id == id }?.name ?? "it"
                profileNote = "Pages opened from now on use \(name). A page already open keeps the one it started in."
            } catch {
                profileNote = said(error, "Could not switch profile.")
            }
        }
    }

    func createProfile() {
        let name = draft
        draft = ""
        adding = false
        profileNote = nil
        Task {
            do { _ = apply(try await call("browser-profile:create", [name])) } catch { profileNote = said(error, "Could not add that profile.") }
        }
    }

    func rename(_ id: String) {
        guard let name = renaming?.name else { return }
        renaming = nil
        profileNote = nil
        Task {
            do { _ = apply(try await call("browser-profile:rename", [id, name])) } catch { profileNote = said(error, "Could not rename that profile.") }
        }
    }

    func delete(_ id: String) {
        confirmDelete = nil
        profileNote = nil
        Task {
            do { _ = apply(try await call("browser-profile:delete", [id])) } catch { profileNote = said(error, "Could not delete that profile.") }
        }
    }

    // Passwords

    func loadLogins() {
        guard let state = profiles else { return }
        Task {
            logins = (try? await call("browser-password:list", [state.activeId])).map(BrowserSettings.logins) ?? []
            var total = 0
            for profile in state.profiles {
                total += ((try? await call("browser-password:list", [profile.id])).map(BrowserSettings.logins) ?? []).count
            }
            loginTotal = total
        }
    }

    func forgetLogin(_ entry: BrowserSettingsLogin) {
        loginNote = nil
        Task {
            do {
                _ = try await call("browser-password:forget", [entry.profileId, entry.origin, entry.username])
                loadLogins()
            } catch {
                loginNote = said(error, "Could not forget that login.")
            }
        }
    }

    func forgetAllLogins() {
        confirmForgetAll = false
        loginNote = nil
        Task {
            do {
                _ = try await call("browser-password:forget-all")
                loginNote = "Every saved password has been removed."
                if let raw = try? await call("browser-password:state") { store = BrowserSettings.passwordStore(raw) }
                loadLogins()
            } catch {
                loginNote = said(error, "Could not remove the saved passwords.")
            }
        }
    }

    func copyLogin(_ entry: BrowserSettingsLogin) {
        loginNote = nil
        Task {
            do {
                let done = try await call("browser-password:copy", [entry.profileId, entry.origin, entry.username])
                loginNote = done.bool == true ? "Copied to the clipboard." : "That login is no longer stored — the list has moved on."
            } catch {
                loginNote = said(error, "Could not copy that password.")
            }
        }
    }

    func showFile() {
        Task {
            do {
                let shown = try await call("browser-password:show-file")
                loginNote = shown.bool == true ? nil : "There is no file yet — nothing has been saved."
            } catch {
                loginNote = said(error, "Could not show the file.")
            }
        }
    }
}
