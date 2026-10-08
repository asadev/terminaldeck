import Foundation
import Observation
import TerminalDeckNativeCore

/// What the Receiver page shows over itself.
enum NativeRCVSheet: Identifiable {
    case addSource
    case reveal(RCVSecretReveal, help: String)
    case rule(RCVRule, isNew: Bool)
    case route(eventID: String)

    var id: String {
        switch self {
        case .addSource: "add-source"
        case .reveal(let reveal, _): "reveal:" + reveal.sourceId
        case .rule(let rule, _): "rule:" + rule.id
        case .route(let id): "route:" + id
        }
    }
}

/// The Receiver page's state. Same shape as AWAgentsWatchModel: one `read` closure
/// over `EngineBridge.shared.invoke`, the answers decoded into the Core RCV types,
/// and one subscription to `receiver:changed` while the page is on screen.
@MainActor @Observable
final class NativeRCVModel {
    typealias Read = @MainActor (String, [Any?]) async throws -> Any

    var overview: RCVOverview?
    var loading = true
    var error: String?
    var place: RCVPresentation.Place = .flow
    var query = ""
    var sourceFilter: String?
    var statusFilter: RCVStatus?
    /// Events from `receiver:events` while the flow is narrowed (it searches past the newest 200).
    var searched: [RCVEvent]?
    var selectedEventID: String?
    var openSourceID: String?
    var sheet: NativeRCVSheet?
    /// What is running, by name ("retry", "save-source" …), so its button can say so.
    var busy: String?
    var actionError: String?
    var actionNote: String?

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private let read: Read
    @ObservationIgnored private let sourceEvents: [String]

    init(sourceEvents: [String] = ["receiver:changed"],
         read: @escaping Read = { channel, args in try await EngineBridge.shared.invoke(channel, args) }) {
        self.sourceEvents = sourceEvents; self.read = read
    }

    // MARK: - Reading

