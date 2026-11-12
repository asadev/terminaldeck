import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The Store's "Browser extensions" department, drawn in Swift —
/// `BrowserStoreDepartment` + `StoreBody` (browser/StorePanel.tsx) with
/// `ExtensionRow` and `ToolRow`, one-to-one. Lane A's Store page embeds it:
///
///     NativeBrowserStoreDepartment(filter: $filter, detail: $detail, onRows: { … })
///     BrowserStore.shelves            // the department's shelves, in order
///     NativeBrowserStoreDepartment.isWired   // feature "browser" on
///
/// Order on the page: what an extension can and cannot do (folded), which
/// profile, the filter bar (no search box — the page has the one), Installed in
/// <profile>, the note above the shelves, the shelves (or why there are none),
/// Add your own, Built into this app, No longer offered, where the files are.
/// A row opened by its name is drawn alone on its own page (`detail` =
/// "e:<id>" or "t:<id>"). Channels: browser-extension:* and browser-store:*.
struct NativeBrowserStoreDepartment: View {
    @Binding var filter: StoreFilter
    @Binding var detail: String
    let onRows: ([StoreFacets]) -> Void
    @State private var model = NativeBrowserStoreModel()

    @MainActor static var isWired: Bool { BrowserStore.wired(featureState: NativeSettingsValues.shared.featureState) }

