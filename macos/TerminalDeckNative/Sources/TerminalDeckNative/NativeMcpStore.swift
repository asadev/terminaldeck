import SwiftUI
import TerminalDeckNativeCore

// The Store's MCP servers department, drawn in SwiftUI (web: McpStore.tsx and
// McpStoreRow.tsx), for lane A's Store screen. The data and the words are
// `McpStoreModel.swift` in Core; the browsing parts are A's (NativeStoreParts.swift).
// Not scrollable itself: it sits in the Store screen's scroll view.

/// The MCP servers department: the filter bar, "Added by you", Installed, then one shelf per category.
struct NativeMcpStoreDepartment: View {
    @Binding var filter: StoreFilter
    /// The row shown on its own, by id ("" for the shelves): the page's `m:<id>` without the prefix.
    @Binding var detail: String
    let onRows: ([StoreFacets]) -> Void
    /// The folder a project scope is relative to (`PanelView`'s `projectPath`).
    let projectPath: String?
    /// What this computer is called, for the header's ⓘ.
    let here: String

    @State private var model = McpStoreModel()

    init(filter: Binding<StoreFilter>, detail: Binding<String>, onRows: @escaping ([StoreFacets]) -> Void,
         projectPath: String?, here: String = "This Mac") {
        _filter = filter
        _detail = detail
        self.onRows = onRows
        self.projectPath = projectPath
        self.here = here
    }

    /// The shelves, in order (`MCP_CATEGORY_ORDER` with their names), for the Store's rail.
    static let shelves: [(id: String, name: String)] = McpStoreCatalog.shelves

    /// Whether the department can be drawn: the engine that answers `mcp:store` is up.
    /// (The `mcp` feature itself is the Store screen's own check.)
    @MainActor static var wired: Bool { AppModel.shared.engineIsUp }

