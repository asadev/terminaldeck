import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Fix 0606 send and history", .serialized)
struct Fix0606SendHistoryTests {
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        let provider: String
        let team: Bool
        init(provider: String, team: Bool) { self.provider = provider; self.team = team }
        var sent: [String] { lock.withLock { calls } }
        func reply(_ method: String, _ payload: Data) throws -> Data {
            if method == "chats.say" || method == "chats.steer" {
                try BackendHOSTChats.validateDeliveryIdentity(method, payload: payload)
                lock.withLock { calls.append(method) }
            }
            if method == "chats.inventory" {
                return try NativeRPCValue.object([.init("jobs", .array([])), .init("sessions", .array([.object([.init("id", .string("earlier"))])]))]).encodedJSON()
            }
            return try NativeRPCValue.object([.init("provider", .string(provider)), .init("busy", .bool(true)),
                .init("foreground", .bool(false)), .init("alive", .bool(true)), .init("events", .array([])),
                .init("job", team ? .object([]) : .null)]).encodedJSON()
        }
    }
    @Test func ordinaryEarlierSendsNeverEnterMigrationForAnyAIOrTeam() async throws {
        for provider in ["claude", "codex", "gemini"] {
            for team in [false, true] {
                let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("f606-" + String(UUID().uuidString.prefix(8)))
                defer { try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let paths = try BackendHOSTPaths(dataDirectory: root)
                _ = try paths.secret(create: true)
                let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
                let wire = Wire(provider: provider, team: team)
                let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture", manager: manager,
                    launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {},
                    resource: { try wire.reply($0, $1) }, chatUpdates: { AsyncStream { _ in } })
                let client = try BackendHOSTClient(paths: paths)
                let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in }, modelCatalogue: { .object([]) })
                do {
                    try await chats.useHost(client)
                    await chats.setEarlierEngineMove { _ in throw NativeRPCError(code: "test", message: "Sending entered the move") }
                    _ = try await chats.say("earlier", text: "ordinary message")
                    _ = try await chats.steer("earlier", text: "send now")
                    #expect(wire.sent == ["chats.say", "chats.say"])
                    client.detach(); server.stopListening()
                } catch { client.detach(); server.stopListening(); throw error }
            }
        }
    }
    @Test func watcherBusyDoesNotOverrideAnIdleTurnReceipt() {
        let snapshot = NativeRPCValue.object([.init("alive", .bool(true)), .init("busy", .bool(true)), .init("foreground", .bool(false))])
        #expect(!BackendHootChatStore.foreground(in: snapshot))
        #expect(BackendHootChatStore.foreground(in: snapshot.setting("foreground", .bool(true))))
    }
    @Test func geminiAndEarlierJobsOfferHistoryForkWithoutRewindOrNotice() {
        for provider in [HootChatProvider.claude, .codex, .gemini] {
            let event = HootChatEvent(conversationID: "source", turnID: "turn", sequence: 1, provider: provider, record: .text(.user, id: "user", "old words"))
            let snapshot = NativeRPCValue.object([.init("provider", .string(provider.rawValue)), .init("readOnly", .bool(true)),
                .init("job", .object([])), .init("events", .array([event.wireValue]))])
            let offered = BackendEarlierChatMove.offeringActions(snapshot)
            #expect(offered["messageActions"].elements?.first?["fork"].bool == true)
            #expect(offered["messageActions"].elements?.first?["rewind"].bool == false)
            #expect(offered["notice"].isNullish)
        }
    }
    @Test func phonesReceiveOnlyTheMatchingMessageActions() {
        let event = NativeRPCValue.object([.init("sequence", .number(8)), .init("value", .object([]))])
        let action = NativeRPCValue.object([.init("sequence", .number(8)), .init("rewind", .bool(false)), .init("fork", .bool(true))])
        let matched = BackendChatMessageActions.phoneEvent(event, actions: [action])
        #expect(matched["value"]["historyActions"]["fork"].bool == true)
        #expect(matched["value"]["historyActions"]["rewind"].bool == false)
        #expect(BackendChatMessageActions.phoneEvent(event.setting("sequence", .number(9)), actions: [action])["value"]["historyActions"]["fork"].bool == false)
    }
    @Test func historySeedCopiesMediaAndNeverReusesProviderIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("f606-seed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("parent/chat-gemini.json")
        let source = try BackendHootChatStore(file: file, provider: .gemini, retainAllHistory: true)
        let events = [HootChatEvent(conversationID: "source", turnID: "turn", sequence: 1, provider: .gemini, record: .text(.user, id: "u", "old prompt")),
                      HootChatEvent(conversationID: "source", turnID: "turn", sequence: 2, provider: .gemini, record: .text(.message, id: "a", "old answer"))]
        try await source.seedForkHistory(events)
        let before = try Data(contentsOf: file)
        let media = file.deletingLastPathComponent().appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: media.appendingPathComponent("fixture.bin"))
        let childFile = root.appendingPathComponent("child/chat-gemini.json")
        let target = try BackendHootChatStore(file: childFile, provider: .gemini, retainAllHistory: true)
        try await target.seedHootForkHistory(events, mediaFrom: file)
        let snapshot = await target.snapshot()
        #expect(snapshot["providerConversationId"].isNullish)
        #expect(snapshot["events"].elements?.count == 2)
        #expect(await target.handoverPending)
        #expect(try Data(contentsOf: file) == before)
        #expect(try Data(contentsOf: childFile.deletingLastPathComponent().appendingPathComponent("media/fixture.bin")) == Data([1, 2, 3]))
    }
}

