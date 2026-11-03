import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// M1 CORE · Deck Memory: the one store every lane reaches through `DeckMemory.ready()`.
extension NativeCompositionProduction {
    static let deckMemoryOwner = "native.deck-memory"

    /// Keep the Mac's view notifications downstream of the same events phones and tools hear.
    func installMemoryEvents() async throws {
        let registry = root.registry
        let feed = try await registry.subscribeAll(ownerID: BackendCompositionRoot.appOwnerID) { event in
            await MainActor.run {
                let center = NotificationCenter.default
                switch event.channel {
                case "job-flow:changed": center.post(name: .jobFlowChanged, object: nil)
                case "hoot:mention-delivery-ready": center.post(name: .hootMentionDeliveryReady, object: nil)
                case "hoot:mention-answered":
                    if let value = event.arguments.first, let answer = try? JSONDecoder().decode(BackendHootMentionAnswer.self, from: value.encodedJSON()) {
                        center.post(name: .hootMentionAnswered, object: nil, userInfo: ["answer": answer])
                    }
                case "deck-memory:handoff-presented":
                    guard event.arguments.count == 2, let owner = event.arguments[0].string, let id = event.arguments[1].string else { return }
                    center.post(name: .deckMemoryHandoffPresented, object: nil, userInfo: ["owner": owner, "id": id])
                case "deck-memory:changed":
                    guard event.arguments.count == 3, let area = event.arguments[0].string.flatMap(DeckMemoryChange.Area.init(rawValue:)) else { return }
                    let change = DeckMemoryChange(area: area, owner: event.arguments[1].string.flatMap(DeckMemoryOwner.init(key:)), ref: event.arguments[2].string)
                    center.post(name: .deckMemoryChanged, object: nil, userInfo: ["change": change])
                default: break
                }
            }
        }
        BackendMemoryEvents.shared.connect(registry)
        try await root.retain(.init(name: "memory-events", domains: ["memory-events"], ownerID: "native.memory-events", invokes: [],
            events: ["job-flow:changed", "hoot:mention-delivery-ready", "hoot:mention-answered", "deck-memory:handoff-presented", "deck-memory:changed"], stop: {
            BackendMemoryEvents.shared.connect(nil)
            await feed.cancelAndWait()
        }))
    }

    /// Opens the memory folder for this copy of the app ("Terminal Deck Memory", inside the app's own data folder for every
    /// build; an older install's ~/Terminal Deck Memory is moved there first) and makes it the app's store. Runs before any
    /// session starts. A failure is reported and leaves the rest of the app working; memory then stays "starting".
    func installDeckMemoryStore() async {
        guard !DeckMemory.isReady else { return }
        let report = self.report, root = self.root
        // A copy that does not own its data folder must not write into the memory that goes with it.
        guard root.state.ownership != .readOnly else {
            report("Memory is not open: another copy of the app owns this data folder."); return
        }
        do {
            // An older install kept memory in ~/Terminal Deck Memory: move it into the app's data folder first (off the main thread).
            let dataRoot = root.dataRoot
            if let moved = await Task.detached(priority: .userInitiated, operation: { DeckMemoryPaths.relocateLegacyHomeFolder(dataRoot: dataRoot) }).value {
                report(moved)
            }
            // Which model search by meaning uses, chosen off the main thread and said in the log, so a fallback is visible.
            let choice = await Task.detached(priority: .userInitiated) { await DeckMemoryEmbedders.choose() }.value
            report(choice.description)
            let store = try await DeckMemoryStore.open(dataRoot: root.dataRoot, embedder: choice.embedder)
            for line in await store.openingReport() { report(line) }
            let registry = root.registry
            await store.setOnRootChanged { DeckMemoryCenter.shared.noteRoot($0) }
            // Web and phone pages hear changes on a channel; native views use the notification.
            await store.setChangeForward { change in
                Task {
                    try? await registry.publish("deck-memory:changed", arguments: [.string(change.area.rawValue),
                        change.owner.map { .string($0.key) } ?? .null, change.ref.map(NativeRPCValue.string) ?? .null])
                }
            }
            let location = await store.location()
            DeckMemoryCenter.shared.install(store, root: location.root)
            await Self.bindHandoffPanel()
            if !location.isDefault, location.previousRoots.isEmpty {
                report("Memory is kept in \(location.root.path) because \(location.defaultRoot.path) already holds other things.")
            }
            do {
                try await root.retain(.init(name: "deck-memory", domains: ["deck-memory"], ownerID: Self.deckMemoryOwner, invokes: [], stop: {
                    DeckMemoryCenter.shared.uninstall()
                    await store.close()
                }))
            } catch { report("Memory is open but could not be registered for a clean shutdown: " + error.localizedDescription) }
            // Hoot's old notes come in as Hoot notes: copy only, the original stays. Every start picks up what is new there.
            Task(priority: .utility) {
                do {
                    let moved = try await store.migrateHootMemory()
                    if moved.imported + moved.updated > 0 {
                        report("Hoot's earlier notes were copied into memory: \(moved.imported) new, \(moved.updated) refreshed" + (moved.verified ? "." : "; some copies did not match and were left out."))
                    }
                } catch { report("Hoot's earlier notes could not be copied into memory: " + error.localizedDescription) }
            }
        } catch {
            report("Memory could not be opened: " + error.localizedDescription)
        }
    }

