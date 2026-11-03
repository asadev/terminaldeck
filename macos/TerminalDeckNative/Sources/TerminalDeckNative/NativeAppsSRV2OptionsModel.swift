import Foundation
import Observation
import TerminalDeckNativeCore

/// SRV2: the app page's options (build, deploy steps, health check, address
/// options, storage) and its variables, for one app on one server. Edits stay
/// in drafts until that section's Save; every write goes through the engine's
/// approval-controlled SRV2 channels, exactly like NativeAppsModel's actions.
@MainActor
@Observable
final class NativeAppsSRV2OptionsModel {
    /// One part of the options, saved by its own Save button.
    enum Part: String, CaseIterable, Sendable { case build, steps, health, web, storage, variables }

    /// A storage item being edited. `uid` keeps rows stable while the path is typed.
    struct StorageDraft: Identifiable, Equatable {
        let uid = UUID()
        var mount: NativeAppsOptions.Mount
        var id: UUID { uid }
    }

    /// A variable as edited on the page. `replacement` nil keeps the saved value.
    struct VariableDraft: Identifiable, Equatable {
        var key: String
        var build: Bool
        var run: Bool
        var locked: Bool
        var replacement: String?
        var id: String { key }
    }

    /// The "Add a variable" fields.
    struct NewVariable: Equatable {
        var key = ""
        var value = ""
        var build = false
        var run = true
        var locked = true
        var isEmpty: Bool { key.isEmpty && value.isEmpty }
    }

    typealias Transport = @MainActor (String, [String: Any]) async throws -> NativeRPCValue

    let serverID: String
    let appID: String

    /// The options as last read from (or saved to) the server, in their public form.
    private(set) var saved: NativeAppsOptions?
    /// Editable copy of build, steps, health and web. Storage edits live in `storage`.
    var draft = NativeAppsOptions()
    var storage: [StorageDraft] = []
    /// A new password typed for password protection; sent once, then cleared.
    var newPassword = ""
    /// True while the person is replacing an existing password.
    var changingPassword = false

    private(set) var summary: [String] = []
    private(set) var variables: [NativeAppsVariable] = []
    var variableDrafts: [VariableDraft] = []
    var newVariable = NewVariable()
    private(set) var router: NativeAppsRouterInfo?
    private(set) var routerProblem: String?

    private(set) var loading = true
    private(set) var loadProblem: String?
    private(set) var variablesProblem: String?
    let changes = NativeAppsChangeRunner<Part>(problem: NativeAppsSRV2OptionsModel.problem(_:))
    var busy: String? { changes.busy }
    var resultPart: Part? { changes.resultPart }
    var note: String? { changes.note }
    var problem: String? { changes.problem }

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private var started = false
    @ObservationIgnored private var readTask: Task<Void, Never>?

    init(serverID: String, appID: String, transport: Transport? = nil) {
        self.serverID = serverID
        self.appID = appID
        self.transport = transport ?? { try await NativeAppsSRV2Engine.invoke($0, $1) }
    }

    // MARK: reading

    private func call(_ channel: String, _ additional: [String: Any] = [:]) async throws -> NativeRPCValue {
        var payload = additional
        payload["serverId"] = serverID
        if channel != "apps:router:read" { payload["appId"] = appID }
        return try await transport(channel, payload)
    }

    /// First visit only; Refresh reads again.
    func loadIfNeeded() {
        guard !started else { return }
        load()
    }