extension Fix0606SendHistoryTests {
    @Test func oversizedHistoryDoesNotAdvertiseASeedThatWouldTruncate() {
        let long = HootChatEvent(conversationID: "chat", turnID: "turn", sequence: 1, provider: .gemini,
            record: .text(.user, id: "user", String(repeating: "x", count: 12_001)))
        #expect(BackendChatMessageActions.historyRows([long]).first?["fork"].bool == false)
        #expect(BackendChatMessageActions.rows([long], provider: .gemini).first?["fork"].bool == false)
        let missing = HootChatEvent(conversationID: "chat", turnID: "turn", sequence: 500, provider: .gemini, record: .text(.message, id: "answer", "tail only"))
        #expect(BackendChatMessageActions.historyRows([missing]).first?["fork"].bool == false)
    }
    @Test func fullHistoryPrefixDoesNotDropOlderPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("f606-pages-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat-gemini.json"), provider: .gemini, retainAllHistory: true)
        let events = (1...600).map { i in
            HootChatEvent(conversationID: "chat", turnID: "turn", sequence: i, provider: .gemini,
                record: i == 1 ? .text(.user, id: "user", "first prompt") : i == 600 ? .text(.message, id: "answer", "last answer") : .init(.toolResult, id: "tool-\(i)", value: .object([])))
        }
        try await store.seedForkHistory(events)
        #expect(try await store.carriedHistoryPrefix(through: 600).count == 600)
        #expect(try await store.carriedHistoryPrefix(through: 1).count == 1)
    }
}

extension Fix0606SendHistoryTests {
    private actor SendBarrier {
        private var entered = false
        private var started: CheckedContinuation<Void, Never>?
        private var sending: CheckedContinuation<Void, Never>?
        var moves = 0
        private var reads = 0
        func firstRead() -> Bool { reads += 1; return reads == 1 }
        func hold() async {
            entered = true; started?.resume(); started = nil
            await withCheckedContinuation { sending = $0 }
        }
        func waitForSend() async {
            if entered { return }
            await withCheckedContinuation { started = $0 }
        }
        func release() { sending?.resume(); sending = nil }
        func moved() { moves += 1 }
    }
    @Test func migrationCannotCloseAnEarlierWriterAwaitingSendReceipt() async throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("f606-race-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let wire = Wire(provider: "codex", team: false), gate = SendBarrier()
        let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {},
            resource: { method, payload in
                if method == "chats.say" { await gate.hold() }
                let bytes = try wire.reply(method, payload)
                if method == "chats.read" { return try NativeRPCValue.parseJSON(bytes).setting("busy", .bool(false)).setting("providerConversationId", .string("original")).encodedJSON() }
                return bytes
            }, chatUpdates: { AsyncStream { _ in } })
        let client = try BackendHOSTClient(paths: paths)
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in }, modelCatalogue: { .object([]) })
        do {
            try await chats.useHost(client)
            await chats.setEarlierEngineMove { _ in await gate.moved() }
            let send = Task { try await chats.say("earlier", text: "keep this message") }
            await gate.waitForSend()
            do { _ = try await chats.rewind("earlier", sequence: 1) } catch {}
            await gate.release()
            _ = try await send.value
            #expect(await gate.moves == 0)
            client.detach(); server.stopListening()
        } catch { await gate.release(); client.detach(); server.stopListening(); throw error }
    }
}

