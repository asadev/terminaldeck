import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 22 Oct (Asad "Fix the host"): the session host sat on 1.5–2.5 cores. Every host request read every session's process
/// first, and the app asked once per session (its transcript setting) on every status change. A request now reads only
/// the session it names, and callers that read no transcript do not ask for one.
final class HostRequestCostTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var asked: [String] = []
        func note(_ id: String) { lock.withLock { asked.append(id) } }
        var ids: [String] { lock.withLock { asked } }
    }

    func testAHostRequestReadsOnlyTheSessionItNames() async throws {
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let counter = Counter()
        for (index, id) in ["a", "b", "c"].enumerated() {
            var input = BackendCreateSessionInput(cwd: "/tmp", provider: "claude"); input.chat = true
            let meta = BackendSessionMeta(id: id, input: input, spawn: .init(provider: "claude", command: "/never-run", args: [], path: "/usr/bin"))
            try manager.registerChat(meta, controls: .init(send: { _ in }, stop: {}, text: { "" },
                pid: { counter.note(id); return Int32(1000 + index) }))
        }
        let probe = BackendHOSTSessionProbe(manager: manager)
        let found = await probe.session("b")
        XCTAssertEqual(found.meta?.id, "b"); XCTAssertEqual(found.pid, 1001)
        XCTAssertEqual(counter.ids, ["b"], "only the named session's process is read")
        let missing = await probe.session("gone")
        XCTAssertNil(missing.meta); XCTAssertNil(missing.pid)
        let rows = await probe.rows()
        XCTAssertEqual(rows.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(counter.ids, ["b"], "listing reads no process")
    }

    func testNoRequestProbesEverySessionAndBusyCallersSkipTranscripts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent("Sources/" + path), encoding: .utf8) }
        for file in ["TerminalDeckBackend/BackendHOSTAccountService.swift", "TerminalDeckBackend/BackendHOSTResources.swift"] {
            XCTAssertFalse(try source(file).contains("rows.compactMap { row in manager.pidOf(row.id)"), "\(file) reads every session's process per request")
        }
        // Hoot's island refreshes on every session status change and reads no transcript.
        XCTAssertTrue(try source("TerminalDeckBackend/BackendHootRegistration.swift").contains("d.lifecycle.metadata(transcripts: false)"))
        let backend = root.appendingPathComponent("Sources")
        for case let file as URL in FileManager.default.enumerator(at: backend, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("lifecycle.metadata().first"), "\(file.lastPathComponent): use metadata(sessionID:) for one session")
        }
    }
}
