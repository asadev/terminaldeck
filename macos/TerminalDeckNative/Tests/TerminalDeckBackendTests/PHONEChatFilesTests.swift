import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Phone round, 31 Oct (phone-chat): typed commands reach the chat exactly as typed, a phone message may carry the
/// files its own uploads landed (`chats.files`), and a phone's upload lands in this Mac's uploads folder again.
final class PHONEChatFilesTests: XCTestCase {
    private func parse(_ json: String) -> BackendRemoteClientMessage? {
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
        return nil
    }
    private static func context() -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil, claimedCapabilities: ["chats.files"],
              reach: .init(kind: .mine, unrestricted: false, folders: ["/Projects/Phone"], accounts: nil, drivesWindows: false), phoneAccess: .work)
    }
    private func chats(_ log: Log, files: Bool = true) -> BackendPhoneChats {
        var engine = BackendPhoneChats.Engine(read: { _ in .object([]) }, isChat: { _ in true },
            say: { id, text in await log.note("say \(id) \(text)") }, interrupt: { _ in }, answer: { _, _, _ in },
            start: { _ in throw NativeRPCError(code: "unused", message: "unused") })
        engine.sendIdentified = { id, text, _, steer in await log.note("\(steer ? "steer" : "say") \(id) \(text)") }
        if files { engine.sendFiles = { id, text, paths, _, steer, device in await log.note("files \(steer) \(id) [\(text)] \(paths.joined(separator: ",")) \(device)") } }
        return BackendPhoneChats(engine: engine, host: .init(send: { _, _ in }, stillSees: { _, _ in true }, admitStarted: { _, _ in }), beat: .zero)
    }

    func testATypedCommandReachesTheChatExactlyAsTyped() async throws {
        let log = Log(), chats = chats(log)
        for typed in ["/wrap", "/catchup now please", "/plan Fix the relay", "/review"] {
            _ = try await chats.handle(try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"\#(typed)"}"#)), context: Self.context())
        }
        let seen = await log.lines
        XCTAssertEqual(seen, ["say chat-1 /wrap", "say chat-1 /catchup now please", "say chat-1 /plan Fix the relay", "say chat-1 /review"])
    }

    func testFilesParseOnChatsAndHootAndAreBounded() throws {
        let say = try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"Look","files":["/Users/a/Downloads/Terminal Deck/shot.png"]}"#))
        XCTAssertEqual(say["files"].elements?.compactMap(\.string), ["/Users/a/Downloads/Terminal Deck/shot.png"])
        XCTAssertNotNil(parse(#"{"t":"chats.say","id":"chat-1","text":"","files":["/a.png"]}"#), "files alone are a message")
        XCTAssertNil(parse(#"{"t":"chats.say","id":"chat-1","text":""}"#), "still no empty message")
        XCTAssertNil(parse(#"{"t":"chats.say","id":"chat-1","text":"x","files":["relative.png"]}"#))
        XCTAssertNil(parse(#"{"t":"chats.say","id":"chat-1","text":"x","files":["/1","/2","/3","/4","/5"]}"#))
        XCTAssertNil(parse(#"{"t":"chats.say","id":"chat-1","text":"x","files":[]}"#))
        let hoot = try XCTUnwrap(parse(#"{"t":"copilot.say","text":"See this","files":["/b.pdf"]}"#))
        XCTAssertEqual(hoot.type, "hoot.say")
        XCTAssertEqual(hoot["files"].elements?.compactMap(\.string), ["/b.pdf"])
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains(BackendPhoneChats.filesCapability))
    }

    func testAMessageWithFilesReachesTheFileSendAndAnOlderEngineRefusesIt() async throws {
        let log = Log()
        _ = try await chats(log).handle(try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"","files":["/u/a.png","/u/b.zip"]}"#)), context: Self.context())
        let seen = await log.lines
        XCTAssertEqual(seen, ["files false chat-1 [] /u/a.png,/u/b.zip phone-1"])
        let older = Log()
        let frames = try await chats(older, files: false).handle(try XCTUnwrap(parse(#"{"t":"chats.say","id":"chat-1","text":"Hi","files":["/u/a.png"]}"#)), context: Self.context())
        XCTAssertEqual(frames.first?.kind.rawValue, "error")
        let none = await older.lines
        XCTAssertTrue(none.isEmpty, "never sent without its files")
    }

    func testTheFilesCapabilityIsAdvertisedOnlyByAMacThatTakesFiles() async {
        let log = Log()
        let taking = await chats(log).feature(), older = await chats(log, files: false).feature()
        XCTAssertEqual(taking.additionalAdvertisedCapabilities, ["chats.files"])
        XCTAssertTrue(older.additionalAdvertisedCapabilities.isEmpty)
    }

    func testAPhoneUploadLandsInTheUploadsFolderAndANamedFolderNeedsReach() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("td-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let uploads = BackendUploadDestination.uploadsFolder(home: home, appName: "Terminal Deck")
        XCTAssertEqual(uploads.lastPathComponent, "Terminal Deck")
        XCTAssertEqual(uploads.deletingLastPathComponent().lastPathComponent, "Downloads")
        let landed = await BackendUploadDestination.resolve(nil, approved: true, uploads: uploads, reaches: { _ in false })
        XCTAssertEqual(landed?.path, uploads.resolvingSymlinksInPath().path)
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploads.path, isDirectory: &isFolder) && isFolder.boolValue)
        let refusedDevice = await BackendUploadDestination.resolve(nil, approved: false, uploads: uploads, reaches: { _ in true })
        XCTAssertNil(refusedDevice)
        let project = home.appendingPathComponent("Project").path
        let reached = await BackendUploadDestination.resolve(project, approved: true, uploads: uploads, reaches: { $0.hasSuffix("/Project") })
        XCTAssertNotNil(reached)
        let escaped = await BackendUploadDestination.resolve(project + "/../../etc", approved: true, uploads: uploads, reaches: { $0.hasSuffix("/Project") })
        XCTAssertNil(escaped, "a folder is judged by where it really is")
        let relative = await BackendUploadDestination.resolve("Project", approved: true, uploads: uploads, reaches: { _ in true })
        XCTAssertNil(relative)
    }

    func testAPhoneUploadsEndToEndIntoTheUploadsFolder() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("td-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let uploads = BackendUploadDestination.uploadsFolder(home: home, appName: "Terminal Deck")
        let receiver = BackendUploadReceive(destination: { _, proposed in
            await BackendUploadDestination.resolve(proposed, approved: true, uploads: uploads, reaches: { _ in false })
        })
        let bytes = Data("a photo from the phone".utf8), context = Self.context()
        func frame(_ type: String, _ fields: [NativeRPCValue.Field]) throws -> BackendRemoteClientMessage {
            try XCTUnwrap(parse(String(decoding: try NativeRPCValue.object([.init("t", .string(type)), .init("id", .string("up-1"))] + fields).encodedJSON(), as: UTF8.self)))
        }
        let ready = try await receiver.handle(try frame("upload.begin", [.init("name", .string("IMG_0001.jpg")), .init("size", .number(Double(bytes.count)))]), context: context)
        XCTAssertEqual(ready.first?.kind.rawValue, "upload.ready")
        _ = try await receiver.handle(try frame("upload.data", [.init("data", .string(bytes.base64EncodedString()))]), context: context)
        let digest = SHA256Hex.of(bytes)
        let done = try await receiver.handle(try frame("upload.end", [.init("sha256", .string(digest))]), context: context)
        XCTAssertEqual(done.first?.kind.rawValue, "upload.done")
        let path = try XCTUnwrap(done.first?.value["path"].string)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertTrue(path.hasSuffix("/Downloads/Terminal Deck/IMG_0001.jpg"))
        let attachable = await BackendUploadDestination.attachable(path, approved: true, uploads: uploads, reaches: { _ in false })
        XCTAssertNotNil(attachable, "a landed upload may go to the AI")
        let elsewhere = home.appendingPathComponent("secret.txt")
        try Data("x".utf8).write(to: elsewhere)
        let refused = await BackendUploadDestination.attachable(elsewhere.path, approved: true, uploads: uploads, reaches: { _ in false })
        XCTAssertNil(refused, "a file outside the uploads folder and the device's folders is not the phone's to name")
        await receiver.stop()
    }

    /// 31 Oct (Asad: "accounts switching is also not working in phones"): the phone reads what this Mac's chip shows,
    /// so the account an in-place switch just handed the session shows at once instead of the old one.
    func testAPhonesAccountReadShowsTheSwitchedToAccountAtOnce() throws {
        var input = BackendCreateSessionInput(cwd: "/Projects/Phone", provider: "claude"); input.chat = true
        let meta = BackendSessionMeta(id: "chat-1", input: input, spawn: .init(provider: "claude", command: "/not-run", args: [], path: ""),
                                      now: Date(timeIntervalSince1970: 1))
        let old = BackendAccountSessionReading(provider: "claude", configDir: "/c/work", profileId: "work", profileName: "Work",
                                               source: "spawn", email: nil, reason: nil)
        let shown = BackendAccountSessionReading.decode(BackendSessionLifecycleRPC.account(old, meta: meta, pending: .init(id: "home", name: "Home")))
        XCTAssertEqual(shown.profileId, "home")
        XCTAssertEqual(shown.profileName, "Home")
        XCTAssertNil(shown.reason)
        let unchanged = BackendAccountSessionReading.decode(BackendSessionLifecycleRPC.account(old, meta: meta, pending: nil))
        XCTAssertEqual(unchanged.profileId, "work")
        XCTAssertNotNil(BackendAccountSessionReading.decode(.object([.init("kind", .string("withheld")), .init("reason", .string("x"))])).reason)
    }
}

import CryptoKit
private enum SHA256Hex { static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() } }

private actor Log {
    private(set) var lines: [String] = []
    func note(_ line: String) { lines.append(line) }
}
