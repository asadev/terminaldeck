import Foundation
import Security
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class OneIdentityTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func scratch() throws -> URL {
        let path = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("one-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func run(_ command: String, _ arguments: [String]) throws -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: command); p.arguments = arguments
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    private func requirement(_ id: String) throws -> String {
        let result = try run("/bin/bash", ["-c", "source \"$1\"; td_privacy_requirement \"$2\"", "identity-test", repo.appendingPathComponent("scripts/mac-privacy-signing.sh").path, id])
        XCTAssertEqual(result.0, 0)
        return result.1
    }
    func testProductionRequirementPinsIdentifierAndTeamWithoutVersionPathOrHash() throws {
        let id = "dev.terminaldeck.app.session-host", value = try requirement(id)
        XCTAssertTrue(value.contains("6U4VNX5W87")); XCTAssertTrue(value.contains(id))
        XCTAssertTrue(value.contains("anchor apple generic")); XCTAssertTrue(value.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertFalse(value.contains("cdhash")); XCTAssertFalse(value.contains("host3")); XCTAssertFalse(value.contains("/"))
        var compiled: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(value as CFString, [], &compiled), errSecSuccess)
        XCTAssertNotNil(compiled)
    }
    func testSigningStepKeepsRequirementAndIdentifierAcrossVersionedPaths() throws {
        let script = repo.appendingPathComponent("scripts/mac-privacy-signing.sh").path
        let result = try run("/bin/bash", ["-c", """
        source "$1"
        codesign() { printf '%s\\n' "$@"; }
        IDENTITY=fixture
        SIGN=(codesign --force --sign fixture)
        td_sign_privacy_helper /scratch/0.21.2/Helper dev.terminaldeck.app.session-host /scratch/entitlements
        td_sign_privacy_helper /scratch/0.21.3/Helper dev.terminaldeck.app.session-host /scratch/entitlements
        """, "identity-test", script])
        XCTAssertEqual(result.0, 0)
        let lines = result.1.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0 == "--identifier" }.count, 2)
        XCTAssertEqual(lines.filter { $0 == "dev.terminaldeck.app.session-host" }.count, 2)
        let requirements = lines.filter { $0.hasPrefix("=designated => ") }
        XCTAssertEqual(requirements.count, 2); XCTAssertEqual(requirements.first, requirements.last)
        XCTAssertEqual(lines.filter { $0.hasPrefix("-R=identifier") && $0.contains("6U4VNX5W87") }.count, 2)
    }
    func testScratchPackagingPreparesItsOwnIdentityAndKeepsUsageDescriptions() throws {
        let root = try scratch(), output = root.appendingPathComponent("Scratch-Info.plist")
        let script = repo.appendingPathComponent("scripts/mac-privacy-metadata.py").path
        let source = repo.appendingPathComponent("macos/TerminalDeckNative/Support/SessionHost-Info.plist").path
        let prepared = try run("/usr/bin/python3", [script, "--prepare", source, output.path, "dev.terminaldeck.identity-test", "Identity Test"])
        XCTAssertEqual(prepared.0, 0, prepared.1)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: output), format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "dev.terminaldeck.identity-test.session-host")
        XCTAssertEqual(info["CFBundleName"] as? String, "Identity Test")
        XCTAssertNotNil(info["NSMicrophoneUsageDescription"])
        XCTAssertEqual(try run("/usr/bin/python3", [script, "--prepare", source, output.path, "../invalid", "Identity Test"]).0, 1)
    }
    func testBuiltKeeperMetadataMatchesReleaseAndRejectsScratchMismatch() throws {
        let helper = Bundle(for: OneIdentityTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TerminalDeckSessionHostHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let validator = repo.appendingPathComponent("scripts/mac-privacy-metadata.py").path
        let correct = try run("/usr/bin/python3", [validator, helper.path, "dev.terminaldeck.app.session-host"])
        XCTAssertEqual(correct.0, 0, correct.1)
        XCTAssertNotEqual(try run("/usr/bin/python3", [validator, helper.path, "dev.terminaldeck.scratch.session-host"]).0, 0)
    }
    func testTwoChangedVersionsCrossMatchScratchDRButCannotSatisfyProductionTeam() throws {
        let root = try scratch(), id = "dev.terminaldeck.identity-test." + UUID().uuidString.lowercased()
        var binaries: [URL] = []
        for (version, source) in [("0.21.2", "/usr/bin/true"), ("0.21.3", "/usr/bin/false")] {
            let dir = root.appendingPathComponent(version); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let binary = dir.appendingPathComponent("Helper")
            try FileManager.default.copyItem(atPath: source, toPath: binary.path)
            // Test-only identity matching; NEVER used by the release signing function.
            let signed = try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", id, "--requirements", "=designated => identifier \"\(id)\"", binary.path])
            XCTAssertEqual(signed.0, 0, signed.1); binaries.append(binary)
        }
        XCTAssertNotEqual(try Data(contentsOf: binaries[0]), try Data(contentsOf: binaries[1]))
        let first = try run("/usr/bin/codesign", ["-d", "-r-", binaries[0].path]).1.split(separator: "\n").first { $0.hasPrefix("designated =>") }
        let second = try run("/usr/bin/codesign", ["-d", "-r-", binaries[1].path]).1.split(separator: "\n").first { $0.hasPrefix("designated =>") }
        XCTAssertEqual(first, second); XCTAssertNotNil(first)
        let production = try requirement("dev.terminaldeck.app.session-host")
        for binary in binaries {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--strict", "-R=identifier \"\(id)\"", binary.path]).0, 0)
            XCTAssertNotEqual(try run("/usr/bin/codesign", ["--verify", "-R=" + production, binary.path]).0, 0)
            XCTAssertNotEqual(try run("/usr/bin/codesign", ["--verify", "-R=identifier \"wrong.identifier\"", binary.path]).0, 0)
        }
    }
    func testKeeperHasEmbeddedMetadataAndPackagingSignsThePinnedIdentity() throws {
        let plist = try Data(contentsOf: repo.appendingPathComponent("macos/TerminalDeckNative/Support/SessionHost-Info.plist"))
        let value = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(value["CFBundleIdentifier"] as? String, "dev.terminaldeck.app.session-host")
        XCTAssertEqual(value["CFBundleName"] as? String, "Terminal Deck")
        for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSAppleEventsUsageDescription", "NSLocalNetworkUsageDescription"] { XCTAssertFalse((value[key] as? String ?? "").isEmpty) }
        let package = try String(contentsOf: repo.appendingPathComponent("macos/TerminalDeckNative/Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("__info_plist")); XCTAssertTrue(package.contains("-sectcreate"))
        let build = try String(contentsOf: repo.appendingPathComponent("macos/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("td_sign_privacy_helper")); XCTAssertTrue(build.contains("$PRIVACY_APP_ID.session-host"))
    }
    func testProductionCoreAndAgentsAssociateWithAppButScratchNeverDoes() throws {
        let root = try scratch()
        let production = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminaldeck")
        // Planning only: no directory creation or launchctl calls on production paths.
        for namespace: String? in [nil, "agents"] {
            let paths = try BackendHOSTPaths(dataDirectory: production, namespace: namespace)
            for version in ["v1", "v2"] {
                let plan = try BackendHOSTLaunchAgent(paths: paths, version: version, launchAgentsDirectory: root)
                let raw = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.propertyList(), format: nil) as? [String: Any])
                XCTAssertEqual(raw["AssociatedBundleIdentifiers"] as? [String], ["dev.terminaldeck.app"])
            }
        }
        let scratchPlan = try BackendHOSTLaunchAgent(paths: BackendHOSTPaths(dataDirectory: root), version: "v1", launchAgentsDirectory: root)
        let raw = try XCTUnwrap(PropertyListSerialization.propertyList(from: scratchPlan.propertyList(), format: nil) as? [String: Any])
        XCTAssertNil(raw["AssociatedBundleIdentifiers"])
    }
    func testCleanupGuideIsManualAndListsEveryRequestedPrivacyService() {
        XCTAssertEqual(BackendDeckCoreCatalogueDescribe.areaOf("privacy.cleanup_guide"), "app")
        XCTAssertEqual(BackendPrivacyIdentity.guide["automaticResetAvailable"], .bool(false))
        XCTAssertEqual(Set(BackendPrivacyIdentity.panes.map(\.id)), Set(["screen", "accessibility", "automation", "files", "disk", "camera", "microphone", "network"]))
        XCTAssertTrue(BackendPrivacyIdentity.cleanupSteps.joined().contains("Keep Terminal Deck and every other app"))
        XCTAssertTrue(BackendPrivacyIdentity.panes.allSatisfy { $0.url.scheme == "x-apple.systempreferences" })
    }
}

@MainActor
final class OneIdentityMCPTests: XCTestCase {
    private func context(_ tiers: Set<BackendMCPTier> = [.read, .act]) -> BackendMCPCallContext {
        .init(sessionID: "identity-test", machineID: "", projectRoot: nil, attended: true,
              allowedTools: ["privacy.cleanup_guide", "privacy.open_settings"], allowedTiers: tiers, cancellation: .init())
    }
    private func access(_ opened: OneIdentityAudit, deny: Bool = false) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: .local) }, knownFolder: { _, root in root }, session: { _, _ in .null }, runnableProject: { _, root in root },
              rpc: { _ in .init(caller: .nativeApp, ownerID: "identity-test") },
              authorize: { _, _, _, tier, _, owner in
                  await opened.authorize(tier: tier, owner: owner)
                  if deny { throw NativeRPCError(code: "not-approved", message: "Declined") }
              }, record: { _, _, _, _ in })
    }
    func testGuideReadsWithoutOpeningSettingsAndOpenAsksOwner() async throws {
        let audit = OneIdentityAudit()
        let defs = try BackendPrivacyMCP.definitions(access: access(audit), openSettings: { _ in await audit.open(); return true })
        let read = try XCTUnwrap(defs.first { $0.spec.id == "privacy.cleanup_guide" })
        let guide = try await read.handler(context(), .object([]))
        XCTAssertFalse(guide.isError)
        let afterRead = await audit.opens; XCTAssertEqual(afterRead, 0)
        let open = try XCTUnwrap(defs.first { $0.spec.id == "privacy.open_settings" })
        let result = try await open.handler(context(), .object([.init("pane", .string("screen"))]))
        XCTAssertFalse(result.isError)
        let opens = await audit.opens, owner = await audit.owner
        XCTAssertEqual(opens, 1); XCTAssertTrue(owner)
    }
    func testRegistrarAcceptsWholePrivacyFamilyAndRejectsHalfWithoutMutation() async throws {
        let server = BackendNativeMCPServer(), audit = OneIdentityAudit()
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        let privacy = try BackendPrivacyMCP.definitions(access: access(audit), openSettings: { _ in await audit.open(); return true })
        let installed = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + privacy)
        XCTAssertTrue(BackendPrivacyMCP.toolIDs.isSubset(of: Set(installed.toolIDs)))
        let before = Set(await server.registrations().map { $0.0.id })
        do {
            _ = try await BackendDeckToolsRegistration.register(on: server, definitions: baseline + [privacy[0]])
            XCTFail("A partial privacy family was accepted")
        } catch { }
        let after = Set(await server.registrations().map { $0.0.id })
        XCTAssertEqual(before, after)
    }
    func testDeniedReadOnlyCancelledAndInjectedArgumentsNeverOpenSettings() async throws {
        let audit = OneIdentityAudit()
        let defs = try BackendPrivacyMCP.definitions(access: access(audit, deny: true), openSettings: { _ in await audit.open(); return true })
        let open = try XCTUnwrap(defs.first { $0.spec.id == "privacy.open_settings" })
        let good = NativeRPCValue.object([.init("pane", .string("screen"))])
        for (ctx, args) in [(context(), good), (context([.read]), good), (context(), good.setting("approved", .bool(true))), (context(), .object([.init("pane", .string("https://example.com"))]))] {
            let result = try await open.handler(ctx, args); XCTAssertTrue(result.isError)
        }
        let cancelled = context(); cancelled.cancellation.cancel()
        let reply = try await open.handler(cancelled, good); XCTAssertTrue(reply.isError)
        let opens = await audit.opens; XCTAssertEqual(opens, 0)
    }
}

private actor OneIdentityAudit {
    var opens = 0
    var owner = false
    func open() { opens += 1 }
    func authorize(tier: BackendMCPTier, owner: Bool) { self.owner = owner }
}