    var body: some View {
        let scopes = McpScopeChoice.choices(projectPath: projectPath)
        VStack(alignment: .leading, spacing: 12) {
            header(scopes)
            runtimes
            if !model.problem.isEmpty { McpErrorText(model.problem) }
            if model.loading, model.view.rows.isEmpty, model.problem.isEmpty {
                NativePageNote("Looking at what this machine can run…", busy: true)
                    .frame(minHeight: 120)
            }
            if !model.view.writerFound, !model.loading {
                Text("Claude Code’s command line tool is what writes this configuration, and it was not found on this machine. Nothing below can be installed until it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let open = model.view.rows.first(where: { $0.id == detail }) {
                StoreDetailView(backTo: McpStoreCatalog.shelfName(open.category) ?? "the store", onBack: { detail = "" }) {
                    McpStoreRowView(row: open, model: model, onOpen: nil,
                                    onEdit: open.custom ? {
                                        detail = ""
                                        model.edit(open)
                                    } : nil,
                                    onExport: open.custom ? { model.exportOne(open) } : nil)
                }
            } else {
                shelvesBody
            }
        }
        .onAppear {
            model.onRows = onRows
            model.start(projectPath: projectPath)
        }
        .onChange(of: projectPath) { _, next in model.start(projectPath: next) }
        .onChange(of: model.view) { _, view in onRows(view.rows.map(\.facets)) }
    }

    // MARK: head (StoreHeader)

    private func header(_ scopes: [McpScopeChoice]) -> some View {
        HStack(spacing: 10) {
            NativeCodingAIInfo(label: "Where these are installed",
                               text: "Install writes the server into your Claude Code configuration on \(here), through the same command line tool that owns that file. Nothing here is downloaded by this app: the server itself is fetched by npx, uvx or docker the first time a session starts it.")
            if scopes.count > 1 {
                Picker("Where an installed server is saved", selection: $model.scope) {
                    ForEach(scopes, id: \.value) { choice in
                        Text(choice.label).tag(choice.value).help(choice.help)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button(model.loading ? "Reading…" : "Reload") { model.load() }
                .disabled(model.loading)
        }
    }

    /// What was looked for on this machine and what was found — every "cannot run here" refers back to it.
    @ViewBuilder private var runtimes: some View {
        if !model.view.runtimes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.view.runtimes) { runtime in
                    HStack(spacing: 8) {
                        Text(runtime.binary).font(.caption.monospaced())
                        if runtime.found {
                            Text(runtime.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(runtime.path)
                        } else {
                            Text("not on this machine — needs \(runtime.needs)").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("environment").font(.caption.monospaced())
                    Text(model.view.environmentWords).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    // MARK: body (StoreBody)

    @ViewBuilder private var shelvesBody: some View {
        let shelving = McpStoreShelving(rows: model.view.rows, filter: filter)
        StoreFilterBarView(placeholder: "files, search, postgres, github…", search: false, filter: $filter,
                           controls: shelving.controls, showing: shelving.kept.count, total: model.view.rows.count,
                           active: shelving.filtering)

        // "Added by you": the first shelf, and the way in, so it is drawn whether or not it holds anything.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(McpStoreCatalog.shelfName("your-own") ?? "Added by you").font(.headline)
                NativeCodingAIInfo(label: "what you can add here",
                                   text: "Any MCP server at all — one you are writing, one from a README, one your team runs. It is written into the same configuration the catalogue rows are, through the same command line tool. This app measures one thing about it, which is whether the command it starts is on this machine, and claims nothing else.")
                if model.form == nil {
                    Spacer()
                    Button("Add your own tool…") { model.addOwn() }
                        .buttonStyle(.borderedProminent)
                    Button(model.busy == "own" ? "Reading…" : "Open a shared one…") { model.importOne() }
                        .disabled(model.busy == "own")
                }
            }
            if let form = model.form {
                McpAddFormView(projectPath: projectPath, mode: form.mode == .edit ? .edit : .add, start: form.start,
                               onSubmit: { try await model.submit(form, $0) },
                               onAdded: { model.added($0) },
                               onCancel: { model.form = nil })
                    .id(form.key)
            }
            if !model.saidOwn.isEmpty { McpSaid(text: model.saidOwn) }
            ForEach(shelving.own) { row in line(row) }
            if let hidden = shelving.ownHidden { McpStoreNote(hidden) }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))

        if !shelving.installed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Installed").font(.headline)
                McpStoreNote("Configured on this machine. Remove takes the line back out of the configuration.")
                ForEach(shelving.installed) { row in line(row) }
            }
        }

        if !shelving.shelves.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                McpStoreNote("Nothing here ships inside this app: Install writes the command on the row into your configuration, and npx, uvx or docker fetches the server itself the first time it runs.")
                NativeCodingAIInfo(label: "rows with no Install",
                                   text: "A row with no Install says which of two things is true of it — the runtime it needs is not on this machine, or a server of that name is already configured and is not this one. Those rows carry Get it, which opens the project’s own page in this app’s browser and installs nothing anywhere.")
            }
        }

        if let empty = shelving.emptyWords {
            Text(empty).font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(shelving.shelves) { shelf in
                VStack(alignment: .leading, spacing: 8) {
                    Text(shelf.name).font(.headline)
                    ForEach(shelf.rows) { row in line(row) }
                }
            }
        }
    }

    private func line(_ row: McpStoreRow) -> some View {
        McpStoreRowView(row: row, model: model,
                        onOpen: { detail = row.id },
                        onEdit: row.custom ? { model.edit(row) } : nil,
                        onExport: row.custom ? { model.exportOne(row) } : nil)
    }
}

// MARK: - The department's state (McpStore)

@MainActor @Observable
final class McpStoreModel {
    struct Form: Equatable {
        enum Mode { case add, edit }
        var mode: Mode
        var row: McpStoreRow?
        var start: McpFormStart?
        let key = UUID()
    }

    var view = McpStoreView()
    var problem = ""
    var loading = true
    var scope: McpAddScope = .user
    var form: Form?
    var saidOwn = ""
    var values: [String: [String: String]] = [:]
    var said: [String: String] = [:]
    var busy = ""
    var arming = ""
    var asking = ""
    @ObservationIgnored var onRows: (([StoreFacets]) -> Void)?
    @ObservationIgnored private var projectPath: String?
    @ObservationIgnored private var started = false

    private static let longCall: TimeInterval = 600

    func start(projectPath: String?) {
        guard !started || projectPath != self.projectPath else { return }
        started = true
        self.projectPath = projectPath
        // A scope the folder no longer offers falls back to the global one.
        if !McpScopeChoice.choices(projectPath: projectPath).contains(where: { $0.value == scope }) { scope = .user }
        load()
    }

    func load() {
        loading = true
        let path = projectPath
        Task {
            do {
                view = McpStoreView.from(try await EngineBridge.shared.invokeOrdered("mcp:store", [path], timeout: Self.longCall))
                problem = ""
            } catch {
                view = McpStoreView()
                let said = mcpMessage(error)
                problem = said.isEmpty ? "The catalogue could not be read." : said
            }
            loading = false
        }
    }