extension Fix0606SendHistoryTests {
    @Test func shortMarkdownImagesRequestTheMacResolverWithoutClippingText() {
        let text = "Picture ![local](plot.png) and ![http](http://localhost:8080/plot.png)"
        let event = HootChatEvent(conversationID: "chat", turnID: "turn", sequence: 2, provider: .gemini,
            record: .text(.message, id: "answer", text)).wireValue
        let frame = ChatRenderedContent.phoneEvent(event)
        #expect(frame["value"]["text"].string == text)
        #expect(frame["value"]["richSource"]["revision"].number == 2)
        let code = event.setting("value", .object([.init("text", .string("`![not an image](plot.png)`"))]))
        #expect(ChatRenderedContent.phoneEvent(code)["value"]["richSource"].isNullish)
    }
}

extension Fix0606SendHistoryTests {
    @Test func historyClaimPrecedesItsFirstAwaitAndKeepsConcurrentSendUnsent() async throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("f606-lock-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let wire = Wire(provider: "codex", team: false), gate = SendBarrier()
        let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {},
            resource: { method, payload in
                if method == "chats.read", await gate.firstRead() { await gate.hold() }
                let bytes = try wire.reply(method, payload)
                return method == "chats.read" ? try NativeRPCValue.parseJSON(bytes).setting("busy", .bool(false)).encodedJSON() : bytes
            }, chatUpdates: { AsyncStream { _ in } })
        let client = try BackendHOSTClient(paths: paths)
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in }, modelCatalogue: { .object([]) })
        do {
            try await chats.useHost(client)
            await chats.setEarlierEngineMove { _ in await gate.moved() }
            let moving = Task { do { _ = try await chats.rewind("earlier", sequence: 1) } catch {} }
            await gate.waitForSend()
            do { _ = try await chats.say("earlier", text: "keep this unsent"); Issue.record("A send entered during the history read") }
            catch { #expect(error.localizedDescription.contains("history action")) }
            await gate.release(); await moving.value
            #expect(wire.sent.isEmpty)
            client.detach(); server.stopListening()
        } catch { await gate.release(); client.detach(); server.stopListening(); throw error }
    }
}

extension Fix0606SendHistoryTests {
    @Test func adoptedTeamForkCarriesItsVisibleBriefAndAnswerInsteadOfHidingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("f606-team-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.json")
        let source = try BackendHootChatStore(file: file, provider: .codex, retainAllHistory: true)
        let raw = [HootChatEvent(conversationID: "job", turnID: "bg:task:one", sequence: 1, provider: .codex,
            record: .init(.session, value: .object([.init("background", .object([.init("brief", .string("Retain this team brief"))]))]))),
            HootChatEvent(conversationID: "job", turnID: "bg:task:one", sequence: 2, provider: .codex, record: .text(.message, id: "answer", "Retain this team answer"))]
        try await source.seedForkHistory(raw)
        let before = try Data(contentsOf: file)
        let prefix = try await source.carriedJobHistoryPrefix(through: 2)
        #expect(prefix.first?.record.kind == .user)
        #expect(prefix.allSatisfy { $0.turnID.hasPrefix("task:") })
        let child = try BackendHootChatStore(file: root.appendingPathComponent("child.json"), provider: .codex, retainAllHistory: true)
        try await child.seedHootForkHistory(prefix)
        let carried = await child.recentMessages(limit: 400)
        #expect(carried.map(\.text) == ["Retain this team brief", "Retain this team answer"])
        #expect(await source.carriedJobHistoryActionRows.first?["fork"].bool == true)
        #expect(try Data(contentsOf: file) == before)
    }
}

