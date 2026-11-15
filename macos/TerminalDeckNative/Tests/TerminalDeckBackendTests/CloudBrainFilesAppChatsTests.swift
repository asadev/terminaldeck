import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud I20 — app chats, attachments and drafts")
struct CloudBrainFilesAppChatsTests {
    typealias F = CloudBrainFilesFixture

    @Test func chatsRestoreInertWithRuntimeFieldsNeutralisedAndDraftsNeverPlaced_S11() async throws {
        let f = try F(); defer { f.close() }
        let picture = Data([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3])
        try f.write("a/data/session-chats/t1/chat.json", #"{"events":[{"kind":"user","text":"hello"}],"queuedMessages":[{"text":"would send"}]}"#)
        try f.write("a/data/session-chats/t1/job.json", #"{"key":"t1","result":"done","interruptedAt":1.5,"resumeInput":{"cwd":"/other/mac"},"turnID":"x"}"#)
        try f.write("a/data/session-chats/t1/composer-settings.json", #"{"model":"m"}"#)
        try f.write("a/data/session-chats/t1/media/p.png", data: picture)
        try f.write("a/data/session-chats/delivery-requests/r1.json", #"{"text":"unsent"}"#)
        try f.write("a/data/chat-outgoing/o1.json", #"{"text":"unsent"}"#)
        try f.write("a/hoot/chat.json", #"{"conversationId":"c-1","events":[],"queuedMessages":[1]}"#)
        try f.write("a/data/copilot/old.json", "{}")
        let a = try BackendCloudBrainAppChats.adapter(dataRoot: f.url("a/data"), hootRoot: f.url("a/hoot"), deviceId: f.deviceA, stateRoot: f.url("a/state"))
        let b = try BackendCloudBrainAppChats.adapter(dataRoot: f.url("b/data"), hootRoot: f.url("b/hoot"), deviceId: f.deviceB, stateRoot: f.url("b/state"))
        let inventory = try await a.sourceInventory()
        #expect(inventory.map { $0.items } == [4, 1, 1, 1, 1, 0])
        // Conversation links are not built: the row stays visibly incomplete instead of reporting a silent zero.
        #expect(inventory.last.map { !$0.complete && !$0.blockedReasons.isEmpty } == true)
        let snapshot = try await F.snapshot(a)
        _ = try await F.apply(b, snapshot.operations, device: f.deviceA)
        let chat = try NativeRPCValue.parseJSON(f.read("b/data/session-chats/t1/chat.json"))
        #expect(chat["queuedMessages"] == .missing)
        #expect(chat["events"].elements?.count == 1)
        let job = try NativeRPCValue.parseJSON(f.read("b/data/session-chats/t1/job.json"))
        #expect(job["interruptedAt"] == .missing && job["resumeInput"] == .missing && job["turnID"] == .missing)
        #expect(job["result"].string == "done" && job["key"].string == "t1")
        #expect(try f.read("b/data/session-chats/t1/composer-settings.json") == f.read("a/data/session-chats/t1/composer-settings.json"))
        #expect(try f.read("b/data/session-chats/t1/media/p.png") == picture)
        let hoot = try NativeRPCValue.parseJSON(f.read("b/hoot/chat.json"))
        #expect(hoot["queuedMessages"] == .missing && hoot["conversationId"].string == "c-1")
        // Unsent drafts and the legacy folder are kept readable, never placed where a queue could send them.
        #expect(!f.exists("b/data/session-chats/delivery-requests"))
        #expect(!f.exists("b/data/chat-outgoing"))
        #expect(!f.exists("b/data/copilot"))
        // Cloud keeps the raw bytes unchanged.
        let raw = try #require(try await b.retainedVersions(key: "file/session-chats/t1/chat.json").first)
        #expect(try await b.readRetained(rawHash: raw.rawHash, offset: 0, limit: 4096) == f.read("a/data/session-chats/t1/chat.json"))
        #expect(try await b.readiness().verified)
        #expect(try await b.reconcile().journaled == 0)
    }

    @Test func anOpenTabOnThisMacIsNeverWritten_S05() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/data/session-chats/t1/chat.json", #"{"events":[1]}"#)
        try f.write("b/data/session-chats/t1/chat.json", #"{"events":[2]}"#)
        let a = try BackendCloudBrainAppChats.adapter(dataRoot: f.url("a/data"), hootRoot: f.url("a/hoot"), deviceId: f.deviceA, stateRoot: f.url("a/state"))
        let b = try BackendCloudBrainAppChats.adapter(dataRoot: f.url("b/data"), hootRoot: f.url("b/hoot"), deviceId: f.deviceB, stateRoot: f.url("b/state"))
        let receipt = try await F.apply(b, try await F.snapshot(a).operations, device: f.deviceA)
        #expect(receipt.results.map { $0.status } == [.keptBoth])
        #expect(try f.read("b/data/session-chats/t1/chat.json") == Data(#"{"events":[2]}"#.utf8))
    }

    @Test func neutralisingLeavesOtherFilesByteIdentical() throws {
        let pretty = Data("{\n  \"events\" : []\n}".utf8)
        #expect(try BackendCloudBrainAppChats.neutralise("t1/chat.json", pretty) == pretty)
        #expect(try BackendCloudBrainAppChats.neutralise("t1/media/x.json", Data(#"{"busy":true}"#.utf8)) == Data(#"{"busy":true}"#.utf8))
        #expect(try BackendCloudBrainAppChats.neutralise("t1/chat.json", Data("not json".utf8)) == Data("not json".utf8))
    }
}
