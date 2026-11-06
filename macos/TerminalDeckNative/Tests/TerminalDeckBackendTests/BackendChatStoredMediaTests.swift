import CryptoKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private func storedMediaFixture() throws -> (URL, NativeRPCValue, Data) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-stored-media-" + UUID().uuidString)
    let data = Data(repeating: 0x52, count: 24_000)
    let result = NativeRPCValue.object([.init("content", .array([.object([.init("type", .string("image")), .init("mimeType", .string("image/png")), .init("data", .string(data.base64EncodedString()))])]))])
    let kept = BackendChatMedia.keep(.init(.toolResult, id: "call", value: result), in: folder.appendingPathComponent("media"))
    return (folder, kept.value, data)
}
@Test func backendChatStoredMediaRestoresTheExactPersistedToolImage() throws {
    let (folder, result, data) = try storedMediaFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(result["content"].elements?.first?["data"].string == "")
    let restored = try BackendChatStoredMedia.restore(result, historyFile: folder.appendingPathComponent("chat.json"))
    #expect(restored["content"].elements?.first?["data"].string.flatMap { Data(base64Encoded: $0) } == data)
}
@Test func backendChatStoredMediaRefusesTraversalAndChangedContent() throws {
    let (folder, result, _) = try storedMediaFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = try #require(result["content"].elements?.first)
    let escaped = result.setting("content", .array([image.setting("dataFile", .string("../private.png"))]))
    #expect(throws: NativeRPCError.self) { try BackendChatStoredMedia.restore(escaped, historyFile: folder.appendingPathComponent("chat.json")) }
    let reference = try #require(image["dataFile"].string)
    try Data(repeating: 0x53, count: 24_000).write(to: folder.appendingPathComponent(reference))
    #expect(throws: NativeRPCError.self) { try BackendChatStoredMedia.restore(result, historyFile: folder.appendingPathComponent("chat.json")) }
}
@Test func backendChatStoredMediaRefusesSymlinkedImagesAndOversizedFiles() throws {
    let (folder, result, _) = try storedMediaFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reference = try #require(result["content"].elements?.first?["dataFile"].string)
    let file = folder.appendingPathComponent(reference), outside = folder.appendingPathComponent("outside.png")
    try FileManager.default.moveItem(at: file, to: outside)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: NativeRPCError.self) { try BackendChatStoredMedia.restore(result, historyFile: folder.appendingPathComponent("chat.json")) }
    try FileManager.default.removeItem(at: file)
    try Data(repeating: 0x52, count: BackendChatStoredMedia.maximumBytes + 1).write(to: file)
    #expect(throws: NativeRPCError.self) { try BackendChatStoredMedia.restore(result, historyFile: folder.appendingPathComponent("chat.json")) }
}
@Test func backendChatStoredMediaRequiresTheRecordedSourceRow() async throws {
    let (folder, result, data) = try storedMediaFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try BackendHootChatStore(file: folder.appendingPathComponent("chat.json"), provider: .claude, retainAllHistory: true)
    try await store.seedForkHistory([
        .init(conversationID: "c", turnID: "turn", sequence: 1, provider: .claude, record: .init(.toolCall, id: "call", value: .object([.init("name", .string("screenshot")), .init("input", .object([]))]))),
        .init(conversationID: "c", turnID: "turn", sequence: 2, provider: .claude, record: .init(.toolResult, id: "call", value: .object([.init("output", result)])))])
    let restored = try await BackendChatStoredMedia.result(store: store, rowID: "turn:call")
    #expect(restored["content"].elements?.first?["data"].string.flatMap { Data(base64Encoded: $0) } == data)
    do { _ = try await BackendChatStoredMedia.result(store: store, rowID: "other:call"); Issue.record("An unrelated source row was accepted.") }
    catch let error as NativeRPCError { #expect(error.code == "access-denied") }
}
