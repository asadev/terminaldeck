import Darwin
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Old app with new keeper: refuse before sending", .serialized)
struct ChatSendNowLegacyTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let paths: BackendHOSTPaths
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        private let lock = NSLock()
        private var entered = 0
        var sendCalls: Int { lock.withLock { entered } }
        var server: BackendHOSTServer?
        init() throws {
            root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("sn-old-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            paths = try BackendHOSTPaths(dataDirectory: root)
            _ = try paths.secret(create: true)
            try start()
        }
        func start() throws {
            server = try BackendHOSTServer(paths: paths, hostVersion: "scratch-legacy", manager: manager,
                launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { [manager] in manager.chatHostSnapshot($0) }, onIdle: {},
                resource: { [self] method, payload in
                    if method == "chats.say" || method == "chats.steer" {
                        lock.withLock { entered += 1 }
                        // Represents delayed launch/interrupt/source work. The compatibility gate must
                        // never enter it, even if the old app has already abandoned its socket.
                        try await Task.sleep(for: .milliseconds(50))
                        throw BackendHOSTFailure.invalid("Simulated failed pipe write")
                    }
                    if method == "chats.read", try NativeRPCValue.parseJSON(payload)["failRead"].bool == true {
                        throw BackendHOSTFailure.invalid("Simulated failed reconciliation read")
                    }
                    return try NativeRPCValue.object([.init("events", .array([]))]).encodedJSON()
                })
        }
        func close() {
            server?.stopListening(); server = nil
            try? FileManager.default.removeItem(at: root)
        }
        var oldArguments: NativeRPCValue {
            .object([.init("id", .string("old-chat")), .init("text", .string("same words")),
                .init("attachments", .array([.object([.init("type", .string("image"))])]))])
        }
        func discardReply() throws {
            let client = try BackendHOSTClient(paths: paths)
            defer { client.detach() }
            var request = BackendHOSTProtocol.Request(secret: try paths.secret(create: false), operation: .resource)
            request.instance = client.hello.instance
            request.resourceMethod = "chats.steer"
            request.resourcePayload = try oldArguments.encodedJSON()
            let fd = try BackendHOSTSocket.connect(paths.socket)
            defer { Darwin.close(fd) }
            try BackendHOSTSocket.write(request, to: fd, maximum: BackendHOSTProtocol.maximumRequestBytes)
            _ = Darwin.shutdown(fd, SHUT_RDWR) // Old app disconnected or stopped waiting; don't read the rejection.
        }
        func rejected(_ method: String) async throws -> String {
            let client = try BackendHOSTClient(paths: paths)
            defer { client.detach() }
            do {
                _ = try await client.resource(method, arguments: oldArguments)
                Issue.record("An old app was allowed into \(method)")
                return ""
            } catch { return error.localizedDescription }
        }
    }

    @Test func rejectionUsesTheOldAppsHeldQueueBranchWithoutTextReconciliation() async throws {
        let f = try Fixture(); defer { f.close() }
        for method in ["chats.steer", "chats.say"] {
            let error = try await f.rejected(method)
            // bb22898a: deliveryUnknown checks these strings; its steer catch holds on this phrase.
            let deliveryUnknown = error.contains("connection failed") || error.contains("POSIX status") || error.contains("timed out")
            #expect(!deliveryUnknown)
            #expect(error.contains("held in the queue"))
            #expect(error.contains("Not sent"))
            // Even another sender's matching user row or a pre-write journal row cannot be
            // mistaken for delivery: the old app only reads/matches text in deliveryUnknown.
        }
        #expect(f.sendCalls == 0)
    }

    @Test(arguments: [false, true]) func timeoutOrDisconnectThenNegativeOrFailedReadCannotResend(failedRead: Bool) async throws {
        let f = try Fixture(); defer { f.close() }
        try f.discardReply()
        // The old client's timeout/disconnect catch either gets an empty read or a failed read.
        // Both release the row in bb22898a; its following automatic say must still be refused.
        let client = try BackendHOSTClient(paths: f.paths)
        defer { client.detach() }
        do {
            let read = try await client.resource("chats.read", arguments: f.oldArguments.setting("failRead", .bool(failedRead)))
            #expect(!failedRead)
            #expect(read["events"].elements?.isEmpty == true)
        } catch {
            #expect(failedRead)
            #expect(error.localizedDescription.contains("Simulated failed reconciliation read"))
        }
        let error = try await f.rejected("chats.say")
        #expect(error.contains("held in the queue"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.sendCalls == 0, "Neither the abandoned steer nor the automatic retry may reach journal/write work")
    }

    @Test func keeperRestartWhileOldSendIsOutstandingCannotLeaveWorkToReplay() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.discardReply()
        weak var previous = f.server
        f.server?.stopListening(); f.server = nil
        // The abandoned socket's reader may still retain the stopped server. Let it finish
        // before taking its owner lock, as a new keeper process would after the old one exits.
        for _ in 0..<100 {
            if previous == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(previous == nil)
        try f.start() // Scratch keeper endpoint only; no app, real helper or real sessions.
        #expect(try await f.rejected("chats.steer").contains("held in the queue"))
        #expect(try await f.rejected("chats.say").contains("held in the queue"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.sendCalls == 0)
    }

    @Test func directServiceRejectsBeforeRestoringOrJournallingAndAcceptsOnlyNonemptyIDs() async throws {
        let f = try Fixture(); defer { f.close() }
        let directory = f.root.appendingPathComponent("never-opened")
        let service = BackendHOSTChats(manager: f.manager, directory: directory)
        for method in ["chats.say", "chats.steer"] {
            for identity in [NativeRPCValue.null, .string(""), .string("  ")] {
                let args = f.oldArguments.setting("clientMessageId", identity)
                do { _ = try await service.invoke(method, payload: args.encodedJSON()); Issue.record("Missing ID accepted") }
                catch { #expect(error.localizedDescription.contains("held in the queue")) }
            }
            try BackendHOSTChats.validateDeliveryIdentity(method, payload: f.oldArguments.setting("clientMessageId", .string("unique-id")).encodedJSON())
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path), "No restore, journal, pipe write or receipt for an old caller")
        #expect(f.manager.list().isEmpty)
    }
}