    func load() {
        started = true
        readTask?.cancel()
        let mine = changes.advance()
        loading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            // Three independent reads; a failed address-manager check never
            // hides the options, and failed variables never hide the rest.
            async let optionsRead = readOptions()
            async let variablesRead = readVariables()
            async let routerRead = readRouter()
            let (options, rows, info) = await (optionsRead, variablesRead, routerRead)
            guard !Task.isCancelled, changes.isCurrent(mine) else { return }
            switch options {
            case .success(let value):
                adopt(value.options)
                summary = value.summary
                loadProblem = nil
            case .failure(let error):
                loadProblem = Self.problem(error)
            }
            switch rows {
            case .success(let next): adoptVariables(next); variablesProblem = nil
            case .failure(let error): variablesProblem = Self.problem(error)
            }
            switch info {
            case .success(let next): router = next; routerProblem = nil
            case .failure:
                router = nil
                routerProblem = "This server’s address manager could not be checked. Your choices are checked again when you save."
            }
            loading = false
        }
    }

    private func readOptions() async -> Result<(options: NativeAppsOptions, summary: [String]), Error> {
        do {
            let reply = try await call("apps:options:read")
            return .success((try NativeAppsOptions.from(reply["options"]), Self.lines(reply["summary"])))
        } catch { return .failure(error) }
    }

    private func readVariables() async -> Result<[NativeAppsVariable], Error> {
        do { return .success(try NativeAppsVariable.rows(try await call("apps:variables:read"))) }
        catch { return .failure(error) }
    }

    private func readRouter() async -> Result<NativeAppsRouterInfo, Error> {
        do { return .success(try NativeAppsRouterInfo.from(try await call("apps:router:read"))) }
        catch { return .failure(error) }
    }

    /// Take the server's options. A part the person has not touched follows
    /// the server; a part with unsaved edits keeps them.
    private func adopt(_ next: NativeAppsOptions) {
        let previous = saved
        saved = next
        guard let previous else {
            draft = next
            storage = next.storage.map { StorageDraft(mount: $0) }
            draft.storage = []
            return
        }
        if draft.build == previous.build { draft.build = next.build }
        if draft.steps == previous.steps { draft.steps = next.steps }
        if draft.health == previous.health { draft.health = next.health }
        if draft.web == previous.web, newPassword.isEmpty, !changingPassword { draft.web = next.web }
        if storage.map(\.mount) == previous.storage { storage = next.storage.map { StorageDraft(mount: $0) } }
        draft.version = next.version
        draft.storage = []
    }

    private func adoptVariables(_ rows: [NativeAppsVariable]) {
        variables = rows
        variableDrafts = rows.map { VariableDraft(key: $0.key, build: $0.build, run: $0.run, locked: $0.locked, replacement: nil) }
    }

    // MARK: what changed

    func isChanged(_ part: Part) -> Bool {
        guard let saved else { return false }
        switch part {
        case .build: return draft.build != saved.build
        case .steps: return draft.steps != saved.steps
        case .health: return draft.health != saved.health
        case .web: return draft.web != saved.web || !newPassword.isEmpty
        case .storage: return storage.map(\.mount) != saved.storage
        case .variables: return !variableChanges.isEmpty || !newVariable.isEmpty
        }
    }

    func revert(_ part: Part) {
        guard let saved else { return }
        switch part {
        case .build: draft.build = saved.build
        case .steps: draft.steps = saved.steps
        case .health: draft.health = saved.health
        case .web: draft.web = saved.web; newPassword = ""; changingPassword = false
        case .storage: storage = saved.storage.map { StorageDraft(mount: $0) }
        case .variables: adoptVariables(variables); newVariable = NewVariable()
        }
        changes.clear(part)
    }

    /// The saved options with only this part's edits applied.
    func proposed(_ part: Part) -> NativeAppsOptions? {
        guard var next = saved else { return nil }
        switch part {
        case .build: next.build = draft.build
        case .steps: next.steps = draft.steps
        case .health: next.health = draft.health
        case .web:
            next.web = draft.web
            if let password = draft.web.password {
                next.web.password = .init(username: password.username.trimmingCharacters(in: .whitespaces),
                                          password: newPassword.isEmpty ? nil : newPassword)
            }
        case .storage: next.storage = storage.map(\.mount)
        case .variables: break
        }
        return next
    }

    /// Plain words for what blocks this part's Save, checked before sending.
    func validationMessage(_ part: Part) -> String? {
        if part == .variables { return variablesMessage }
        guard let next = proposed(part) else { return "The app’s saved options have not been read yet." }
        if part == .web, let password = next.web.password {
            let savedName = saved?.web.password?.username
            if password.password == nil, savedName == nil || savedName != password.username {
                return password.username.isEmpty ? "Enter a user name and a password." : "Enter a password for \(password.username)."
            }
        }
        do { try next.validate(); return nil }
        catch { return (error as? NativeRPCError)?.message ?? "Check the values you entered." }
    }

    // MARK: saving options

    func save(_ part: Part, writesDisabled: Bool = false) {
        if part == .variables { saveVariables(writesDisabled: writesDisabled); return }
        guard busy == nil, !writesDisabled, isChanged(part), let next = proposed(part) else { return }
        if let message = validationMessage(part) { changes.report(part, message); return }
        let payload: [String: Any]
        do {
            guard let object = try next.value().foundation as? [String: Any] else { throw NativeRPCError.malformed("These options could not be prepared.") }
            payload = object
        } catch { changes.report(part, Self.problem(error)); return }
        let mine = changes.generation
        changes.run(part, Self.savingLabel(part)) { [self] in
            let reply = try await call("apps:options:apply", ["options": payload])
            var options = try NativeAppsOptions.from(reply["options"])
            guard changes.isCurrent(mine) else { return nil }
            // The save reply leaves file text out (the server keeps it apart);
            // carry over the text that was just sent so editors don't empty.
            for index in options.storage.indices where options.storage[index].kind == .file && options.storage[index].content == nil {
                let path = options.storage[index].path
                options.storage[index].content = next.storage.first { $0.kind == .file && $0.path == path }?.content
            }
            // The saved part now matches the server; other parts keep their drafts.
            switch part {
            case .build: draft.build = options.build
            case .steps: draft.steps = options.steps
            case .health: draft.health = options.health
            case .web: draft.web = options.web; newPassword = ""; changingPassword = false
            case .storage: storage = options.storage.map { StorageDraft(mount: $0) }
            case .variables: break
            }
            adopt(options)
            summary = Self.lines(reply["summary"])
            return reply["note"].string ?? "Saved. The next deploy uses these settings."
        }
    }

    // MARK: variables

    /// Rows whose flags or value the person changed.
    var variableChanges: [VariableDraft] {
        variableDrafts.filter { row in
            guard let saved = variables.first(where: { $0.key == row.key }) else { return false }
            return row.build != saved.build || row.run != saved.run || row.locked != saved.locked || replacementValue(row) != nil
        }
    }

    /// A typed value that differs from the saved one; nil keeps the saved value.
    func replacementValue(_ row: VariableDraft) -> String? {
        guard let value = row.replacement, !value.isEmpty else { return nil }
        if let saved = variables.first(where: { $0.key == row.key }), !saved.locked, saved.value == value { return nil }
        return value
    }

    /// The text a replacement editor starts with: the value itself when it is
    /// shown on this page, nothing when it is locked.
    func startingReplacement(_ key: String) -> String {
        guard let saved = variables.first(where: { $0.key == key }), !saved.locked else { return "" }
        return saved.value
    }

    var variablesMessage: String? {
        for row in variableChanges {
            let value = replacementValue(row)
            let multiline = value.map { $0.contains("\n") } ?? (variables.first { $0.key == row.key }?.multiline ?? false)
            if let message = Self.variableProblem(key: row.key, value: value, multiline: multiline, build: row.build, run: row.run) { return message }
        }
        guard !newVariable.isEmpty else { return nil }
        let key = newVariable.key.trimmingCharacters(in: .whitespaces)
        guard NativeAppsVariable.validKey(key) else { return "Name the variable with letters, numbers and underscores, such as API_KEY." }
        guard !variables.contains(where: { $0.key == key }) else { return "\(key) already exists. Replace its value in the list above." }
        guard !newVariable.value.isEmpty else { return "Enter a value for \(key)." }
        return Self.variableProblem(key: key, value: newVariable.value, multiline: newVariable.value.contains("\n"),
                                    build: newVariable.build, run: newVariable.run)
    }

    static func variableProblem(key: String, value: String?, multiline: Bool, build: Bool, run: Bool) -> String? {
        if let value {
            guard !value.contains("\0"), value.utf8.count <= 48_000 else { return "Keep each value under 48 KB." }
            guard value != NativeAppsVariable.mask else { return "Enter the real value for \(key), not the hidden dots." }
        }
        guard build || run else { return "\(key) must be available during the build, while running, or both." }
        if build {
            guard !NativeAppsVariable.reservedForBuild(key) else { return "\(key) steers the server’s build tools, so it can’t be used during the build." }
            guard !multiline else { return "\(key) has more than one line, so it can’t be used during the build." }
        }
        return nil
    }

    private func saveVariables(writesDisabled: Bool) {
        guard busy == nil, !writesDisabled, isChanged(.variables) else { return }
        if let message = variablesMessage { changes.report(.variables, message); return }
        var set: [[String: Any]] = variableChanges.map { row in
            var item: [String: Any] = ["key": row.key, "build": row.build, "run": row.run, "locked": row.locked]
            if let value = replacementValue(row) { item["value"] = value }
            return item
        }
        if !newVariable.isEmpty {
            set.append(["key": newVariable.key.trimmingCharacters(in: .whitespaces), "value": newVariable.value,
                        "build": newVariable.build, "run": newVariable.run, "locked": newVariable.locked])
        }
        patchVariables(set: set, remove: [], label: "Saving variables")
    }

    func removeVariable(_ key: String, writesDisabled: Bool = false) {
        guard busy == nil, !writesDisabled, variables.contains(where: { $0.key == key }) else { return }
        patchVariables(set: [], remove: [key], label: "Removing \(key)")
    }

    private func patchVariables(set: [[String: Any]], remove: [String], label: String) {
        let mine = changes.generation
        changes.run(.variables, label) { [self] in
            let reply = try await call("apps:variables:patch", ["set": set, "remove": remove])
            let rows = try NativeAppsVariable.rows(reply["variables"])
            guard changes.isCurrent(mine) else { return nil }
            // Typed values are dropped as soon as the server has them.
            let pending = variableChanges.filter { row in !remove.contains(row.key) && !set.contains { ($0["key"] as? String) == row.key } }
            adoptVariables(rows)
            for row in pending {
                if let index = variableDrafts.firstIndex(where: { $0.key == row.key }) { variableDrafts[index] = row }
            }
            if set.contains(where: { ($0["key"] as? String) == newVariable.key.trimmingCharacters(in: .whitespaces) }) { newVariable = NewVariable() }
            variablesProblem = nil
            return reply["note"].string ?? "Saved. The next deploy uses these values."
        }
    }

    // MARK: storage

    func addStorage(_ kind: NativeAppsOptions.MountKind) {
        storage.append(StorageDraft(mount: .init(kind: kind, path: "", source: "", readOnly: false, content: kind == .file ? "" : nil)))
    }

    func removeStorage(_ id: UUID) {
        storage.removeAll { $0.id == id }
    }

    // MARK: words

    static func savingLabel(_ part: Part) -> String {
        switch part {
        case .build: "Saving build settings"
        case .steps: "Saving deploy steps"
        case .health: "Saving health check"
        case .web: "Saving address options"
        case .storage: "Saving storage"
        case .variables: "Saving variables"
        }
    }

    private static func lines(_ value: NativeRPCValue) -> [String] {
        (value.elements ?? []).compactMap(\.string).map { String($0.prefix(200)) }
    }

    /// The engine's own plain checks are shown as written; everything else uses
    /// the Apps screen's known safe copy (never raw server output).
    static func problem(_ error: Error) -> String {
        if let rpc = error as? NativeRPCError, rpc.code == "invalid-arguments",
           !rpc.message.isEmpty, rpc.message.count <= 300, !rpc.message.contains(where: \.isNewline) {
            return rpc.message
        }
        return NativeAppsContract.problem(error)
    }
}
