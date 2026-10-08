import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsDeployTests: XCTestCase, @unchecked Sendable {
    func testDeployKeepsCredentialOutOfCommandsAndUsesPrivateCandidate() async throws {
        let fake = BackendAppsDeployFake()
        let deploy = await fake.service()
        let result = try await deploy.deploy(serverID: "fixture", appID: "demo")
        let snapshot = await fake.snapshot()
        XCTAssertEqual(result["status"].string, "running")
        XCTAssertEqual(snapshot.record["activeDeploymentId"], result["id"])
        XCTAssertTrue(snapshot.commands.allSatisfy { !$0.contains(BackendAppsDeployFake.token) })
        XCTAssertEqual(snapshot.cloneInput, Data(BackendAppsDeployFake.token.utf8))
        XCTAssertEqual(snapshot.candidate["HostConfig"]["NetworkMode"].string, "terminaldeck-apps")
        XCTAssertEqual(snapshot.candidate["HostConfig"]["PortBindings"].fields?.count, 0)
        XCTAssertNil(snapshot.candidate["HostConfig"]["Privileged"].bool)
        XCTAssertFalse(snapshot.events.contains("remove-old"))
        XCTAssertFalse(result.compact.contains(BackendAppsDeployFake.token))
        XCTAssertTrue(snapshot.events.firstIndex(of: "intent")! < snapshot.events.firstIndex(of: "route-candidate")!)
        XCTAssertTrue(snapshot.events.firstIndex(of: "route-candidate")! < snapshot.events.firstIndex(of: "commit")!)
        XCTAssertTrue(snapshot.events.firstIndex(of: "commit")! < snapshot.events.firstIndex(of: "stop-old")!)
        XCTAssertFalse(snapshot.previousRunning)
        XCTAssertEqual(result["cleanupNeeded"].bool, false)
    }

    func testFailedHealthDoesNotChangeServingRoute() async throws {
        let fake = BackendAppsDeployFake(unhealthy: true)
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Unhealthy app deployed") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "health-failed") }
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.record["activeDeploymentId"].string, "terminaldeck-deploy-old")
        XCTAssertFalse(snapshot.events.contains("route-candidate"))
        XCTAssertTrue(snapshot.events.contains("remove-candidate"))
        XCTAssertFalse(snapshot.events.contains("remove-old"))
        XCTAssertTrue(snapshot.previousRunning)
        XCTAssertFalse(snapshot.events.contains("stop-old"))
    }

    func testFailedStateCommitRestoresOldRouteAndRetainsOldInstance() async throws {
        let fake = BackendAppsDeployFake(failCommit: true)
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Unsaved app deployed") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-failed") }
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.route["handle"].elements?.first?["upstreams"].elements?.first?["dial"].string, "172.19.0.2:8080")
        XCTAssertEqual(snapshot.record["activeDeploymentId"].string, "terminaldeck-deploy-old")
        XCTAssertTrue(snapshot.events.contains("route-candidate"))
        XCTAssertTrue(snapshot.events.contains("route-old"))
        XCTAssertTrue(snapshot.events.contains("remove-candidate"))
        XCTAssertFalse(snapshot.events.contains("remove-old"))
        XCTAssertTrue(snapshot.previousRunning)
        XCTAssertFalse(snapshot.events.contains("stop-old"))
    }

    func testLostSwapResponseIsCompensatedEvenIfRouteAlreadyChanged() async throws {
        let fake = BackendAppsDeployFake(loseSwapResponse: true)
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Lost route response accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "route-failed") }
        let snapshot = await fake.snapshot()
        XCTAssertTrue(snapshot.events.contains("route-candidate"))
        XCTAssertTrue(snapshot.events.contains("route-old"))
        XCTAssertEqual(snapshot.record["activeDeploymentId"].string, "terminaldeck-deploy-old")
    }

    func testRollbackUsesRetainedImageWithoutRebuildingOrCloning() async throws {
        let fake = BackendAppsDeployFake()
        let deploy = await fake.service()
        let result = try await deploy.rollback(serverID: "fixture", appID: "demo", deploymentID: "terminaldeck-deploy-old")
        let snapshot = await fake.snapshot()
        XCTAssertEqual(result["rollbackOf"].string, "terminaldeck-deploy-old")
        XCTAssertEqual(snapshot.candidate["Image"].string, BackendAppsDeployFake.oldImage)
        XCTAssertNil(snapshot.cloneInput)
        XCTAssertFalse(snapshot.commands.contains { $0.contains("docker build") || $0.contains("git ") })
    }

    func testUncertainRouteRetainsBothInstancesAndDurableIntent() async throws {
        let fake = BackendAppsDeployFake(loseSwapResponse: true, failOldRoute: true)
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Uncertain route succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "route-failed") }
        let snapshot = await fake.snapshot()
        XCTAssertFalse(snapshot.record["pendingDeploymentId"].isNullish)
        XCTAssertFalse(snapshot.events.contains("remove-candidate"))
        XCTAssertFalse(snapshot.events.contains("remove-old"))
    }

    func testFailureCompensationKeepsApprovedTaskLocalAuthority() async throws {
        let fake = BackendAppsDeployFake(failCommit: true, requireCallContext: true)
        let deploy = await fake.service()
        try await BackendAppsDeployFakeCallContext.$owner.withValue("approved-fixture") {
            do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Unsaved app deployed") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-failed") }
        }
        let snapshot = await fake.snapshot()
        XCTAssertTrue(snapshot.events.contains("route-old"))
        XCTAssertTrue(snapshot.events.contains("remove-candidate"))
        XCTAssertFalse(snapshot.events.contains("remove-old"))
    }

    func testApprovedOlderPushRevisionIsFetchedCheckedOutVerifiedAndBuilt() async throws {
        let fake = BackendAppsDeployFake()
        let deploy = await fake.service()
        let approved = BackendAppsDeployFake.olderRevision
        let result = try await deploy.deploy(serverID: "fixture", appID: "demo", revision: approved.uppercased())
        let snapshot = await fake.snapshot()
        XCTAssertNotEqual(BackendAppsDeployFake.branchHead, approved)
        XCTAssertEqual(snapshot.fetchedRevisions, [approved])
        XCTAssertEqual(snapshot.checkedOutRevision, approved)
        XCTAssertEqual(snapshot.builtRevision, approved)
        XCTAssertEqual(result["commit"].string, approved)
        XCTAssertEqual(result["requestedRevision"].string, approved)
        XCTAssertEqual(snapshot.cloneInput, Data(BackendAppsDeployFake.token.utf8))
        XCTAssertFalse(snapshot.commands.contains { $0.contains(BackendAppsDeployFake.token) })
        XCTAssertTrue(snapshot.events.contains("route-candidate"))
    }

    func testExactRevisionMismatchStopsBeforeBuildAndRoute() async throws {
        let fake = BackendAppsDeployFake(ignoreExactCheckout: true)
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo", revision: BackendAppsDeployFake.olderRevision); XCTFail("Newer branch head replaced approved push") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "build-failed"); XCTAssertTrue(error.message.contains("does not match")) }
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.fetchedRevisions, [BackendAppsDeployFake.olderRevision])
        XCTAssertNil(snapshot.builtRevision)
        XCTAssertFalse(snapshot.events.contains("create-candidate"))
        XCTAssertFalse(snapshot.events.contains("route-candidate"))
        XCTAssertEqual(snapshot.record["activeDeploymentId"].string, "terminaldeck-deploy-old")
    }

    func testRejectedShallowRevisionFetchIsExplicitAndNeverBuildsBranchHead() async throws {
        let fake = BackendAppsDeployFake(rejectRevisionFetch: true)
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo", revision: BackendAppsDeployFake.olderRevision); XCTFail("Unavailable older push silently fell back to branch head") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "build-failed"); XCTAssertTrue(error.message.contains("shallow fetch")); XCTAssertFalse(error.message.contains(BackendAppsDeployFake.token)) }
        let snapshot = await fake.snapshot()
        XCTAssertNil(snapshot.builtRevision)
        XCTAssertFalse(snapshot.events.contains("route-candidate"))
        XCTAssertEqual(snapshot.record["activeDeploymentId"].string, "terminaldeck-deploy-old")
    }

    func testInvalidRevisionRefusesBeforeAnyServerIOAndTemplatesRejectRevision() async throws {
        for invalid in [String(repeating: "a", count: 39), String(repeating: "a", count: 41), String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 40), "main; execute-something"] {
            let fake = BackendAppsDeployFake(), deploy = await fake.service()
            do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo", revision: invalid); XCTFail("Invalid revision accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
            let state = await fake.snapshot()
            XCTAssertTrue(state.commands.isEmpty)
            XCTAssertTrue(state.events.isEmpty)
        }
        let fake = BackendAppsDeployFake()
        await fake.setSource(.object([.init("kind", .string("template")), .init("templateId", .string("uptime-kuma"))]))
        let deploy = await fake.service()
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo", revision: BackendAppsDeployFake.olderRevision); XCTFail("Template accepted a GitHub revision") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let state = await fake.snapshot()
        XCTAssertNil(state.cloneInput)
        XCTAssertNil(state.builtRevision)
        XCTAssertFalse(state.events.contains("route-candidate"))
    }

    func testPushBindingChangesAtLockAcquisitionPreventBuildRowsAndServerAPIs() async throws {
        let source = BackendAppsValidation.object([("kind", .string("github")), ("repository", .string("example/demo")), ("branch", .string("main"))])
        let changes = [
            NativeRPCValue.object([.init("autoDeploy", .bool(false))]),
            .object([.init("pendingAutoDeploy", .object([.init("phase", .string("changing"))]))]),
            .object([.init("source", source.setting("repository", .string("other/demo")))]),
            .object([.init("source", source.setting("branch", .string("other")))]),
            .object([.init("source", .object([.init("kind", .string("template"))]))])
        ]
        let push = try verifiedPush()
        for change in changes {
            let fake = BackendAppsDeployFake(acquisitionChange: change)
            let deploy = await fake.service()
            do { _ = try await deploy.deployPush(serverID: "fixture", appID: "demo", push: push); XCTFail("Push binding change ignored") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "conflict") }
            let state = await fake.snapshot()
            XCTAssertTrue(state.events.contains("lock"))
            XCTAssertFalse(state.events.contains("build-row"))
            XCTAssertNil(state.cloneInput)
            XCTAssertNil(state.builtRevision)
            XCTAssertEqual(state.dockerCalls, 0)
            XCTAssertFalse(state.events.contains("route-candidate"))
        }
    }

    func testBoundPushDeploysExactRevisionWhileHoldingSameAppLock() async throws {
        let fake = BackendAppsDeployFake()
        let deploy = await fake.service()
        let result = try await deploy.deployPush(serverID: "fixture", appID: "demo", push: verifiedPush())
        let state = await fake.snapshot()
        XCTAssertEqual(result["commit"].string, BackendAppsDeployFake.olderRevision)
        XCTAssertEqual(state.builtRevision, BackendAppsDeployFake.olderRevision)
        XCTAssertEqual(state.events.filter { $0 == "lock" }.count, 1)
        XCTAssertTrue(state.events.firstIndex(of: "lock")! < state.events.firstIndex(of: "build-row")!)
        XCTAssertTrue(state.events.firstIndex(of: "stop-old")! < state.events.firstIndex(of: "unlock")!)
    }

    func testPreviousStopFailureWarnsWithoutUndoingDurableDeploy() async throws {
        let fake = BackendAppsDeployFake(failPreviousStop: true)
        let deploy = await fake.service()
        let result = try await deploy.deploy(serverID: "fixture", appID: "demo")
        let state = await fake.snapshot()
        XCTAssertEqual(result["status"].string, "running")
        XCTAssertEqual(state.record["activeDeploymentId"], result["id"])
        XCTAssertTrue(state.previousRunning)
        XCTAssertEqual(result["cleanupNeeded"].bool, true)
        XCTAssertEqual(result["cleanupNeededIds"], .array([.string(BackendAppsDeployFake.previousID)]))
        XCTAssertEqual(state.record["cleanupNeededContainers"], result["cleanupNeededIds"])
        XCTAssertFalse(result["warnings"].elements?.isEmpty ?? true)
        XCTAssertFalse(state.events.contains("route-old"))
        XCTAssertFalse(state.events.contains("remove-candidate"))
    }

    func testUnownedPreviousInstanceNeverStopsAndCleanupCapacityIsBounded() async throws {
        let fake = BackendAppsDeployFake(unownedPrevious: true)
        let deploy = await fake.service()
        let result = try await deploy.deploy(serverID: "fixture", appID: "demo")
        let state = await fake.snapshot()
        XCTAssertTrue(state.previousRunning)
        XCTAssertEqual(result["cleanupNeeded"].bool, true)
        XCTAssertFalse(state.events.contains("stop-old-attempt"))
        let full = BackendAppsDeployFake()
        await full.patchRecord(.object([.init("cleanupNeededContainers", .array((0..<8).map { .string("pending-\($0)") }))]))
        let fullDeploy = await full.service()
        do { _ = try await fullDeploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Full cleanup queue grew") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "busy") }
        let fullState = await full.snapshot()
        XCTAssertEqual(fullState.dockerCalls, 0)
        XCTAssertNil(fullState.cloneInput)
    }

    func testCleanupMetadataSaveFailureDoesNotUndoSuccessfulDeploy() async throws {
        let fake = BackendAppsDeployFake(failCleanupSave: true)
        let deploy = await fake.service()
        let result = try await deploy.deploy(serverID: "fixture", appID: "demo")
        let state = await fake.snapshot()
        XCTAssertEqual(result["status"].string, "running")
        XCTAssertEqual(state.record["activeDeploymentId"], result["id"])
        XCTAssertFalse(state.previousRunning)
        XCTAssertEqual(result["cleanupStateSaved"].bool, false)
        XCTAssertFalse(result["warnings"].elements?.isEmpty ?? true)
        XCTAssertEqual(state.record["cleanupNeededContainers"], .array([.string(BackendAppsDeployFake.previousID)]))
        XCTAssertFalse(state.events.contains("route-old"))
        XCTAssertFalse(state.events.contains("remove-candidate"))
    }

    func testLostCreateReplyUsesSealedCandidateCleanupAfterOrdinaryAuthorityExpires() async throws {
        let fake = BackendAppsDeployFake(loseCreateReply: true)
        let recovery = await fake.recoveryController()
        let deploy = await fake.service(recovery: recovery)
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Lost create acknowledgement succeeded") }
        catch is CancellationError { }
        do { _ = try await fake.execute("ordinary-after-expiry", nil); XCTFail("Expired ordinary callback accepted I/O") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        let state = await fake.snapshot()
        XCTAssertFalse(state.candidateExists)
        XCTAssertTrue(state.events.contains("remove-candidate-recovery"))
        XCTAssertEqual(state.candidate["Labels"]["io.terminaldeck.transaction"].string, state.recoveryOwner)
        XCTAssertTrue(state.events.firstIndex(of: "sealed:remove-transaction-candidates")! < state.events.firstIndex(of: "create-candidate")!)
        XCTAssertTrue(state.capturedIOCalls > 0)
        XCTAssertTrue(state.ordinaryDeniedCalls > 0)
        XCTAssertEqual(state.closedLeases, 1)
        XCTAssertTrue(state.previousRunning)
        XCTAssertTrue(state.hashVerifications > 0)
        XCTAssertTrue(state.allRouteChecks > 0)
        // Injected transport proof only; DKA verifies actual mutation receipts.
    }

    func testLateStateFailureUsesCapturedRouteAndFileBeforeCandidateCleanup() async throws {
        let fake = BackendAppsDeployFake(expireOnCommit: true)
        let recovery = await fake.recoveryController()
        let deploy = await fake.service(recovery: recovery)
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("Expired failed commit succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-failed") }
        let state = await fake.snapshot()
        XCTAssertEqual(state.record["activeDeploymentId"].string, "terminaldeck-deploy-old")
        XCTAssertTrue(state.record["pendingDeploymentId"].isNullish)
        XCTAssertTrue(state.previousRunning)
        XCTAssertFalse(state.candidateExists)
        XCTAssertTrue(state.events.contains("route-old"))
        XCTAssertTrue(state.events.contains("remove-candidate-recovery"))
        XCTAssertTrue(state.events.firstIndex(of: "route-old")! < state.events.firstIndex(of: "remove-candidate-recovery")!)
        XCTAssertEqual(state.closedLeases, 1)
        XCTAssertTrue(state.hashVerifications > 0)
        XCTAssertTrue(state.allRouteChecks > 0)
    }

    private func verifiedPush() throws -> BackendAppsVerifiedPush {
        let secret = Data("fixture-approved-push-secret-32-bytes".utf8)
        let body = try BackendAppsValidation.object([
            ("ref", .string("refs/heads/main")), ("after", .string(BackendAppsDeployFake.olderRevision)), ("deleted", .bool(false)),
            ("repository", .object([.init("id", .number(12)), .init("full_name", .string("example/demo"))])),
            ("sender", .object([.init("id", .number(34)), .init("login", .string("owner"))]))
        ]).encodedJSON()
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
        let headers: [BackendAppsPushHeader] = [.init("X-GitHub-Event", "push"), .init("X-GitHub-Delivery", "12345678-2222-4333-8444-555555555555"), .init("X-Hub-Signature-256", "sha256=" + signature), .init("Content-Type", "application/json")]
        return try BackendAppsPushVerifier.verify(headers: headers, body: body, secret: secret, target: .init(repository: "example/demo", branch: "main"))
    }

    func testUnwiredRuntimeAndUnsafeComposeFailClearly() async throws {
        let runtime = BackendAppsRuntime(execute: { _, _, _, _, _ in throw BackendAppsRuntime.unavailable("Not connected") })
        let service = BackendAppsDeploy(runtime: runtime, store: .init(runtime: runtime), caddy: .init(runtime: runtime))
        do { _ = try await service.deploy(serverID: "fixture", appID: "demo"); XCTFail("Missing connection succeeded") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        for key in ["ports", "volumes", "privileged", "network_mode", "pid", "devices", "depends_on", "env_file", "extends", "configs", "secrets"] {
            let json = BackendAppsValidation.object([("services", BackendAppsValidation.object([
                ("web", BackendAppsValidation.object([("build", .string(".")), (key, .string("unsafe"))]))
            ]))])
            XCTAssertThrowsError(try BackendAppsDeployPlan.compose(json, service: "web", port: 8080), key)
        }
    }

    func testCRLFClusterCredentialAndBuildPathAreRejectedBeforeClone() async throws {
        let fake = BackendAppsDeployFake()
        let deploy = await fake.service(credential: "fixture-token\r\ninjected-line")
        do { _ = try await deploy.deploy(serverID: "fixture", appID: "demo"); XCTFail("A multiline askpass credential was accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let state = await fake.snapshot()
        XCTAssertNil(state.cloneInput)
        XCTAssertNil(state.builtRevision)
        XCTAssertFalse(state.commands.contains { $0.contains("git ") })
        XCTAssertThrowsError(try BackendAppsDeploy.relative("Dockerfile\r\nother-file"))
    }

    func testComposeRequiresLocalBuildAndRejectsExternalPathsAndUnmanagedResources() throws {
        func compose(_ context: String, extra: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
            BackendAppsValidation.object([("services", BackendAppsValidation.object([
                ("web", BackendAppsValidation.object([("build", .string(context))]))
            ]))] + extra)
        }
        let safe = try BackendAppsDeployPlan.compose(compose("app"), service: "web", port: 8080)
        XCTAssertEqual(safe.context, "app")
        XCTAssertEqual(safe.port, 8080)
        for context in ["../outside", "/etc", "https://github.com/other/repo", "app/../../etc", "app\\outside"] {
            XCTAssertThrowsError(try BackendAppsDeployPlan.compose(compose(context), service: "web", port: 8080), context)
        }
        XCTAssertThrowsError(try BackendAppsDeployPlan.compose(compose(".", extra: [("volumes", .object([]))]), service: "web", port: 8080))
        XCTAssertThrowsError(try BackendAppsDeployPlan.compose(compose("."), service: nil, port: 8080))
        XCTAssertThrowsError(try BackendAppsDeployPlan.compose(compose("."), service: "web", port: nil))
        let source = BackendAppsValidation.object([("kind", .string("github")), ("repository", .string("example/demo"))])
        XCTAssertNil(try BackendAppsDeploySource(source).branch)
        XCTAssertThrowsError(try BackendAppsDeploySource(source.setting("branch", .object([.init("apiKey", .string("secret"))]))))
        XCTAssertThrowsError(try BackendAppsDeploySource(source.setting("repository", .string("../.."))))
        XCTAssertFalse(BackendAppsDeploy.privateIPv4("178.105.239.176"))
        XCTAssertFalse(BackendAppsDeploy.privateIPv4("172.19.0.3; rm -rf /"))
    }
}

/// Swift fake callbacks only. No subprocess, socket, server, or filesystem.
private actor BackendAppsDeployFake {
    static let token = "fixture-github-private-token"
    static let oldImage = "sha256:" + String(repeating: "b", count: 64)
    static let candidateID = String(repeating: "c", count: 64)
    static let previousID = String(repeating: "d", count: 64)
    static let branchHead = String(repeating: "a", count: 40)
    static let olderRevision = String(repeating: "b", count: 40)
    var record: NativeRPCValue
    var route: NativeRPCValue
    var candidate: NativeRPCValue = .missing
    var commands: [String] = []
    var events: [String] = []
    var cloneInput: Data?
    var fetchedRevisions: [String] = []
    var checkedOutRevision: String?, builtRevision: String?
    var failCommit: Bool
    var loseSwapResponse: Bool
    let failOldRoute: Bool
    let requireCallContext: Bool
    let ignoreExactCheckout: Bool, rejectRevisionFetch: Bool
    let acquisitionChange: NativeRPCValue?
    let failPreviousStop: Bool, unownedPrevious: Bool, failCleanupSave: Bool, loseCreateReply: Bool, expireOnCommit: Bool
    var previousRunning = true, dockerCalls = 0
    var candidateExists = false, ordinaryExpired = false
    var capturedIOCalls = 0, ordinaryDeniedCalls = 0, closedLeases = 0
    var recoveryOwner: String?
    var stateBytes: Data?
    var hashVerifications = 0
    var allRouteChecks = 0
    let unhealthy: Bool

    init(unhealthy: Bool = false, failCommit: Bool = false, loseSwapResponse: Bool = false, failOldRoute: Bool = false, requireCallContext: Bool = false,
         ignoreExactCheckout: Bool = false, rejectRevisionFetch: Bool = false, acquisitionChange: NativeRPCValue? = nil,
         failPreviousStop: Bool = false, unownedPrevious: Bool = false, failCleanupSave: Bool = false, loseCreateReply: Bool = false, expireOnCommit: Bool = false) {
        self.unhealthy = unhealthy; self.failCommit = failCommit; self.loseSwapResponse = loseSwapResponse
        self.failOldRoute = failOldRoute
        self.requireCallContext = requireCallContext
        self.ignoreExactCheckout = ignoreExactCheckout; self.rejectRevisionFetch = rejectRevisionFetch
        self.acquisitionChange = acquisitionChange; self.failPreviousStop = failPreviousStop; self.unownedPrevious = unownedPrevious
        self.failCleanupSave = failCleanupSave
        self.loseCreateReply = loseCreateReply
        self.expireOnCommit = expireOnCommit
        let o = BackendAppsValidation.object
        let old = o([("id", .string("terminaldeck-deploy-old")), ("imageTag", .string("terminaldeck/demo:terminaldeck-deploy-old")),
                     ("imageId", .string(Self.oldImage)), ("containerId", .string(Self.previousID)), ("upstream", .string("172.19.0.2")),
                     ("port", .number(8080)), ("domains", .array([.string("demo.178-105-239-176.sslip.io")])),
                     ("status", .string("running")), ("createdAt", .number(1))])
        record = o([("id", .string("demo")), ("name", .string("Demo")), ("kind", .string("app")), ("status", .string("running")),
                    ("activeDeploymentId", .string("terminaldeck-deploy-old")), ("deployments", .array([old])), ("autoDeploy", .bool(true)),
                    ("domains", old["domains"]), ("source", o([("kind", .string("github")), ("repository", .string("example/demo")),
                                                            ("branch", .string("main")), ("build", .string("dockerfile")), ("port", .number(8080))]))])
        route = Self.route(ip: "172.19.0.2")
    }
    struct Snapshot: Sendable {
        let record: NativeRPCValue, route: NativeRPCValue, candidate: NativeRPCValue
        let commands: [String], events: [String]
        let cloneInput: Data?
        let fetchedRevisions: [String]
        let checkedOutRevision: String?, builtRevision: String?
        let previousRunning: Bool, dockerCalls: Int
        let candidateExists: Bool, capturedIOCalls: Int, ordinaryDeniedCalls: Int, closedLeases: Int
        let recoveryOwner: String?
        let hashVerifications: Int
        let allRouteChecks: Int
    }
    func snapshot() -> Snapshot { .init(record: record, route: route, candidate: candidate, commands: commands, events: events, cloneInput: cloneInput,
                                      fetchedRevisions: fetchedRevisions, checkedOutRevision: checkedOutRevision, builtRevision: builtRevision,
                                      previousRunning: previousRunning, dockerCalls: dockerCalls, candidateExists: candidateExists, capturedIOCalls: capturedIOCalls,
                                      ordinaryDeniedCalls: ordinaryDeniedCalls, closedLeases: closedLeases, recoveryOwner: recoveryOwner, hashVerifications: hashVerifications,
                                      allRouteChecks: allRouteChecks) }
    func setSource(_ source: NativeRPCValue) { record = record.setting("source", source) }
    func patchRecord(_ patch: NativeRPCValue) { record = record.merging(patch) }
    func service(recovery: BackendAppsRecovery? = nil, credential: String = BackendAppsDeployFake.token) -> BackendAppsDeploy {
        let runtime = BackendAppsRuntime(execute: { _, command, stdin, _, _ in try await self.execute(command, stdin) },
                                        docker: { _, method, path, data in try await self.docker(method, path, data) },
                                        caddy: { _, method, path, data in try await self.caddy(method, path, data) },
                                        githubCredential: { _ in credential }, serverAddresses: { _ in ["178.105.239.176"] }, recovery: recovery, now: { 123_000 })
        return .init(runtime: runtime, store: .init(runtime: runtime), caddy: .init(runtime: runtime))
    }
    func execute(_ command: String, _ data: Data?, captured: Bool = false) throws -> BackendServersRunResult {
        try checkCallContext(captured: captured)
        commands.append(command)
        if captured, command.contains("terminaldeck-caddy-lock"), command.contains("acquired") { return .init(code: 0, stdout: "acquired") }
        if command.contains("mkdir --"), command.contains("/.lock/owner"), data != nil {
            events.append("lock")
            if let acquisitionChange { record = record.merging(acquisitionChange) }
            return .init(code: 0, stdout: "")
        }
        if command.contains("rmdir --"), command.contains("/.lock/owner") { events.append("unlock"); return .init(code: 0, stdout: "") }
        if let data, let json = try? NativeRPCValue.parseJSON(data), json["id"].string == "demo" {
            if failCleanupSave, !previousRunning, json["cleanupNeededContainers"].elements?.isEmpty == true {
                events.append("cleanup-save-failed"); return .init(code: 9, stdout: "", stderr: Self.token)
            }
            if json["deployments"].elements?.first?["status"].string == "building" { events.append("build-row") }
            if json["activeDeploymentId"].string != "terminaldeck-deploy-old" {
                if expireOnCommit, !ordinaryExpired, !captured { ordinaryExpired = true; events.append("commit-failed"); return .init(code: 9, stdout: "") }
                if failCommit { failCommit = false; events.append("commit-failed"); return .init(code: 9, stdout: "", stderr: Self.token) }
                events.append("commit")
            } else if !json["pendingDeploymentId"].isNullish { events.append("intent") }
            record = json
            stateBytes = data
            return .init(code: 0, stdout: "")
        }
        if command.contains("git ") {
            cloneInput = data
            var head = Self.branchHead
            let script = command.hasPrefix("sh -c '") && command.hasSuffix("'")
                ? String(command.dropFirst(7).dropLast()).replacingOccurrences(of: "'\\''", with: "'") : command
            if let fetched = capture(#"fetch --depth 1 --no-tags origin '([a-f0-9]{40}|[a-f0-9]{64})'"#, in: script) {
                if rejectRevisionFetch || fetched != Self.olderRevision { return .init(code: 128, stdout: "", stderr: Self.token) }
                fetchedRevisions.append(fetched)
                guard let checkout = capture(#"checkout --detach '([a-f0-9]{40}|[a-f0-9]{64})' --"#, in: script), fetchedRevisions.contains(checkout) else { return .init(code: 128, stdout: "") }
                if !ignoreExactCheckout { head = checkout; checkedOutRevision = checkout }
            }
            return .init(code: 0, stdout: head + "\n")
        }
        if command.contains("docker build") { builtRevision = checkedOutRevision ?? Self.branchHead }
        if command.contains("sha256sum --"), command.contains("state.json") {
            hashVerifications += 1
            let bytes = stateBytes ?? Data(record.compact.utf8)
            return .init(code: 0, stdout: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        if command.contains("cat --"), command.contains("state.json") { return .init(code: 0, stdout: stateBytes.map { String(decoding: $0, as: UTF8.self) } ?? record.compact) }
        if command.contains("cat --"), command.contains("/.env") { return .init(code: 44, stdout: "") }
        if command.contains("autosave.json") { return .init(code: 0, stdout: configuration().compact) }
        return .init(code: 0, stdout: "")
    }
    func docker(_ method: String, _ path: String, _ data: Data?, captured: Bool = false) throws -> BackendAppsHTTPResponse {
        try checkCallContext(captured: captured)
        dockerCalls += 1
        let o = BackendAppsValidation.object
        if path.hasPrefix("/images/") {
            let image = path.contains("old") ? Self.oldImage : "sha256:" + String(repeating: "a", count: 64)
            return try response(o([("Id", .string(image)), ("Config", o([]))]))
        }
        if path.hasPrefix("/networks/") { return try response(o([("Driver", .string("bridge")), ("Scope", .string("local")), ("Labels", o([("io.terminaldeck.managed", .string("true"))]))])) }
        if path.hasPrefix("/containers/create") {
            candidate = try NativeRPCValue.parseJSON(data!)
            candidateExists = true; events.append("create-candidate")
            if loseCreateReply { ordinaryExpired = true; throw CancellationError() }
            return try response(o([("Id", .string(Self.candidateID))]), status: 201)
        }
        if path.hasPrefix("/containers/json?") {
            return try response(.array(candidateExists ? [o([("Id", .string(Self.candidateID)), ("Labels", candidate["Labels"])])] : []))
        }
        if path == "/containers/\(Self.previousID)/stop?t=10", method == "POST" {
            events.append("stop-old-attempt")
            if failPreviousStop { return .init(status: 500) }
            previousRunning = false; events.append("stop-old")
            return .init(status: 204)
        }
        if path == "/containers/\(Self.previousID)/json" {
            return try response(o([("Id", .string(Self.previousID)), ("State", o([("Running", .bool(previousRunning))])),
                                   ("Config", o([("Labels", o([("io.terminaldeck.app", .string(unownedPrevious ? "another-app" : "demo")), ("io.terminaldeck.managed", .string("true"))]))]))]))
        }
        if path.hasSuffix("/json") {
            return try response(o([("Id", .string(Self.candidateID)), ("Config", o([("Labels", candidate["Labels"])])),
                                   ("State", o([("Running", .bool(true)), ("Health", o([("Status", .string(unhealthy ? "unhealthy" : "healthy"))]))])),
                                   ("NetworkSettings", o([("Networks", o([("terminaldeck-apps", o([("IPAddress", .string("172.19.0.3"))]))]))]))]))
        }
        if method == "DELETE" {
            events.append(path.contains(Self.candidateID) ? "remove-candidate" : "remove-old")
            if path.contains(Self.candidateID) { candidateExists = false; if captured { events.append("remove-candidate-recovery") } }
        }
        return .init(status: 204)
    }
    func caddy(_ method: String, _ path: String, _ data: Data?, captured: Bool = false) throws -> BackendAppsHTTPResponse {
        try checkCallContext(captured: captured)
        if method == "GET" {
            if path == "/config/apps/http/servers" {
                allRouteChecks += 1
                return try response(configuration()["apps"]["http"]["servers"])
            }
            if path.hasPrefix("/id/") { return path == "/id/terminaldeck-demo" && !route.isNullish ? try response(route) : .init(status: 404) }
            return try response(configuration())
        }
        if method == "PATCH" || method == "POST" || method == "PUT" {
            let nextRoute = try NativeRPCValue.parseJSON(data!)
            let isCandidate = nextRoute.compact.contains("172.19.0.3")
            events.append(isCandidate ? "route-candidate" : "route-old")
            if !isCandidate, failOldRoute { return .init(status: 500) }
            route = nextRoute
            if isCandidate, loseSwapResponse { loseSwapResponse = false; throw NativeRPCError(code: "fixture", message: Self.token) }
        }
        if method == "DELETE" { route = .missing; events.append("route-remove") }
        return .init(status: 200)
    }
    private func configuration() -> NativeRPCValue {
        let o = BackendAppsValidation.object
        let server = o([("@id", .string("td-app-server")), ("listen", .array([.string(":443")])), ("routes", .array([route]))])
        let http = o([("servers", o([("terminaldeck", server)]))])
        return o([("admin", o([("listen", .string("127.0.0.1:2019"))])), ("apps", o([("http", http)]))])
    }
    private func checkCallContext(captured: Bool = false) throws {
        if captured { capturedIOCalls += 1; return }
        if ordinaryExpired { ordinaryDeniedCalls += 1; throw NativeRPCError(code: "access-denied", message: "The ordinary approval expired.") }
        guard !requireCallContext || BackendAppsDeployFakeCallContext.owner == "approved-fixture" else {
            throw NativeRPCError(code: "access-denied", message: "The approved call context was lost.")
        }
    }
    func recoveryController() -> BackendAppsRecovery {
        BackendAppsRecovery(capture: { scope, _ in
            await self.capturedOwner(scope.ownerToken)
            return BackendAppsRecoveryTransport(
                execute: { _, command, input, _, _ in try await self.execute(command, input, captured: true) },
                docker: { _, method, path, body in try await self.docker(method, path, body, captured: true) },
                caddy: { _, method, path, body in try await self.caddy(method, path, body, captured: true) },
                authorizeRegistration: { _ in try await self.authorizeRegistration() }, validateBinding: { }, close: { await self.closeLease() })
        }, audit: { entry in await self.audit(entry) })
    }
    private func capturedOwner(_ owner: String) { recoveryOwner = owner }
    private func authorizeRegistration() throws { if ordinaryExpired { throw NativeRPCError(code: "access-denied", message: "Registration approval expired") } }
    private func closeLease() { closedLeases += 1 }
    private func audit(_ entry: BackendAppsRecoveryAudit) { if entry.event == "sealed", let operation = entry.operation { events.append("sealed:" + operation) } }
    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private func response(_ value: NativeRPCValue, status: Int = 200) throws -> BackendAppsHTTPResponse { .init(status: status, body: try value.encodedJSON()) }
    private static func route(ip: String) -> NativeRPCValue {
        let o = BackendAppsValidation.object
        return o([("@id", .string("terminaldeck-demo")), ("match", .array([o([("host", .array([.string("demo.178-105-239-176.sslip.io")]))])])),
                  ("handle", .array([o([("handler", .string("reverse_proxy")), ("upstreams", .array([o([("dial", .string(ip + ":8080"))])]))])]))])
    }
}

private enum BackendAppsDeployFakeCallContext {
    @TaskLocal static var owner: String?
}