    /// The context handoff panel (L5's NativeHandoff.swift) reads and keeps its documents through the store, and
    /// opens when a seat's AI presents one with the `handoff.present` tool.
    @MainActor private static var handoffPanelBound = false
    @MainActor static func bindHandoffPanel() {
        NativeHandoffActions.load = { ownerKey, id in
            guard let found = try await DeckMemory.store.handoff(id: id), found.owner.key == ownerKey else {
                throw DeckMemoryError(.notFound, "That handoff is not in memory any more.")
            }
            return NativeHandoffDoc(found)
        }
        NativeHandoffActions.earlier = { ownerKey, topicID in
            guard let owner = DeckMemoryOwner(key: ownerKey) else { return [] }
            return try await DeckMemory.store.handoffs(owner, topic: topicID, includeArchived: false).map { NativeHandoffDoc($0) }
        }
        NativeHandoffActions.keep = { ownerKey, doc in
            // Already in memory: the person's edit replaces the text (the earlier text is kept). Not yet: it is saved with its topic.
            if try await DeckMemory.store.handoff(id: doc.id) != nil {
                return NativeHandoffDoc(try await DeckMemory.store.updateHandoff(id: doc.id, title: doc.title, markdown: doc.markdown))
            }
            guard let owner = DeckMemoryOwner(key: ownerKey) else { throw DeckMemoryError(.invalid, "That seat is not known to memory.") }
            return NativeHandoffDoc(try await DeckMemory.store.saveHandoff(.init(title: doc.title, markdown: doc.markdown, stamp: .init(owner: owner),
                                                                               topic: doc.topicID, author: .person)))
        }
        guard !handoffPanelBound else { return }
        handoffPanelBound = true
        NotificationCenter.default.addObserver(forName: .deckMemoryHandoffPresented, object: nil, queue: .main) { note in
            guard let owner = note.userInfo?["owner"] as? String, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated { NativeHandoffActions.presented(ownerKey: owner, id: id) }
        }
    }

    /// The memory tools (MEMORY-SPEC section 5), behind the same door, consent and action log as every other deck tool.
    /// Called with Hoot's other additive tools; a failure leaves those working.
    func installDeckMemoryTools(access: BackendDeckToolsAppAccess) async throws {
        let owner = DeckMemoryTools.ownerID
        let joins = self.joins, root = self.root
        let definitions = try DeckMemoryTools.definitions(access: access) + DeckMemoryProfileTools.definitions(access: access) // L5: the Memory area's own controls
        let policies = definitions.map { joins.nativePolicy($0) }
        let area = try BackendDeckToolsSupport.area(id: DeckMemoryTools.area, definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "deck-memory-tools", domains: ["deck-memory-tools"], ownerID: owner, invokes: [], stop: {
                await root.mcp.removeTools(ownerID: owner)
                try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            throw error
        }
    }
}

private extension NativeHandoffDoc {
    init(_ stored: DeckMemoryHandoff) {
        self.init(id: stored.id, topicID: stored.topic, title: stored.title, markdown: stored.markdown, createdAt: stored.createdAt, kept: true)
    }
}
