import Foundation
import Testing
@testable import TerminalDeckBackend

// #497: big copies open the file once and keep several requests in flight. This runs the real
// SFTP client against this Mac's own sftp-server on scratch files; no server is contacted.
@Suite("Server file transfers")
struct BackendServersSFTPTransferTests {
    static let server = "/usr/libexec/sftp-server"

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: BackendServersSFTPTransferTests.server)))
    func bigCopiesKeepSeveralRequestsInFlightAndArriveIntact() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-sftp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("source.bin"), copy = scratch.appendingPathComponent("copy.bin").path
        let original = Data((0..<(3 * 1024 * 1024 + 123)).map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index * 31 + (index >> 9)) })
        try original.write(to: source)

        let child = BackendServersSSHProcess(executable: URL(fileURLWithPath: Self.server), arguments: [], environment: ["PATH": "/usr/bin:/bin"])
        try child.start()
        let sftp = try await BackendServersSSHSFTP.open(child)
        defer { sftp.close() }

        try await sftp.put(localPath: source.path, remotePath: copy)
        #expect(FileManager.default.contents(atPath: copy) == original)

        var whole = Data()
        let count = try await sftp.read(copy, from: 0, length: original.count) { whole.append($0) }
        #expect(count == original.count && whole == original)
        #expect(sftp.peakPending > 1, "a transfer waited for each piece in turn")

        var middle = Data()
        _ = try await sftp.read(copy, from: 1000, length: 700_000) { middle.append($0) }
        #expect(middle == original.subdata(in: 1000..<701_000))

        // Asking past the end hands over what is there and stops.
        var tail = Data()
        let last = try await sftp.read(copy, from: original.count - 10, length: 100) { tail.append($0) }
        #expect(last == 10 && tail == original.suffix(10))
    }

    // #511: the folder picker and the Files view read a folder with the same loop: same names, no "." or "..".
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: BackendServersSFTPTransferTests.server)))
    func folderPickerAndFilesViewReadTheSameRows() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-sftp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("x".utf8).write(to: scratch.appendingPathComponent("note.txt"))

        let child = BackendServersSSHProcess(executable: URL(fileURLWithPath: Self.server), arguments: [], environment: ["PATH": "/usr/bin:/bin"])
        try child.start()
        let sftp = try await BackendServersSSHSFTP.open(child)
        defer { sftp.close() }

        let picker = try await sftp.list(scratch.path).sorted { $0.name < $1.name }
        let files = try await sftp.listDetailed(scratch.path).sorted { $0.name < $1.name }
        #expect(picker == [.init(name: "inner", kind: "folder"), .init(name: "note.txt", kind: "file")])
        #expect(files.map(\.name) == picker.map(\.name) && files.map(\.kind) == picker.map(\.kind))
    }
}
