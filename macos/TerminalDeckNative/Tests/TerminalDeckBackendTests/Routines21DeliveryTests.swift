import Foundation
import Network
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Routines21DeliveryTests: XCTestCase, @unchecked Sendable {
    private let botToken = "123456:" + String(repeating: "a", count: 32)

    func testWebhookPostsReportAndSecretHeaderToLocalServer() async throws {
        let fake = try await LocalServer.start(); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport)
        let destination = Routines21Destination(id: "web", kind: "webhook", label: "Daily summary", url: fake.url.absoluteString, secretHeader: "X-Report-Secret")
        try await delivery.saveDestinationSecret(routineID: "daily", id: "web", value: "local-test-header")
        let receipts = await delivery.send([destination], routineID: "daily", routine: "Daily checks", runTime: 1000, status: "ok", report: "All checks passed.")
        XCTAssertEqual(receipts.first?.status, "sent"); XCTAssertEqual(receipts.first?.attempts, 1)
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.method, "POST"); XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertTrue(request.headers["x-report-secret"] == "local-test-header")
        let body = try NativeRPCValue.parseJSON(request.body)
        XCTAssertEqual(body["routine"].string, "Daily checks"); XCTAssertEqual(body["runTime"].number, 1000)
        XCTAssertEqual(body["status"].string, "ok"); XCTAssertEqual(body["report"].string, "All checks passed.")
        XCTAssertEqual(Set(body.fields?.map(\.key) ?? []), ["routine", "runTime", "status", "report"])
    }

    func testWhatsAppUsesReceiverPresetChannelTokenAndSelectedGroup() async throws {
        let fake = try await LocalServer.start(); defer { fake.stop() }
        let state = receiverState()
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), receiver: { state }, transport: fake.transport)
        let destination = Routines21Destination(id: "wa", kind: "whatsapp", label: "WhatsApp", connectionId: "whapi-local", chatId: "team@g.us")
        let receipts = await delivery.send([destination], routineID: "daily", routine: "Daily checks", runTime: 1000, status: "failed", report: "A check needs attention.")
        XCTAssertEqual(receipts.first?.status, "sent")
        let request = try XCTUnwrap(fake.requests.first), body = try NativeRPCValue.parseJSON(request.body)
        XCTAssertEqual(request.path, "/messages/text")
        XCTAssertTrue(request.headers["authorization"] == "Bearer local-whapi-token")
        XCTAssertEqual(body["to"].string, "team@g.us")
        XCTAssertTrue(body["body"].string?.contains("A check needs attention.") == true)
        XCTAssertTrue(body["body"].string?.contains("failed") == true)
        let connections = try await delivery.connections()
        let wire = try XCTUnwrap(connections.first).wire
        XCTAssertEqual(wire["hasSecret"].bool, true)
        XCTAssertEqual(wire["chats"].elements?.first?["id"].string, "team@g.us")
        XCTAssertFalse(String(decoding: try wire.encodedJSON(), as: UTF8.self).contains("local-whapi-token"))
    }

    func testTelegramUsesSavedBotAndChatOnLocalServer() async throws {
        let fake = try await LocalServer.start(body: Data("{\"ok\":true}".utf8)); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport)
        _ = try await delivery.saveTelegram(id: "telegram-local", label: "Daily Telegram", chatId: "-10042", botToken: botToken)
        let receipts = await delivery.send([.init(id: "tg", kind: "telegram", label: "Telegram", connectionId: "telegram-local")],
                                          routineID: "daily", routine: "Daily checks", runTime: 1000, status: "ok", report: "Report text.")
        XCTAssertEqual(receipts.first?.status, "sent")
        let request = try XCTUnwrap(fake.requests.first), body = try NativeRPCValue.parseJSON(request.body)
        XCTAssertTrue(request.path == "/bot\(botToken)/sendMessage")
        XCTAssertEqual(body["chat_id"].string, "-10042")
        XCTAssertTrue(body["text"].string?.contains("Report text.") == true)
        XCTAssertEqual(request.method, "POST")
    }

    func testRefusedTokenIsShownSafelyAndRetriedExactlyOnce() async throws {
        let fake = try await LocalServer.start(statuses: [401, 401], body: Data("raw server detail must not escape".utf8)); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport)
        _ = try await delivery.saveTelegram(id: "telegram-local", label: "Telegram", chatId: "42", botToken: botToken)
        let receipts = await delivery.send([.init(id: "tg", kind: "telegram", label: "Telegram", connectionId: "telegram-local")],
                                          routineID: "daily", routine: "Daily checks", runTime: 1000, status: "ok", report: "The routine itself succeeded.")
        XCTAssertEqual(fake.requests.count, 2); XCTAssertEqual(receipts.first?.attempts, 2)
        XCTAssertEqual(receipts.first?.status, "failed"); XCTAssertEqual(receipts.first?.message, "The bot token was refused.")
        let wire = try XCTUnwrap(receipts.first).wire
        let text = String(decoding: try wire.encodedJSON(), as: UTF8.self)
        XCTAssertFalse(text.contains(botToken)); XCTAssertFalse(text.contains("raw server"))
    }

    func testFirstFailedSendRetriesThenSucceedsWithoutThirdAttempt() async throws {
        let fake = try await LocalServer.start(statuses: [503, 200, 503]); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport)
        let receipts = await delivery.send([.init(id: "web", kind: "webhook", label: "Webhook", url: fake.url.absoluteString)],
                                          routineID: "daily", routine: "Daily checks", runTime: 1000, status: "ok", report: "Done.")
        XCTAssertEqual(receipts.first?.status, "sent"); XCTAssertEqual(receipts.first?.attempts, 2)
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testTelegramFalseOKIsFailureEvenWithHTTP200() async throws {
        let fake = try await LocalServer.start(body: Data("{\"ok\":false,\"error_code\":403,\"description\":\"private service text\"}".utf8)); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport)
        _ = try await delivery.saveTelegram(id: "telegram-local", label: "Telegram", chatId: "42", botToken: botToken)
        let receipts = await delivery.send([.init(id: "tg", kind: "telegram", label: "Telegram", connectionId: "telegram-local")],
                                          routineID: "daily", routine: "Daily", runTime: 1000, status: "ok", report: "Done.")
        XCTAssertEqual(receipts.first?.status, "failed"); XCTAssertEqual(receipts.first?.message, "The bot token was refused.")
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testTelegramMetadataPersistsWithoutTokenAndOmittedTokenIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routines21-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = BackendConnectedTasksMemorySecrets()
        let delivery = BackendRoutines21Delivery(directory: directory, secrets: secrets)
        _ = try await delivery.saveTelegram(id: "telegram-local", label: "Old name", chatId: "42", botToken: botToken)
        let changed = try await delivery.saveTelegram(id: "telegram-local", label: "New name", chatId: "43", botToken: nil)
        XCTAssertTrue(changed.hasSecret)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(BackendRoutines21Connections.fileName))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(botToken))
        let reopened = BackendRoutines21Delivery(directory: directory, secrets: secrets)
        let records = try await reopened.connections()
        XCTAssertEqual(records.first?.label, "New name"); XCTAssertEqual(records.first?.chatId, "43")
        XCTAssertEqual(records.first?.hasSecret, true)
        let wire = try XCTUnwrap(records.first).wire
        XCTAssertFalse(String(decoding: try wire.encodedJSON(), as: UTF8.self).contains(botToken))
    }

    func testDestinationSecretsStayMaskedAndAreScopedToRoutine() async throws {
        let fake = try await LocalServer.start(); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport)
        let raw = Routines21Destination(id: "same", kind: "webhook", label: "Webhook", url: fake.url.absoluteString, secretHeader: "Authorization").wire
        let saved = try await delivery.prepareDestinations(routineID: "routine-a", raw: [raw.setting("secret", .string("local-secret-a"))], previous: [])
        XCTAssertEqual(saved.first?.hasSecret, true)
        let readback = String(decoding: try XCTUnwrap(saved.first).wire.encodedJSON(), as: UTF8.self)
        XCTAssertFalse(readback.contains("local-secret-a")); XCTAssertFalse(readback.contains("botToken"))
        let kept = try await delivery.prepareDestinations(routineID: "routine-a", raw: [raw], previous: saved)
        XCTAssertEqual(kept.first?.hasSecret, true)
        let other = try await delivery.prepareDestinations(routineID: "routine-b", raw: [raw], previous: [])
        XCTAssertEqual(other.first?.hasSecret, false)
        _ = await delivery.send(other, routineID: "routine-b", routine: "Other", runTime: 1000, status: "ok", report: "Done.")
        XCTAssertNil(fake.requests.first?.headers["authorization"])
    }

    func testMissingSavedWebhookSecretRefusesToSendWithoutItsHeader() async throws {
        let fake = try await LocalServer.start(); defer { fake.stop() }
        let secrets = DisappearingSecrets()
        let delivery = BackendRoutines21Delivery(secrets: secrets, transport: fake.transport)
        let raw = Routines21Destination(id: "web", kind: "webhook", label: "Webhook", url: fake.url.absoluteString, secretHeader: "Authorization").wire
        let destinations = try await delivery.prepareDestinations(routineID: "daily", raw: [raw.setting("secret", .string("local-required-header"))], previous: [])
        XCTAssertEqual(destinations.first?.hasSecret, true)
        secrets.removeAll()
        let edited = try await delivery.prepareDestinations(routineID: "daily", raw: [raw], previous: destinations)
        XCTAssertEqual(edited.first?.hasSecret, true)
        let receipts = await delivery.send(edited, routineID: "daily", routine: "Daily", runTime: 1000, status: "ok", report: "The routine succeeded.")
        XCTAssertEqual(receipts.first?.status, "failed"); XCTAssertEqual(receipts.first?.attempts, 2)
        XCTAssertEqual(receipts.first?.message, "The saved webhook secret is missing. Add it again before sending.")
        XCTAssertTrue(fake.requests.isEmpty)
        let cleared = try await delivery.prepareDestinations(routineID: "daily", raw: [raw.setting("secret", .string(""))], previous: edited)
        XCTAssertEqual(cleared.first?.hasSecret, false)
    }

    func testHootFailureDoesNotPreventOtherDestinationAndEachGetsOwnReceipt() async throws {
        let fake = try await LocalServer.start(); defer { fake.stop() }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: fake.transport, hoot: { _, _, _, _ in
            throw URLError(.badServerResponse)
        })
        let receipts = await delivery.send([.init(id: "hoot", kind: "hoot", label: "Hoot"), .init(id: "web", kind: "webhook", label: "Webhook", url: fake.url.absoluteString)],
                                          routineID: "daily", routine: "Daily", runTime: 1000, status: "ok", report: "Done.")
        XCTAssertEqual(receipts.count, 2); XCTAssertEqual(receipts[0].status, "failed"); XCTAssertEqual(receipts[0].attempts, 2)
        XCTAssertEqual(receipts[1].status, "sent"); XCTAssertEqual(fake.requests.count, 1)
    }

    func testExistingTelegramConnectionUsesServerSenderWithoutDownloadingToken() async throws {
        let masked = BackendAppsServerSettings.publicAlerts(.object([.init("channels", .array([
            .object([.init("botToken", .string("set"))]), .object([.init("botToken", .string(""))])
        ]))]))["channels"].elements ?? []
        XCTAssertEqual(masked[0]["hasBotToken"].bool, true)
        XCTAssertEqual(masked[0]["botToken"].string, BackendAppsServerSettings.mask)
        XCTAssertEqual(masked[1]["hasBotToken"].bool, false)
        let calls = RemoteCalls()
        let runtime = BackendAppsRuntime(execute: { _, command, stdin, _, _ in
            await calls.add(command, stdin)
            if stdin == nil {
                return .init(code: 0, stdout: "{\"channels\":[{\"id\":\"daily\",\"kind\":\"telegram\",\"name\":\"Server Telegram\",\"botToken\":\"set\",\"chatId\":\"-10042\"}]}")
            }
            return .init(code: 0, stdout: "200\n")
        })
        let adapter = try BackendRoutines21ServerTelegram(runtime: runtime)
        let records = await adapter.list(serverIDs: ["server-fixture"])
        XCTAssertEqual(records.first?.id, "server:server-fixture:daily"); XCTAssertEqual(records.first?.hasSecret, true)
        XCTAssertNil(records.first?.wire["botToken"].string)
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), existingTelegram: { records },
                                                sendExistingTelegram: { id, chat, text in try await adapter.send(connectionID: id, chatID: chat, text: text) })
        let receipts = await delivery.send([.init(id: "tg", kind: "telegram", label: "Telegram", connectionId: "server:server-fixture:daily")],
                                          routineID: "daily", routine: "Daily", runTime: 1000, status: "ok", report: "Routine report.")
        XCTAssertEqual(receipts.first?.status, "sent")
        let sent = await calls.lastInput()
        let wire = try NativeRPCValue.parseJSON(try XCTUnwrap(sent))
        XCTAssertEqual(wire["channelId"].string, "daily"); XCTAssertTrue(wire["text"].string?.contains("Routine report.") == true)
        XCTAssertNil(wire["botToken"].string)
        XCTAssertTrue(adapter.script.contains("td_curlq")); XCTAssertTrue(adapter.script.contains("-K -"))
        XCTAssertFalse(adapter.script.contains("--test"))
    }

    func testNoConnectionsHasEmptyPickerAndMissingTokenProducesSafeFailure() async throws {
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets())
        let connections = try await delivery.connections()
        XCTAssertTrue(connections.isEmpty)
        let receipts = await delivery.send([.init(id: "tg", kind: "telegram", label: "Telegram", connectionId: "missing")],
                                          routineID: "daily", routine: "Daily", runTime: 1000, status: "ok", report: "Done.")
        XCTAssertEqual(receipts.first?.status, "failed"); XCTAssertEqual(receipts.first?.attempts, 2)
        XCTAssertTrue(receipts.first?.message.contains("no saved bot token") == true)
    }

    func testInvalidHeaderAndPasswordInWebhookAreRejectedBeforeSending() throws {
        XCTAssertThrowsError(try Routines21Destination(id: "web", kind: "webhook", label: "Webhook", url: "https://user:password@example.test", secretHeader: "Authorization").validate())
        XCTAssertThrowsError(try Routines21Destination(id: "web", kind: "webhook", label: "Webhook", url: "https://example.test", secretHeader: "Host").validate())
        XCTAssertThrowsError(try Routines21Destination(id: "web", kind: "webhook", label: "Webhook", url: "https://example.test", secretHeader: "X-Test\r\nHeader").validate())
    }

    private func receiverState() -> BackendRCVState {
        var state = BackendRCVState(receiverKey: Data(repeating: 1, count: 32))
        state.sources = [.init(id: "whapi-local", name: "Team WhatsApp", preset: RCVPresets.whapi.id, auth: RCVPresets.whapi.auth, mapping: RCVPresets.whapi.mapping, reply: RCVPresets.whapi.reply)]
        state.secrets["whapi-local"] = .init(secret: "receiver-local-secret", reply: "local-whapi-token")
        state.events = [.init(sourceId: "whapi-local", receivedAt: 1000, kind: "message", fields: ["chat": "team@g.us"])]
        return state
    }

    private actor RemoteCalls {
        var calls: [(String, Data?)] = []
        func add(_ command: String, _ stdin: Data?) { calls.append((command, stdin)) }
        func lastInput() -> Data? { calls.last?.1 }
    }

    private final class DisappearingSecrets: BackendConnectedTasksSecrets, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func read(_ id: String) throws -> String? { lock.withLock { values[id] } }
        func write(_ id: String, token: String) throws { lock.withLock { values[id] = token } }
        func remove(_ id: String) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
        func removeAll() { lock.withLock { values.removeAll() } }
    }

    /// Real loopback HTTP, never an external endpoint. The transport only swaps
    /// the host/port; it exercises the complete URLSession request and body.
    private final class LocalServer: @unchecked Sendable {
        struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }
        private let listener: NWListener
        private let queue = DispatchQueue(label: "routines21.local-http")
        private let lock = NSLock()
        private var captured: [Request] = []
        private var connections: [NWConnection] = []
        private let statuses: [Int]
        private let body: Data
        var requests: [Request] { lock.withLock { captured } }
        var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/report")! }
        var transport: BackendRoutines21Delivery.Transport {
            { [self] original in
                var request = original
                var components = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)!
                components.scheme = "http"; components.host = "127.0.0.1"; components.port = Int(listener.port!.rawValue)
                request.url = components.url
                return try await BackendRoutines21Delivery.http(request)
            }
        }
        private init(statuses: [Int], body: Data) throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params); self.statuses = statuses; self.body = body
        }
        static func start(statuses: [Int] = [200], body: Data = Data("{}".utf8)) async throws -> LocalServer {
            let server = try LocalServer(statuses: statuses, body: body)
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { connection.cancel(); return }
                server.lock.withLock { server.connections.append(connection) }
                connection.start(queue: server.queue); server.receive(connection, buffer: Data())
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                server.listener.stateUpdateHandler = { [weak server] state in
                    switch state {
                    case .ready: server?.listener.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error): server?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    default: break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            return server
        }
        func stop() { listener.cancel(); lock.withLock { connections.forEach { $0.cancel() } } }
        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128_000) { [weak self] data, _, complete, error in
                guard let self else { connection.cancel(); return }
                var next = buffer; if let data { next.append(data) }
                if let request = Self.parse(next) {
                    let index = self.lock.withLock { let index = self.captured.count; self.captured.append(request); return index }
                    let code = self.statuses[min(index, self.statuses.count - 1)]
                    var response = Data("HTTP/1.1 \(code) Local\r\nContent-Type: application/json\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(self.body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if !complete && error == nil && next.count < 128_000 { self.receive(connection, buffer: next) }
                else { connection.cancel() }
            }
        }
        private static func parse(_ bytes: Data) -> Request? {
            guard let range = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: bytes[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ").map(String.init)
            guard first.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
            }
            let count = Int(headers["content-length"] ?? "0") ?? 0
            guard bytes.count - range.upperBound >= count else { return nil }
            return Request(method: first[0], path: first[1], headers: headers, body: Data(bytes[range.upperBound..<(range.upperBound + count)]))
        }
    }
}