    func setValue(_ id: String, _ key: String, _ value: String) {
        values[id, default: [:]][key] = value
    }

    /// Install's ask, opened or closed; closing it forgets what was typed.
    func ask(_ id: String, _ on: Bool) {
        asking = on ? id : ""
        if !on { values[id] = nil }
    }

    func act(_ row: McpStoreRow) {
        let install = !row.removes
        busy = row.id
        arming = ""
        let path: Any = projectPath ?? NSNull()
        let request: [String: Any] = install
            ? ["id": row.id, "scope": scope.rawValue, "projectPath": path, "values": values[row.id] ?? [:]]
            : ["name": row.name, "scope": row.scope.isEmpty ? scope.rawValue : row.scope, "projectPath": path]
        Task {
            do {
                let raw = try await EngineBridge.shared.invokeOrdered(install ? "mcp:store-install" : "mcp:remove", [request],
                                                                      timeout: Self.longCall)
                let result = McpStoreResults.read(raw)
                said[row.id] = result.message
                if result.ok, install {
                    asking = ""
                    values[row.id] = nil
                }
            } catch {
                said[row.id] = mcpMessage(error)
            }
            busy = ""
            McpPageModel.forgetHeld()
            load()
        }
    }

    func addOwn() {
        saidOwn = ""
        form = Form(mode: .add, row: nil, start: nil)
    }

    func edit(_ row: McpStoreRow) {
        saidOwn = ""
        form = Form(mode: .edit, row: row,
                    start: McpFormStart.edit(name: row.name, scope: McpAddScope(rawValue: row.scope) ?? .user,
                                             transport: row.transport, command: row.command, envKeys: row.envKeys))
    }

    func importOne() {
        busy = "own"
        let scope = scope
        Task {
            do {
                let read = McpStoreResults.readImport(try await EngineBridge.shared.invokeOrdered("mcp:import", [], timeout: Self.longCall))
                saidOwn = read.result.message
                if read.result.ok, let draft = read.draft {
                    form = Form(mode: .add, row: nil,
                                start: McpFormStart.import(name: draft.name, transport: draft.transport, command: draft.command,
                                                           url: draft.url, env: draft.env, scope: scope))
                }
            } catch {
                let said = mcpMessage(error)
                saidOwn = said.isEmpty ? "That file could not be read." : said
            }
            busy = ""
        }
    }

    func exportOne(_ row: McpStoreRow) {
        busy = row.id
        let path: Any = projectPath ?? NSNull()
        Task {
            do {
                let raw = try await EngineBridge.shared.invokeOrdered("mcp:export", [row.name, row.scope.isEmpty ? "user" : row.scope, path],
                                                                      timeout: Self.longCall)
                let result = McpStoreResults.read(raw)
                if !result.message.isEmpty { said[row.id] = result.message }
            } catch {
                said[row.id] = mcpMessage(error)
            }
            busy = ""
        }
    }

    /// `submitEdit` / `submitAdd`.
    func submit(_ form: Form, _ request: [String: Any]) async throws -> McpAddResult {
        let path: Any = projectPath ?? NSNull()
        if form.mode == .edit, let row = form.row {
            let edit: [String: Any] = ["name": row.name, "scope": row.scope.isEmpty ? "user" : row.scope, "projectPath": path, "next": request]
            return McpStoreResults.read(try await EngineBridge.shared.invokeOrdered("mcp:edit", [edit], timeout: Self.longCall))
        }
        return McpStoreResults.read(try await EngineBridge.shared.invokeOrdered("mcp:add", [request], timeout: Self.longCall))
    }

    func added(_ message: String) {
        form = nil
        saidOwn = message
        McpPageModel.forgetHeld()
        load()
    }
}

// MARK: - One row (McpStoreRow)

private struct McpStoreRowView: View {
    let row: McpStoreRow
    @Bindable var model: McpStoreModel
    let onOpen: (() -> Void)?
    let onEdit: (() -> Void)?
    let onExport: (() -> Void)?
    @FocusState private var focused: String?