extension Fix0606SendHistoryTests {
    @Test func missingRecordedAccountDoesNotAdvertiseAnUnsafeEarlierFork() {
        let event = HootChatEvent(conversationID: "chat", turnID: "turn", sequence: 1, provider: .gemini, record: .text(.user, "saved words")).wireValue
        let snapshot = NativeRPCValue.object([.init("provider", .string("gemini")), .init("events", .array([event])), .init("historyAccountConfirmed", .bool(false))])
        let actions = BackendEarlierChatMove.offeringActions(snapshot)["messageActions"].elements ?? []
        #expect(actions.count == 1)
        #expect(actions.allSatisfy { $0["fork"].bool == false && $0["rewind"].bool == false })
    }
}

extension Fix0606SendHistoryTests {
    @Test func hootPhoneRowsCarryTheStoresOwnMessageActions() throws {
        let events = [HootChatEvent(conversationID: "hoot", turnID: "t1", sequence: 1, provider: .codex, record: .text(.user, id: "u", "steered words")).wireValue,
                      HootChatEvent(conversationID: "hoot", turnID: "t1", sequence: 2, provider: .codex, record: .text(.message, id: "m", "answer")).wireValue]
        let actions = NativeRPCValue.array([.object([.init("sequence", .number(1)), .init("rewind", .bool(false)), .init("fork", .bool(false))]),
                                            .object([.init("sequence", .number(2)), .init("rewind", .bool(false)), .init("fork", .bool(true))])])
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("hoot")), .init("events", .array(events)), .init("messageActions", actions)])
        let rows = try BackendINT2HootPhone.page(snapshot, before: nil).value["events"].elements ?? []
        #expect(rows.count == 2)
        #expect(rows.map { $0["value"]["historyActions"]["rewind"].bool } == [false, false])
        #expect(rows.map { $0["value"]["historyActions"]["fork"].bool } == [false, true])
        let none = try BackendINT2HootPhone.page(snapshot.setting("messageActions", .null), before: nil).value["events"].elements ?? []
        #expect(!none.isEmpty && none.allSatisfy { $0["value"]["historyActions"]["fork"].bool == false && $0["value"]["historyActions"]["rewind"].bool == false })
    }
    @Test func longEarlierChatsOfferForkFromTheWholeJournalNotOnePage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("f606b-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var raw = [HootChatEvent(conversationID: "long", turnID: "turn", sequence: 1, provider: .gemini, record: .text(.user, id: "ask", "First question"))]
        raw += (2..<600).map { HootChatEvent(conversationID: "long", turnID: "turn", sequence: $0, provider: .gemini,
            record: .init(.toolCall, id: "tool-\($0)", value: .object([.init("name", .string("read"))]))) }
        raw.append(HootChatEvent(conversationID: "long", turnID: "turn", sequence: 600, provider: .gemini, record: .text(.message, id: "answer", "Final answer")))
        let file = root.appendingPathComponent("long.json")
        try await BackendHootChatStore(file: file, provider: .gemini, retainAllHistory: true).seedForkHistory(raw)
        // The UI reads the newest 500 events: this page does not hold sequence 1.
        let page = NativeRPCValue.object([.init("provider", .string("gemini")), .init("events", .array(raw.suffix(500).map(\.wireValue)))])
        #expect(BackendEarlierChatMove.offersCarriedHistory(page))
        let fromPage = BackendEarlierChatMove.offeringActions(page)["messageActions"].elements ?? []
        #expect(fromPage.count == 1 && fromPage.first?["fork"].bool == false)
        let journal = try BackendHootChatStore(file: file, provider: .gemini, retainAllHistory: true)
        let offered = BackendEarlierChatMove.offeringActions(page, journalRows: await journal.carriedHistoryActionRows)["messageActions"].elements ?? []
        #expect(offered.count == 1 && offered.first?["sequence"].number == 600 && offered.first?["fork"].bool == true)
        #expect(offered.first?["rewind"].bool == false)
    }
}