    func start() {
        guard subscriptions.isEmpty else { return }
        for event in sourceEvents { subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in self?.refresh() }) }
        refresh()
    }

    func stop() {
        generation += 1; searchGeneration += 1
        loadTask?.cancel(); searchTask?.cancel(); loadTask = nil; searchTask = nil
        subscriptions.forEach { $0.cancel() }; subscriptions.removeAll()
    }

    func refresh() {
        generation += 1
        let mine = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.read("receiver:overview", [[String: Any]()])
                try Task.checkCancellation()
                guard self.generation == mine else { return }
                self.overview = try RCVPresentation.decode(RCVOverview.self, from: answer)
                self.loading = false; self.error = nil
                if self.narrowed { self.search() }
            } catch is CancellationError {
            } catch {
                guard self.generation == mine else { return }
                self.loading = false
                self.error = RCVPresentation.sentence(error)
            }
        }
    }

    /// The flow narrowed by words, source or status asks `receiver:events`, which reads
    /// every kept event; what the overview already holds shows at once meanwhile.
    func search() {
        searchGeneration += 1
        let mine = searchGeneration
        searchTask?.cancel()
        guard narrowed else { searched = nil; return }
        var request: [String: Any] = ["limit": 500]
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { request["query"] = words }
        if let sourceFilter { request["sourceId"] = sourceFilter }
        if let status = effectiveStatus { request["status"] = status.rawValue }
        let asked = request
        searchTask = Task { [weak self] in
            // A short pause so typing does not ask once per letter.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.searchGeneration == mine else { return }
            do {
                let answer = try await self.read("receiver:events", [asked])
                guard self.searchGeneration == mine else { return }
                self.searched = try RCVPresentation.decode([RCVEvent].self, from: answer)
            } catch {
                // The overview's own events still show; the search error is not worth a banner.
                guard self.searchGeneration == mine else { return }
                self.searched = nil
            }
        }
    }

    // MARK: - What the page shows

    var sources: [RCVSourceView] { RCVPresentation.sorted(overview?.sources ?? []) }
    var rules: [RCVRule] { overview?.rules ?? [] }
    var presets: [RCVPreset] { overview?.presets ?? RCVPresets.all }
    var effectiveStatus: RCVStatus? { place == .unrouted ? .unrouted : statusFilter }
    var narrowed: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceFilter != nil || effectiveStatus != nil
    }
    var visibleEvents: [RCVEvent] {
        let base = narrowed ? (searched ?? overview?.events ?? []) : (overview?.events ?? [])
        return RCVPresentation.filter(base, query: query, sourceID: sourceFilter, status: effectiveStatus, sources: overview?.sources ?? [])
    }
    var selectedEvent: RCVEvent? { event(selectedEventID) }

    func event(_ id: String?) -> RCVEvent? {
        guard let id else { return nil }
        return overview?.events.first { $0.id == id } ?? searched?.first { $0.id == id }
    }

    func sourceView(_ id: String?) -> RCVSourceView? {
        guard let id else { return nil }
        return overview?.sources.first { $0.id == id }
    }

    /// Recent events of one source, newest first (for learn, preview and the tester).
    func recentEvents(of sourceIDs: [String]) -> [RCVEvent] {
        let events = overview?.events ?? []
        let kept = events.filter { $0.status != .rejected }
        let picked = sourceIDs.isEmpty ? kept : kept.filter { sourceIDs.contains($0.sourceId) }
        return picked.sorted { $0.receivedAt > $1.receivedAt }
    }

    func go(_ next: RCVPresentation.Place) {
        place = next
        actionError = nil; actionNote = nil
        if next != .sources { openSourceID = nil }
        search()
    }

    func showEverything() {
        query = ""; sourceFilter = nil; statusFilter = nil
        if place == .unrouted { place = .flow }
        search()
    }

    func select(_ id: String?) {
        guard id != selectedEventID else { return }
        selectedEventID = id
        actionError = nil; actionNote = nil
    }

    func openSheet(_ next: NativeRCVSheet?) {
        actionError = nil
        sheet = next
    }

    // MARK: - Calling

    private func call(_ op: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        try await read("receiver:" + op, [arguments])
    }

    private func call<T: Decodable>(_ op: String, _ arguments: [String: Any] = [:], as type: T.Type) async throws -> T {
        try RCVPresentation.decode(type, from: try await call(op, arguments))
    }

    /// Runs one action: marks it busy, and turns any failure into one plain sentence.
    @discardableResult
    private func act<T>(_ label: String, _ work: () async throws -> T) async -> T? {
        busy = label; actionError = nil; actionNote = nil
        defer { busy = nil }
        do { return try await work() } catch {
            actionError = RCVPresentation.sentence(error)
            return nil
        }
    }

    private func upsert(_ event: RCVEvent) {
        if let index = overview?.events.firstIndex(where: { $0.id == event.id }) { overview?.events[index] = event }
        else { overview?.events.insert(event, at: 0) }
        if let index = searched?.firstIndex(where: { $0.id == event.id }) { searched?[index] = event }
    }

    private func upsert(_ view: RCVSourceView) {
        if let index = overview?.sources.firstIndex(where: { $0.id == view.id }) { overview?.sources[index] = view }
        else { overview?.sources.append(view) }
    }

    private func upsert(_ rule: RCVRule) {
        if let index = overview?.rules.firstIndex(where: { $0.id == rule.id }) { overview?.rules[index] = rule }
        else { overview?.rules.append(rule) }
    }

    // MARK: - Events

    func retry(_ id: String) async {
        if let event = await act("retry", { try await call("retry", ["id": id], as: RCVEvent.self) }) {
            upsert(event); actionNote = "Sent again."
        }
    }

    func replay(_ id: String) async {
        if let event = await act("replay", { try await call("replay", ["id": id], as: RCVEvent.self) }) {
            upsert(event)
            selectedEventID = event.id
            actionNote = "Ran through the rules again."
        }
    }

    func route(_ id: String, to target: RCVTarget, instruction: String) async {
        let done = await act("route") { () -> RCVEvent in
            var arguments: [String: Any] = ["id": id, "target": try RCVPresentation.foundation(target)]
            let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { arguments["instruction"] = words }
            return try await call("route", arguments, as: RCVEvent.self)
        }
        if let done { upsert(done); sheet = nil; actionNote = "Sent on." }
    }

    /// True when the reply went (or was put to the owner).
    func reply(_ id: String, text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        guard let event = await act("reply", { try await call("reply", ["id": id, "text": words], as: RCVEvent.self) }) else { return false }
        upsert(event)
        return true
    }

    func suggest(_ id: String) async {
        if let rule = await act("suggest", { try await call("suggest", ["id": id], as: RCVRule.self) }) {
            openSheet(.rule(RCVPresentation.fresh(rule), isNew: true))
        }
    }

    func askHoot(_ id: String) async {
        if await act("ask-hoot", { try await call("askHoot", ["id": id], as: RCVPresentation.TaskAnswer.self) }) != nil {
            actionNote = "Hoot is looking at it. Its answer arrives as a task."
        }
    }

    // MARK: - Sources

    /// Makes a source; the secret comes back once, for the add sheet to show.
    func createSource(preset: RCVPreset, name: String, auth: RCVAuth?) async -> RCVPresentation.Created? {
        let created = await act("create-source") { () -> RCVPresentation.Created in
            var arguments: [String: Any] = ["preset": preset.id, "name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
            if let auth { arguments["auth"] = try RCVPresentation.foundation(auth) }
            return try await call("sourceCreate", arguments, as: RCVPresentation.Created.self)
        }
        if let created { upsert(created.source) }
        return created
    }

    @discardableResult
    func saveSource(_ source: RCVSource) async -> Bool {
        let saved = await act("save-source") { () -> RCVSourceView in
            try await call("sourceSave", ["source": try RCVPresentation.foundation(source)], as: RCVSourceView.self)
        }
        if let saved { upsert(saved); actionNote = "Saved." }
        return saved != nil
    }

    func setEnabled(_ view: RCVSourceView, _ on: Bool) async {
        var source = view.source
        source.enabled = on
        await saveSource(source)
    }

    func deleteSource(_ id: String) async {
        if await act("delete-source", { try await call("sourceDelete", ["id": id]) }) != nil {
            overview?.sources.removeAll { $0.id == id }
            openSourceID = nil
            if sourceFilter == id { sourceFilter = nil }
        }
    }

    func revealSecret(_ id: String, replace: Bool) async {
        let op = replace ? "secretRotate" : "secretReveal"
        if let reveal = await act(replace ? "rotate" : "reveal", { try await call(op, ["id": id], as: RCVSecretReveal.self) }) {
            openSheet(.reveal(reveal, help: RCVPresentation.revealHelp(sourceView(id), presets: presets)))
            if replace { actionNote = "The secret was replaced. Paste the new one into the sender." }
        }
    }

    /// The sender's own secret (`secretSet`) in place of ours, for senders like Sentry.
    func setSecret(_ id: String, value: String) async -> RCVSecretReveal? {
        let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let reveal = await act("secret-set") { try await call("secretSet", ["id": id, "value": words], as: RCVSecretReveal.self) }
        if reveal != nil { actionNote = RCVPresentation.ownSecretSaved }
        return reveal
    }

    /// Stores the reply credential (never shown back); "" clears it.
    @discardableResult
    func setReplyCredential(_ id: String, value: String) async -> Bool {
        let saved = await act("reply-credential") { () -> RCVSourceView in
            try await call("replyCredential", ["id": id, "value": value], as: RCVSourceView.self)
        }
        if let saved { upsert(saved); actionNote = value.isEmpty ? "Reply key removed." : "Reply key saved." }
        return saved != nil
    }

    func learn(_ sourceID: String, eventID: String?) async -> RCVMapping? {
        await act("learn") { () -> RCVMapping in
            var arguments: [String: Any] = ["sourceId": sourceID]
            if let eventID { arguments["eventId"] = eventID }
            return try await call("learn", arguments, as: RCVMapping.self)
        }
    }

    func savePreset(_ sourceID: String, name: String) async {
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if let preset = await act("save-preset", { try await call("presetSave", ["sourceId": sourceID, "name": words], as: RCVPreset.self) }) {
            if overview?.presets.contains(where: { $0.id == preset.id }) == false { overview?.presets.append(preset) }
            actionNote = "Saved as the preset “\(preset.name)”. It is offered when you add a source."
        }
    }

    // MARK: - Rules

    @discardableResult
    func saveRule(_ rule: RCVRule) async -> Bool {
        let saved = await act("save-rule") { () -> RCVRule in
            try await call("ruleSave", ["rule": try RCVPresentation.foundation(rule)], as: RCVRule.self)
        }
        if let saved { upsert(saved); sheet = nil }
        return saved != nil
    }

    func setEnabled(_ rule: RCVRule, _ on: Bool) async {
        var copy = rule
        copy.enabled = on
        let saved = await act("save-rule") { () -> RCVRule in
            try await call("ruleSave", ["rule": try RCVPresentation.foundation(copy)], as: RCVRule.self)
        }
        if let saved { upsert(saved) }
    }

    func deleteRule(_ id: String) async {
        if await act("delete-rule", { try await call("ruleDelete", ["id": id]) }) != nil {
            overview?.rules.removeAll { $0.id == id }
            sheet = nil
        }
    }

    func moveRule(_ id: String, up: Bool) async {
        guard let index = RCVPresentation.moveIndex(id, up: up, in: rules) else { return }
        if let rules = await act("move-rule", { try await call("ruleMove", ["id": id, "index": index], as: [RCVRule].self) }) {
            overview?.rules = rules
        }
    }

    /// The dry run: the draft rule against a recent event or pasted sample JSON. Nothing is spent.
    func test(_ rule: RCVRule, eventID: String?, sourceID: String?, sample: String) async -> RCVPresentation.TestAnswer? {
        await act("test") { () -> RCVPresentation.TestAnswer in
            var arguments: [String: Any] = ["rule": try RCVPresentation.foundation(rule)]
            let pasted = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pasted.isEmpty {
                arguments["sample"] = pasted
                if let sourceID { arguments["sourceId"] = sourceID }
            } else if let eventID {
                arguments["eventId"] = eventID
            } else {
                throw NativeRPCError.invalidArguments("Nothing has arrived to test with yet. Paste a sample instead.")
            }
            return try await call("test", arguments, as: RCVPresentation.TestAnswer.self)
        }
    }
}
