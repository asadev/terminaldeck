import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class PROJSessionIdentityTests: PROJMadeUpTestCase, @unchecked Sendable {
    func testLegacySessionInputAndMetadataDecodeWithoutProjectField() throws {
        let input = try JSONDecoder().decode(BackendCreateSessionInput.self, from: Data(#"{"cwd":"/work/crm","cols":100,"rows":30,"provider":"shell"}"#.utf8))
        XCTAssertNil(input.projectId); XCTAssertEqual(input.resolvedProjectID, "crm")
        let meta = try JSONDecoder().decode(BackendSessionMeta.self, from: Data(#"{"id":"fixture","cwd":"/work/imatch","title":"Old","provider":"shell","exitCode":null,"createdAt":0,"resumed":false}"#.utf8))
        XCTAssertNil(meta.projectId); XCTAssertEqual(meta.resolvedProjectID, "imatch")
        let encoded = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
        XCTAssertFalse(encoded.has("projectId"))
    }

    func testExplicitIndependentInputMetadataAndSavedRestoreCopiesRetainIdentity() throws {
        var input = BackendCreateSessionInput(cwd: "/work/crm", provider: "shell")
        input.projectId = "independent"
        let meta = BackendSessionMeta(id: "fixture", input: input, spawn: .init(provider: "shell", command: "/bin/sh", args: [], path: "/usr/bin"), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(meta.projectId, "independent"); XCTAssertEqual(meta.resolvedProjectID, "independent")
        let roundTrip = try JSONDecoder().decode(BackendSessionMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(roundTrip, meta)
        let raw = BackendSessionSaved.from(input)
        XCTAssertEqual(raw["projectId"].string, "independent")
        let restored = try BackendSessionSaved(raw).input(resume: true)
        XCTAssertEqual(restored.projectId, "independent"); XCTAssertEqual(restored.resolvedProjectID, "independent")
        XCTAssertEqual(restored.cwd, input.cwd)
    }

    func testLegacySavedInputFallsBackAndUnknownExplicitIdentitySurvives() throws {
        let legacy = try BackendSessionSaved(.object([.init("cwd", .string("/work/crm")), .init("provider", .string("shell"))])).input(resume: true)
        XCTAssertNil(legacy.projectId); XCTAssertEqual(legacy.resolvedProjectID, "crm")
        var future = BackendCreateSessionInput(cwd: "/outside", provider: "shell"); future.projectId = "custom-team"
        let restored = try BackendSessionSaved(BackendSessionSaved.from(future)).input(resume: false)
        XCTAssertEqual(restored.projectId, "custom-team"); XCTAssertEqual(restored.resolvedProjectID, "custom-team")
    }

    func testMCPSchemaAndInputForwardIdentityWithoutLaunchingAnything() async throws {
        let spec = try XCTUnwrap(BackendDeckCoreCatalogueLiterals.builtins().first { $0.tool.id == "sessions.start" }?.tool)
        XCTAssertEqual(spec.inputSchema["properties"]["projectId"]["type"].string, "string")
        XCTAssertFalse(spec.inputSchema["required"].elements?.contains(.string("projectId")) ?? true)
        XCTAssertEqual(spec.tier, .act)
        let native = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
                                          allowedTools: ["sessions.start"], allowedTiers: [.act], cancellation: .init())
        let context = BackendDeckCoreSecurityCallContext(native: native, caller: .local, callID: "fixture", attended: true, granted: nil,
                                                        sessionLimits: .missing, now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
        let surface = PROJSessionIdentitySurface()
        let args = NativeRPCValue.object([.init("cwd", .string("/work/crm")), .init("provider", .string("shell")), .init("projectId", .string("independent"))])
        _ = try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.start", arguments: args, context: context, surface: surface)
        let explicit = try JSONDecoder().decode(BackendCreateSessionInput.self, from: surface.input().encodedJSON())
        XCTAssertEqual(explicit.projectId, "independent"); XCTAssertEqual(explicit.resolvedProjectID, "independent")
        _ = try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.start", arguments: args.removing("projectId"), context: context, surface: surface)
        let old = try JSONDecoder().decode(BackendCreateSessionInput.self, from: surface.input().encodedJSON())
        XCTAssertNil(old.projectId); XCTAssertEqual(old.resolvedProjectID, "crm")
        // Asad 12 Oct: Hoot may open any folder.
        XCTAssertNoThrow(try BackendDeckCoreCatalogueBuiltins.checkStart(surface: surface, context: context,
                             arguments: args.setting("cwd", .string("/etc"))))
        XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkStart(surface: surface, context: context,
                             arguments: args.setting("cwd", .string("/not-an-open-folder")))) { error in
            XCTAssertTrue(error.localizedDescription.contains("that folder doesn't exist"))
        }
        for kind in [BackendDeckCoreSecurityCaller.Kind.key, .session, .remote] {
            let restricted = BackendDeckCoreSecurityCallContext(native: native, caller: .init(kind: kind, tiers: [.act]),
                callID: "restricted", attended: true, granted: nil, sessionLimits: .missing,
                now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkStart(surface: surface, context: restricted,
                                 arguments: args.setting("cwd", .string("/etc")))) { error in
                XCTAssertTrue(error.localizedDescription.contains("not a folder this app has open"), "\(kind)")
            }
        }
    }
}

/// Only an in-memory serializer sink. No process, app, file, terminal or network call.
private final class PROJSessionIdentitySurface: BackendDeckCoreCatalogueSurface, @unchecked Sendable {
    private let lock = NSLock()
    private var last = NativeRPCValue.missing
    func input() -> NativeRPCValue { lock.withLock { last } }
    func listSessions() -> [NativeRPCValue] { [] }
    func listProjects() -> [NativeRPCValue] { [.object([.init("path", .string("/work/crm"))])] }
    func sessionStatus(_ sessionID: String) -> NativeRPCValue { .null }
    func appStateRoot() -> String { "/fixture.noindex/state" }
    func copilotRoot() -> String { "/fixture.noindex/copilot" }
    func windows(sessionID: String) -> [NativeRPCValue] { [] }
    func readSettings() -> NativeRPCValue { .object([]) }
    func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue {
        lock.withLock { last = input }
        return input.setting("id", .string("fixture")).setting("title", .string("Fixture")).setting("createdAt", .number(0)).setting("exitCode", .null)
    }
}