    private var busy: Bool { model.busy == row.id }
    private var arming: Bool { model.arming == row.id }
    private var asking: Bool { model.asking == row.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StoreLogoView(name: row.name, id: row.id, logo: row.logo.isEmpty ? nil : row.logo)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StoreRowNameView(name: row.name, onOpen: onOpen)
                    Spacer(minLength: 8)
                    controls
                }
                chips
                Text(row.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                (Text("Runs with ") + Text(row.runsWords).bold()
                    + (row.custom ? Text("") : Text(" · Needs ") + Text(row.needsWords).bold()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !row.costNote.isEmpty {
                    Text(row.costNote).font(.caption).foregroundStyle(.secondary)
                }
                StoreRowMoreView(label: "Source, package and the exact command") { facts }
                if !row.caveat.isEmpty {
                    Text(row.caveat).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !row.blocked.isEmpty, row.state != .installed {
                    Text(row.blocked).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !row.taken.isEmpty {
                    Text(row.taken).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).help(row.taken)
                }
                if row.asks, asking { askForm }
                if let said = model.said[row.id], !said.isEmpty { McpSaid(text: said) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            McpTag(text: row.sourceWords)
            McpTag(text: row.costLabel)
            if !row.licence.isEmpty { McpTag(text: row.licence) }
            if !row.version.isEmpty { Text(row.version).font(.caption.monospaced()).foregroundStyle(.secondary) }
            if row.state == .installed { Text(row.installedWords).font(.caption.weight(.medium)).foregroundStyle(.green) }
            if row.custom && row.runtimeMissing { McpTag(text: "Will not start here", kind: .warn) }
            if row.state == .unavailable { McpTag(text: "Cannot run here", kind: .warn) }
            if row.state == .taken { McpTag(text: "Name taken", kind: .scope) }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            if row.custom, !arming, let onEdit {
                Button("Edit", action: onEdit).disabled(busy)
            }
            if row.custom, !arming, let onExport {
                Button("Share", action: onExport).disabled(busy)
            }
            if row.hasAction, row.removes {
                if arming {
                    Button("Remove", role: .destructive) { model.act(row) }.disabled(busy)
                    Button("Keep") { model.arming = "" }
                } else {
                    Button(row.actionLabel(busy: busy)) { model.arming = row.id }.disabled(busy)
                }
            }
            if row.hasAction, !row.removes, !asking {
                Button(row.actionLabel(busy: busy)) {
                    if row.asks { model.ask(row.id, true) } else { model.act(row) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
            if !row.linkOut.isEmpty {
                StoreLinkOutView(url: row.linkOut, describes: "open the \(row.name) project")
            }
        }
        .fixedSize()
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            if !row.homepage.isEmpty { linkRow("Source", row.homepage) }
            if !row.registry.isEmpty { linkRow("Package", row.registry) }
            if let env = row.envWords {
                GridRow {
                    Text("Environment").foregroundStyle(.secondary)
                    Text(env)
                }
            }
            GridRow {
                Text(row.transport == .stdio ? "Command" : "URL").foregroundStyle(.secondary)
                Text(row.command).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .font(.caption)
    }

    @ViewBuilder private func linkRow(_ label: String, _ address: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            if let url = URL(string: address) {
                Link(address, destination: url).lineLimit(1).truncationMode(.middle)
            } else {
                Text(address)
            }
        }
    }

    private var askForm: some View {
        let missing = row.unfilled(model.values[row.id] ?? [:])
        return VStack(alignment: .leading, spacing: 10) {
            (Text(row.name).bold() + Text(String(row.askHead.dropFirst(row.name.count))))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(row.inputs) { input in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(input.label).font(.callout)
                        if input.required { Text("*").foregroundStyle(.red) }
                        if input.kind == .secret { McpTag(text: "secret") }
                        if input.showsKept { NativeCodingAIInfo(label: input.keptLabel, text: input.keptText) }
                    }
                    field(input)
                    if !input.hint.isEmpty {
                        Text(input.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !missing.isEmpty {
                Text("Needs \(missing.joined(separator: ", ")) before it can be installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(busy ? "Working…" : "Install") { model.act(row) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !missing.isEmpty)
                Button("Cancel") { model.ask(row.id, false) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.6)))
        // Focus follows the press, into the first box.
        .onAppear { focused = row.inputs.first?.key }
    }

    @ViewBuilder private func field(_ input: McpStoreInput) -> some View {
        let value = Binding(get: { model.values[row.id]?[input.key] ?? "" },
                            set: { model.setValue(row.id, input.key, $0) })
        Group {
            if input.kind == .secret {
                SecureField("", text: value, prompt: Text(input.placeholder))
            } else {
                TextField("", text: value, prompt: Text(input.placeholder))
                    .autocorrectionDisabled()
            }
        }
        .textFieldStyle(.roundedBorder)
        .focused($focused, equals: input.key)
    }
}

private struct McpStoreNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// What the last act on a row said (`.mcp-store-said`).
private struct McpSaid: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
