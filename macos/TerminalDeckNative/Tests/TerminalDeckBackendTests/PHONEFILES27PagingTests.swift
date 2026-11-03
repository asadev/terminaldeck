import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// phone-files-27 (3 Nov): the phone's Files on the person's own device pages through a big folder. A folder answers
/// in parts that each fit one phone frame; every part says where it starts, how many rows the folder has and where the
/// next part starts, and the parts joined are the whole folder once, in the order the first part began.
@Suite("phone-files-27 Files in parts", .serialized)
struct PHONEFILES27PagingTests {
    private func scratch() throws -> URL {
        let base = URL(fileURLWithPath: BackendMacConfinement.kernelPath(FileManager.default.temporaryDirectory
            .appendingPathComponent("PHONEFILES27-" + UUID().uuidString + ".noindex").path))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func frame(_ fields: [NativeRPCValue.Field]) -> BackendRemoteClientMessage {
        BackendRemoteClientMessage(.object([.init("t", .string("files.list"))] + fields))
    }
    private func mine() -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil, claimedCapabilities: ["files"],
              reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .full)
    }

    @Test func aFolderOfTwoThousandItemsComesInPartsThatJoinIntoTheWholeFolderOnce() async throws {
        let base = try scratch(); defer { try? FileManager.default.removeItem(at: base) }
        for n in 0..<1_990 { try Data("row \(n)\n".utf8).write(to: base.appendingPathComponent(String(format: "file-%04d-with-a-longer-name.txt", n))) }
        for n in 0..<10 { try FileManager.default.createDirectory(at: base.appendingPathComponent("folder \(n)"), withIntermediateDirectories: false) }
        let feature = BackendPhoneFiles(home: base.path).feature()
        var from = 0, names: [String] = [], parts = 0, totals: Set<Double> = []
        while parts < 50 {
            var fields: [NativeRPCValue.Field] = [.init("path", .string(base.path))]
            if from > 0 { fields.append(.init("from", .number(Double(from)))) }
            let part = try #require(try await feature.handle(frame(fields), mine()).first)
            // Every part, as sent, is under the phones' own cap on a message (64 KiB; review-install-27 #7).
            #expect(BackendPhoneFiles.sentSize(part) <= BackendPhoneFiles.phoneMessageLimit)
            #expect(BackendPhoneFiles.phoneMessageLimit == 64 * 1024)
            #expect(part.value["from"] == .number(Double(from)) && part.value["path"] == .string(base.path))
            totals.insert(part.value["total"].number ?? -1)
            let rows = part.value["entries"].elements ?? []
            #expect(!rows.isEmpty)
            names += rows.compactMap { $0["name"].string }
            parts += 1
            guard let next = part.value["next"].number else { break }
            #expect(Int(next) == from + rows.count)
            from = Int(next)
        }
        #expect(totals == [2_000])
        #expect(parts >= 3)                        // more than one frame holds
        #expect(names.count == 2_000 && Set(names).count == 2_000)
        // Folders first, then Finder's name order, the same across parts.
        #expect(names.prefix(10).allSatisfy { $0.hasPrefix("folder ") })
        #expect(names.first == "folder 0" && names[10] == "file-0000-with-a-longer-name.txt" && names.last == "file-1989-with-a-longer-name.txt")
        // A part asked past the end is an empty last part, never an error or a loop.
        let past = try await feature.handle(frame([.init("path", .string(base.path)), .init("from", .number(5_000))]), mine()).first?.value
        #expect(past?["entries"].elements?.isEmpty == true && past?["next"] == .missing && past?["from"] == .number(2_000))
    }

    @Test func filesOpensInThisMacsHomeFolderAndTheWireTakesTheRowToStartFrom() async throws {
        let base = try scratch(); defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Documents"), withIntermediateDirectories: false)
        try Data("hi".utf8).write(to: base.appendingPathComponent("Documents/a.txt"))
        let feature = BackendPhoneFiles(home: base.path).feature()
        let home = try #require(try await feature.handle(frame([.init("path", .string("~"))]), mine()).first).value
        #expect(home["path"] == .string(base.path) && home["total"] == .number(1) && home["next"] == .missing)
        #expect(home["entries"].elements?.first?["name"] == .string("Documents"))
        let inside = try #require(try await feature.handle(frame([.init("path", .string("~/Documents"))]), mine()).first).value
        #expect(inside["path"] == .string(base.appendingPathComponent("Documents").path))
        #expect(try BackendPhoneFiles.read("~/Documents/a.txt", at: 0, max: 64, home: base.path).value["text"] == .string("hi"))
        // `from` reaches the handler through the wire's own reading; a bad one is refused there.
        guard case let .message(parsed) = BackendRemoteProtocol.parseClientMessage(#"{"t":"files.list","path":"~","from":500}"#) else {
            Issue.record("files.list with from was refused"); return
        }
        #expect(parsed.value["from"] == .number(500) && parsed.value["path"] == .string("~"))
        guard case .refused = BackendRemoteProtocol.parseClientMessage(#"{"t":"files.list","path":"~","from":-1}"#) else {
            Issue.record("files.list from -1 was taken"); return
        }
    }

    @Test func aBigTextFileComesInWindowsUnderThePhonesCapThatJoinExactly() throws {
        let base = try scratch(); defer { try? FileManager.default.removeItem(at: base) }
        // 200 KiB of text with quotes and tabs (escaped in JSON) and a 4-byte character now and then.
        var text = "", line = 0
        while text.utf8.count < 200 * 1024 { text += "line \(line)\t\"quoted\" path\\to\\file 🙂\n"; line += 1 }
        let file = base.appendingPathComponent("big.log")
        try Data(text.utf8).write(to: file)
        var at = 0, joined = "", windows = 0
        while windows < 100 {
            let window = try BackendPhoneFiles.read(file.path, at: at, max: 65_536)
            #expect(BackendPhoneFiles.sentSize(window) <= BackendPhoneFiles.phoneMessageLimit)
            #expect(window.value["at"] == .number(Double(at)) && window.value["binary"] == .bool(false))
            let piece = window.value["text"].string ?? ""
            #expect(!piece.isEmpty)
            joined += piece; at += piece.utf8.count; windows += 1
            if window.value["truncated"] != .bool(true) { break }
        }
        #expect(joined == text && windows >= 4)
        // A file that stops being UTF-8 later on: text up to there, then binary from that offset (never a short end).
        let mixed = base.appendingPathComponent("mixed.txt")
        try Data(Array("ok ".utf8) + [0xE9]).write(to: mixed)
        let first = try BackendPhoneFiles.read(mixed.path, at: 0, max: 3).value
        #expect(first["text"] == .string("ok ") && first["truncated"] == .bool(true))
        let rest = try BackendPhoneFiles.read(mixed.path, at: 3, max: 65_536).value
        #expect(rest["binary"] == .bool(true) && rest["at"] == .number(3))
    }

    @Test func aNamedPipeOrADeviceIsRefusedAtOnceAndAFileThroughALinkIsRead() throws {
        let base = try scratch(); defer { try? FileManager.default.removeItem(at: base) }
        let pipe = base.appendingPathComponent("waiting.fifo").path
        #expect(mkfifo(pipe, 0o600) == 0)
        // Before (review-install-27 #8) open(2) waited here for a writer, inside the host, freezing every device.
        let started = Date()
        do { _ = try BackendPhoneFiles.read(pipe, at: 0, max: 65_536); Issue.record("a named pipe was read") }
        catch let error as NativeRPCError { #expect(error.message == BackendPhoneFiles.notAFile) }
        #expect(Date().timeIntervalSince(started) < 1)
        do { _ = try BackendPhoneFiles.read("/dev/zero", at: 0, max: 16); Issue.record("a device was read") }
        catch let error as NativeRPCError { #expect(error.message == BackendPhoneFiles.notAFile) }
        let target = base.appendingPathComponent("real.txt")
        try Data("through a link".utf8).write(to: target)
        let link = base.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try BackendPhoneFiles.read(link.path, at: 0, max: 64).value["text"] == .string("through a link"))
    }
}