    var body: some View {
        Group {
            if !model.loaded {
                // The view must exist before the first read, or nothing starts it.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Browser tool").font(.headline)
                            Text("Read and collect information from the page.").font(.callout)
                        }
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            } else if let ext = model.ext.extensions.first(where: { "e:\($0.id)" == detail }) {
                StoreDetailView(backTo: "Browser extensions", onBack: { detail = "" }) {
                    NativeBrowserExtensionRow(extension: ext, model: model, onOpen: nil)
                        .disabled(model.extensionsLoading || !model.busy.isEmpty)
                }
            } else if let tool = model.tools.tools.first(where: { "t:\($0.id)" == detail }) {
                StoreDetailView(backTo: BrowserStore.builtInName, onBack: { detail = "" }) {
                    NativeBrowserToolRow(tool: tool, model: model, onOpen: nil)
                }
            } else {
                page(model)
            }
        }
        // An unstructured read: the Store keeps a hidden department at zero height,
        // where SwiftUI would cancel a `.task` before the answer lands.
        .onAppear { model.start(); onRows(model.facetRows) }
        .onChange(of: model.rowsKey) { onRows(model.facetRows) }
    }

    @ViewBuilder private func page(_ model: NativeBrowserStoreModel) -> some View {
        let tools = model.tools.tools.filter { StoreRules.matches(BrowserStore.facets($0), filter) }
        VStack(alignment: .leading, spacing: 20) {
            extensions(model)
            section(BrowserStore.builtInName) {
                if !model.toolsProblem.isEmpty {
                    Text(model.toolsProblem).foregroundStyle(.red)
                } else {
                    if tools.isEmpty { Text("No browser tools match this view.").foregroundStyle(.secondary) }
                    ForEach(tools) { tool in
                        NativeBrowserToolRow(tool: tool, model: model, onOpen: { detail = "t:\(tool.id)" })
                    }
                }
                if !model.tools.folder.isEmpty { note("Tool files: \(model.tools.folder)").textSelection(.enabled) }
            }
            if !model.tools.orphans.isEmpty {
                section("No longer offered") {
                    ForEach(model.tools.orphans, id: \.self) { id in
                        orphan(id, key: "t:\(id)", line: "This tool is no longer offered. Its saved file remains on disk.") {
                            model.actTool(id, verb: "remove")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func extensions(_ model: NativeBrowserStoreModel) -> some View {
        let ext = model.ext
        let rows = ext.extensions.filter { StoreRules.matches(BrowserStore.facets($0), filter) }
        section("Browser extensions") {
            if ext.profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { model.showing }, set: { model.show($0) })) {
                    ForEach(ext.profiles, id: \.id) { profile in Text(profile.name).tag(profile.id) }
                }.fixedSize().disabled(model.extensionsLoading || !model.busy.isEmpty)
            } else if !ext.profileName.isEmpty {
                Text("Profile: \(ext.profileName)").font(.callout).foregroundStyle(.secondary)
            }
            if !model.extProblem.isEmpty {
                Text(model.extProblem).foregroundStyle(.red)
                NativeSessionButton("Try again") { Task { await model.loadExtensions() } }
            } else if model.extensionsLoading {
                Text("Reading extensions…").redacted(reason: .placeholder)
            } else {
                if !ext.limits.isEmpty {
                    DisclosureGroup(BrowserStore.limitsSummary(ext.limits.count)) {
                        ForEach(ext.limits, id: \.self) { note($0) }
                    }
                }
                let installed = rows.filter(\.hasIt)
                if !installed.isEmpty {
                    section("Installed in \(ext.profileName.isEmpty ? "this profile" : ext.profileName)") {
                        ForEach(installed) { extensionRow($0) }
                    }
                }
                let available = rows.filter { !$0.hasIt }
                if available.isEmpty {
                    note(BrowserStore.emptyShelvesLine(kept: rows.count, filtering: filter != StoreFilter()))
                }
                ForEach(BrowserStore.categoryOrder, id: \.self) { category in
                    let shelf = available.filter { $0.category == category }
                    if !shelf.isEmpty {
                        section(BrowserStore.categoryNames[category] ?? category) {
                            ForEach(shelf) { extensionRow($0) }
                        }
                    }
                }
                if !ext.profileId.isEmpty { addYourOwn(ext) }
                if !ext.orphans.isEmpty {
                    section("No longer offered in this profile") {
                        ForEach(ext.orphans, id: \.self) { id in
                            orphan(id, key: "e:\(id)", line: "This extension is no longer offered. Its saved files remain on disk.") {
                                model.actExtension(id, verb: "remove")
                            }
                        }
                    }
                }
                if !ext.folder.isEmpty { note("Extension files: \(ext.folder)").textSelection(.enabled) }
            }
        }
    }

    private func extensionRow(_ one: BrowserStoreExtension) -> some View {
        NativeBrowserExtensionRow(extension: one, model: model, onOpen: { detail = "e:\(one.id)" })
            .disabled(model.extensionsLoading || !model.busy.isEmpty)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    @ViewBuilder private func addYourOwn(_ ext: BrowserStoreExtensionsView) -> some View {
        section("Add your own") {
            note("An extension you have on this machine — one you are writing, or one you got somewhere this app does not know about. It is copied into \(ext.profileName.isEmpty ? "this profile" : ext.profileName) and switched on. Nothing about it was measured here, no fingerprint is checked against it, and its row says exactly that instead of borrowing the confidence of the rows above.")
            HStack {
                NativeSessionButton(model.busy == "own:folder" ? "Working…" : "Add a folder…") { model.addOwn("folder") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.busy.isEmpty)
                NativeSessionButton(model.busy == "own:crx" ? "Working…" : "Add a .crx or a zip…") { model.addOwn("crx") }
                    .buttonStyle(.borderless)
                    .disabled(!model.busy.isEmpty)
            }
            note("A folder is the one with the manifest.json in it. A packed file is opened here rather than handed to the browser, and which kind it is comes from its own first four bytes rather than from its name — a zip is what most projects publish, and a .crx is what a browser exports. A .crx has its signature checked first, which proves the file has not changed since it was packed and proves nothing about who packed it, because a .crx carries its own key. A zip carries no signature at all, so there is nothing there to check and nothing is claimed.")
            Text("Each one you add gets a row of its own under Installed, with **Reload** — copy it in again from where it came from, after you rebuild — and **Rename**, for the name this app wrote down. Everything else about it is its own program: change that, and press Reload.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let said = model.said["own"], !said.isEmpty { Text(said).font(.callout) }
        }
    }

    private func orphan(_ id: String, key: String, line: String, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(id).fontWeight(.semibold)
                Spacer()
                NativeSessionButton(model.busy == key ? "Working…" : "Remove", action: remove)
                    .buttonStyle(.borderless)
                    .disabled(model.busy == key)
            }
            Text(line).font(.callout).foregroundStyle(.secondary)
            if let said = model.said[key], !said.isEmpty { Text(said).font(.callout) }
        }
    }
}

// MARK: - ExtensionRow

struct NativeBrowserExtensionRow: View {
    let `extension`: BrowserStoreExtension
    let model: NativeBrowserStoreModel
    let onOpen: (() -> Void)?

    var body: some View {
        let ext = `extension`
        let key = "e:\(ext.id)"
        let busy = model.busy == key
        let renaming = model.renaming == ext.id
        HStack(alignment: .top, spacing: 10) {
            StoreLogoView(name: ext.name, id: ext.id, logo: ext.logo)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StoreRowNameView(name: ext.name, onOpen: onOpen)
                    if !ext.version.isEmpty { Text(ext.version).font(.callout).foregroundStyle(.secondary) }
                    NativeCodingAIBadge(text: BrowserStore.costWords[ext.cost] ?? ext.cost)
                    if ext.sideloaded { NativeCodingAIBadge(text: "Added by you") }
                    Spacer(minLength: 8)
                    if ext.isInstalled && ext.enabled && !ext.popup.isEmpty {
                        NativeSessionButton("Open panel") { model.openPopup(ext.id) }.buttonStyle(.borderless)
                    }
                    if ext.isInstalled && ext.enabled && !ext.optionsPage.isEmpty {
                        NativeSessionButton("Open settings") { model.openOptions(ext.id) }.buttonStyle(.borderless)
                    }
                    if ext.sideloaded && ext.isInstalled && !renaming {
                        NativeSessionButton("Reload") { model.reload(ext.id) }.buttonStyle(.borderless).disabled(busy)
                        NativeSessionButton("Rename") { model.startRename(ext.id, name: ext.name) }.buttonStyle(.borderless).disabled(busy)
                    }
                    if ext.isInstalled {
                        Toggle("On", isOn: Binding(get: { ext.enabled }, set: { model.setEnabled(ext.id, $0) }))
                            .toggleStyle(.checkbox)
                            .disabled(busy)
                    }
                    let remove = BrowserStore.extensionVerb(ext) == "remove"
                    NativeSessionButton(BrowserStore.extensionActionLabel(ext, busy: busy)) { model.actExtension(ext.id, verb: BrowserStore.extensionVerb(ext)) }
                        .buttonStyle(remove ? AnyButtonStyle(.borderless) : AnyButtonStyle(.borderedProminent))
                        .disabled(busy)
                }
                if renaming {
                    HStack {
                        NativeSessionTextField(ext.name, text: Binding(get: { model.renameDraft }, set: { model.renameDraft = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("A name for \(ext.name)")
                            .disabled(busy)
                        NativeSessionButton(busy ? "Working…" : "Save") { model.rename(ext.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || model.renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        NativeSessionButton("Cancel") { model.renaming = "" }.disabled(busy)
                    }
                }
                Text(ext.summary).fixedSize(horizontal: false, vertical: true)
                Text("Reaches ") + Text(BrowserStore.reachWords(ext.reach, everywhere: ext.everywhere)).bold()
                if !ext.costNote.isEmpty { Text(ext.costNote).font(.callout) }
                StoreRowMoreView(label: "Licence, download, checksum and what was measured") {
                    VStack(alignment: .leading, spacing: 6) {
                        if !ext.mayAsk.isEmpty {
                            fact("Would like to reach", "\(ext.mayAsk.joined(separator: ", ")) — it can ask for this at any time and this browser always answers no, so it never gets it.")
                        }
                        if !ext.licence.isEmpty { fact("Licence", ext.licence) }
                        if !ext.homepage.isEmpty { fact("Project", ext.homepage) }
                        if ext.sideloaded && !ext.origin.isEmpty { fact("Added from", ext.origin, code: true) }
                        if ext.sideloaded && !ext.crxId.isEmpty {
                            fact("Signed as", "\(ext.crxId) — its signature matched its contents, which says the file has not changed since it was packed and says nothing at all about who packed it. That id is the fingerprint of the signing key.")
                        }
                        if !ext.url.isEmpty { fact("Download", ext.url + (ext.bytes > 0 ? BrowserStore.bytesExactly(ext.bytes) : "")) }
                        if !ext.url.isEmpty && !ext.sha256.isEmpty {
                            fact("sha256", ext.sha256 + (ext.hasIt ? " — the download matched this before it was unpacked." : " — the download must match this, or nothing is saved."))
                        }
                        if !ext.missing.isEmpty { fact("Not available here", ext.missing.map { "chrome.\($0)" }.joined(separator: ", ")) }
                        if !ext.provides.isEmpty { fact("Filled in by this app", ext.provides.map { "chrome.\($0)" }.joined(separator: ", ")) }
                        if !ext.inert.isEmpty { fact("Still not there", ext.inert.joined(separator: "; ")) }
                        Text(ext.measured).font(.callout)
                        if ext.isInstalled && ext.rulesetsSwitchedOn > 0 {
                            Text("This browser does not switch manifest declarativeNetRequest rulesets on when an extension loads. This app switched its \(ext.rulesetsSwitchedOn) on, once, after installing — and leaves them alone afterwards, so turning one off in the extension stays off.")
                                .font(.callout)
                        }
                    }
                    .textSelection(.enabled)
                }
                if ext.isInstalled && ext.rulesetsSwitchedOn == 0 && ext.staticRulesets {
                    Text("Its rules ship as manifest declarativeNetRequest rulesets that its own manifest leaves off, and this browser does not switch those on, so they are not in force.")
                        .foregroundStyle(.red)
                }
                if ext.state == "damaged" || (ext.isInstalled && !ext.message.isEmpty) {
                    Text(ext.message).foregroundStyle(.red)
                }
                if let said = model.said[key], !said.isEmpty { Text(said).font(.callout) }
            }
        }
        .padding(.vertical, 6)
    }

    private func fact(_ term: String, _ value: String, code: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(term).font(.caption).foregroundStyle(.secondary)
            Text(value).font(code ? .callout.monospaced() : .callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - ToolRow

struct NativeBrowserToolRow: View {
    let tool: BrowserStoreTool
    let model: NativeBrowserStoreModel
    let onOpen: (() -> Void)?

    var body: some View {
        let key = "t:\(tool.id)"
        let busy = model.busy == key
        let installed = tool.state == "installed"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StoreRowNameView(name: tool.name, onOpen: onOpen)
                Text(tool.version).font(.callout).foregroundStyle(.secondary)
                if installed { NativeCodingAIBadge(text: "Installed") }
                Spacer()
                let remove = BrowserStore.toolVerb(tool) == "remove"
                NativeSessionButton(BrowserStore.toolActionLabel(tool, busy: busy)) { model.actTool(tool.id, verb: BrowserStore.toolVerb(tool)) }
                    .buttonStyle(remove ? AnyButtonStyle(.borderless) : AnyButtonStyle(.borderedProminent))
                    .disabled(busy)
            }
            Text(tool.summary).fixedSize(horizontal: false, vertical: true)
            Text(BrowserStore.grantWords(tool.grants)).bold() + Text(" · Runs on ") + Text(BrowserStore.originWords(tool.origins)).bold()
            StoreRowMoreView(label: "Licence, source and checksum") {
                VStack(alignment: .leading, spacing: 6) {
                    fact("Licence", tool.licence)
                    fact("Source", tool.fetched ? tool.url : "Built into this app. Installing it downloads nothing — it ships in the app’s own bytes.")
                    if tool.fetched {
                        fact("sha256", tool.sha256 + (installed
                            ? " — the download matched this before it was saved, and is checked against it again every time it is read."
                            : " — the download must match this, or nothing is saved."))
                    }
                    if !tool.reads.isEmpty { fact("Collects", tool.reads.joined(separator: ", ")) }
                }
                .textSelection(.enabled)
            }
            if tool.state == "damaged" { Text(tool.message).foregroundStyle(.red) }
            if let said = model.said[key], !said.isEmpty { Text(said).font(.callout) }
        }
        .padding(.vertical, 6)
    }

    private func fact(_ term: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(term).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Two button looks behind one type, so a row can pick per state.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some PrimitiveButtonStyle) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - The model

@MainActor
@Observable
final class NativeBrowserStoreModel {
    private(set) var tools = BrowserStoreToolsView()
    private(set) var toolsProblem = ""
    private(set) var ext = BrowserStoreExtensionsView()
    private(set) var extProblem = ""
    private(set) var loaded = false
    private(set) var showing = ""
    private(set) var extensionsLoading = false
    @ObservationIgnored private var extensionTicket = 0
    @ObservationIgnored var invoke: @MainActor (String, [Any?]) async throws -> CodingAIJSON = { channel, args in
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }
    private(set) var said: [String: String] = [:]
    private(set) var busy = ""
    var renaming = ""
    var renameDraft = ""

    /// What the Store page counts and searches across departments (`onRows`).
    var facetRows: [StoreFacets] { ext.extensions.map(BrowserStore.facets) + tools.tools.map(BrowserStore.facets) }
    var rowsKey: [StoreFacets] { facetRows }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        try await invoke(channel, args)
    }

    private func sentence(_ error: Error, _ fallback: String) -> String {
        (error as? EngineWireError).map { BrowserSettings.errorText($0.description, fallback: fallback) } ?? fallback
    }

    @ObservationIgnored private var started = false

    /// Read once, outside any view's task.
    func start() {
        guard !started else { return }
        started = true
        Task { await load() }
    }

    func load() async {
        await loadTools()
        await loadExtensions()
        loaded = true
    }

    func loadTools() async {
        do {
            tools = BrowserStore.tools(try await call("browser-store:list"))
            toolsProblem = ""
        } catch {
            tools = BrowserStoreToolsView()
            toolsProblem = sentence(error, "The list could not be read.")
        }
    }

    func loadExtensions() async {
        extensionTicket += 1
        let ticket = extensionTicket
        extensionsLoading = true
        defer { if ticket == extensionTicket { extensionsLoading = false } }
        do {
            let view = BrowserStore.extensions(try await call("browser-extension:list", [showing]))
            guard ticket == extensionTicket else { return }
            ext = view
            if showing.isEmpty { showing = view.profileId }
            extProblem = ""
        } catch {
            guard ticket == extensionTicket else { return }
            ext = BrowserStoreExtensionsView()
            extProblem = sentence(error, "The list could not be read.")
        }
    }

    func show(_ profileId: String) {
        guard busy.isEmpty, !extensionsLoading else { return }
        showing = profileId
        extensionsLoading = true
        Task { await loadExtensions() }
    }

    /// One press on a row: busy while it runs, its sentence after, the list read again.
    private func act(_ key: String, _ channel: String, _ args: [Any?], fallback: String, reload: @escaping () async -> Void,
                     after: ((Bool) -> Void)? = nil) {
        busy = key
        Task {
            do {
                let result = BrowserStore.result(try await call(channel, args))
                said[key] = result.message
                after?(result.ok)
            } catch {
                said[key] = sentence(error, fallback)
            }
            busy = ""
            await reload()
        }
    }

    func actTool(_ id: String, verb: String) {
        act("t:\(id)", verb == "install" ? "browser-store:install" : "browser-store:remove", [id], fallback: "That did not work.") { [weak self] in
            await self?.loadTools()
        }
    }

    func actExtension(_ id: String, verb: String) {
        act("e:\(id)", verb == "install" ? "browser-extension:install" : "browser-extension:remove", [showing, id],
            fallback: "That did not work.") { [weak self] in await self?.loadExtensions() }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        act("e:\(id)", "browser-extension:enable", [showing, id, on], fallback: "That did not work.") { [weak self] in
            await self?.loadExtensions()
        }
    }

    func reload(_ id: String) {
        act("e:\(id)", "browser-extension:reload", [showing, id], fallback: "That did not work.") { [weak self] in
            await self?.loadExtensions()
        }
    }

    func startRename(_ id: String, name: String) {
        renaming = id
        renameDraft = name
    }

    func rename(_ id: String) {
        let name = renameDraft
        act("e:\(id)", "browser-extension:rename", [showing, id, name], fallback: "That did not work.",
            reload: { [weak self] in await self?.loadExtensions() }, after: { [weak self] ok in if ok { self?.renaming = "" } })
    }

    func addOwn(_ kind: String) {
        let key = "own:\(kind)"
        busy = key
        Task {
            do {
                said["own"] = BrowserStore.result(try await call(kind == "folder" ? "browser-extension:add-folder" : "browser-extension:add-crx", [showing])).message
            } catch {
                said["own"] = sentence(error, "That did not work.")
            }
            busy = ""
            await loadExtensions()
        }
    }

    /// Open panel / Open settings: a sentence only when it did not open.
    func openPopup(_ id: String) { open(id, "browser-extension:popup", fallback: "Its panel did not open.") }
    func openOptions(_ id: String) { open(id, "browser-extension:options", fallback: "Its settings did not open.") }

    private func open(_ id: String, _ channel: String, fallback: String) {
        Task {
            do {
                let result = BrowserStore.result(try await call(channel, [showing, id]))
                if !result.ok { said["e:\(id)"] = result.message }
            } catch {
                said["e:\(id)"] = sentence(error, fallback)
            }
        }
    }
}
