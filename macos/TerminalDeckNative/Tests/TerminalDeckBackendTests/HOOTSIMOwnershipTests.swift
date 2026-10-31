import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class HOOTSIMOwnershipTests: XCTestCase {
    private let folder = "/scratch/hootsim-ownership"
    private func claim(_ instructions: String, file: String = "Sources/Login.swift") -> BackendHOOTSIMOwnership.Claim {
        BackendHOOTSIMOwnership.claim(instructions: instructions, file: file, sourceFolder: folder, ownerFolder: folder)
    }
    func testActualScopeIOwnFormatRecognizesCodePathsAndNotMineSection() {
        let instructions = """
        ## Scope — I own
        - Code: `Sources/Login.swift`, `src/lib/connect/` (auth and quotas).
          `src/app/api/v1/`, `src/jobs/connect-sweep.ts`.
        ## Not mine — hand off to
        - `Sources/Payments.swift` → another owner.
        """
        XCTAssertEqual(claim(instructions), .owns)
        XCTAssertEqual(claim(instructions, file: "src/lib/connect/auth.ts"), .owns)
        XCTAssertEqual(claim(instructions, file: "src/app/api/v1/locations/index.ts"), .owns)
        XCTAssertEqual(claim(instructions, file: "Sources/Payments.swift"), .excludes)
    }
    func testExactOwnsDeclarationAndCanonicalPathUseFullBoundary() {
        XCTAssertEqual(claim("Owns Sources/Login.swift"), .owns)
        XCTAssertEqual(claim("Owns Sources/Login.swift", file: folder + "/Sources/Login.swift"), .owns)
        XCTAssertEqual(claim("Owns src/lib/connect/", file: "src/lib/connect/auth.ts"), .owns)
        XCTAssertEqual(claim("Owns src/lib/connect/", file: "src/lib/connect-other/auth.ts"), .unknown)
        XCTAssertEqual(claim("Owns Sources/Login.swift", file: "Other/Login.swift"), .unknown)
    }
    func testNegativeBorrowedAndConditionalInstructionsNeverBecomeOwnership() {
        for instructions in ["Do not touch Sources/Login.swift", "Never own Sources/Login.swift", "Owns Sources/Login.swift only after another agent's ruling",
            "Owns `Sources/Login.swift` after another agent approves",
            "## Scope — I own\n- In `Sources/Login.swift` (panel-engineer's file), add only my entries."] {
            XCTAssertNotEqual(claim(instructions), .owns)
        }
        XCTAssertEqual(claim("Owns Sources/Login.swift\nDo not touch Sources/Login.swift"), .contradictory)
        XCTAssertEqual(claim("## Scope — I own\n- `Sources/Login.swift`\n## Not mine — hand off to\n- `Sources/Login.swift`"), .contradictory)
    }
    func testMentionsAndUnsupportedGlobsDoNotInventOwnership() {
        XCTAssertEqual(claim("Read Sources/Login.swift before your boot.\n## Lessons\n- Previous bug was in `Sources/Login.swift`."), .unknown)
        XCTAssertEqual(claim("Owns Sources/*.swift"), .unknown)
        XCTAssertEqual(claim("Owns Login.swift", file: "Sources/Login.swift"), .unknown)
        XCTAssertEqual(claim("Owns ../outside/Sources/Login.swift", file: "../outside/Sources/Login.swift"), .unknown)
        XCTAssertEqual(claim("Owns /etc/passwd", file: "/etc/passwd"), .unknown)
    }
    func testSymlinkCannotEscapeTheCurrentSourceFolder() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-ownership-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let inside = temporary.appendingPathComponent("inside"), outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertEqual(BackendHOOTSIMOwnership.claim(instructions: "Owns link/Login.swift", file: "link/Login.swift", sourceFolder: inside.path, ownerFolder: inside.path), .unknown)
    }
    private func resolve(_ instructions: [String], busyFirst: Bool = false) throws -> NativeRPCValue {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: [folder])]
        let agents: [NativeRPCValue] = instructions.enumerated().map { index, instructions in
            .object([.init("id", .string("owner-\(index)")), .init("name", .string("Owner \(index)")),
                     .init("projectId", .string("crm")), .init("defaultProject", .string(folder)),
                     .init("role", .string("Login portal engineer")), .init("instructions", .string(instructions)),
                     .init("sourceFile", .string(folder + "/Sources/Login.swift"))])
        }
        let tasks: [NativeRPCValue] = busyFirst ? [.object([.init("assignee", .string("owner-0")), .init("process", .string("running"))])] : []
        return try BackendHOOTSIMRoutingResolver.resolve(.object([.init("problem", .string("Login portal fails")),
            .init("source", .object([.init("projectId", .string("crm")), .init("folder", .string(folder)), .init("file", .string("Sources/Login.swift"))]))]),
            projects: projects, openFolders: [folder], agents: agents, sessions: [], tasks: tasks)
    }
    func testFileOwnershipDominatesRoleAndSourceDefinitionPathIsNotEvidence() throws {
        let matched = try resolve(["Never touch Sources/Login.swift", "Owns Sources/Login.swift"])
        XCTAssertEqual(matched["target"]["id"].string, "owner-1")
        let unknown = try resolve(["Read Sources/Login.swift before work", ""])
        XCTAssertEqual(unknown["target"]["kind"].string, "task")
    }
    func testDuplicateOwnersAndContradictoryScopeStayTaskOnlyEvenWhenOneIsFree() throws {
        let tie = try resolve(["Owns Sources/Login.swift", "Owns Sources/Login.swift"], busyFirst: true)
        XCTAssertEqual(tie["target"]["kind"].string, "task")
        let contradiction = try resolve(["Owns Sources/Login.swift\nDo not touch Sources/Login.swift", "Owns Sources/Login.swift"])
        XCTAssertEqual(contradiction["target"]["kind"].string, "task")
    }
    func testTrustedFileScopeRejectsSourceEscapeAndKeepsTheActualIcon() throws {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: [folder])]
        let agent = NativeRPCValue.object([.init("id", .string("owner")), .init("name", .string("Owner")),
            .init("projectId", .string("crm")), .init("defaultProject", .string(folder)),
            .init("instructions", .string("Owns Sources/Login.swift")), .init("icon", .string("sf:person.badge.key"))])
        let source = NativeRPCValue.object([.init("projectId", .string("crm")), .init("folder", .string(folder)), .init("file", .string("Sources/Login.swift"))])
        let request = NativeRPCValue.object([.init("problem", .string("Login fails")), .init("source", source)])
        let resolved = try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: [folder], agents: [agent], sessions: [])
        XCTAssertEqual(resolved["target"]["icon"], agent["icon"])
        XCTAssertThrowsError(try BackendHOOTSIMRoutingResolver.resolve(request.setting("source", source.setting("file", .string("../outside/Login.swift"))), projects: projects, openFolders: [folder], agents: [agent], sessions: []))
    }
}
