import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Docker channel approval, confirmation and ownership")
struct BackendDockerChannelsTests {
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "docker-test-owner")

    @Test func registersEveryContractChannelWithoutOpeningEngine() async throws {
        let fixture = BackendDockerChannelFixture()
        let registry = NativeChannelRegistry(), service = fixture.service()
        let channels = try await BackendDockerChannels.register(registry: registry, service: service)
        #expect(channels.count == 28)
        #expect(Set(channels) == BackendDockerChannels.invokeChannels)
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func missingApprovalAdapterFailsBeforeResolver() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service(authorize: nil)
        try await BackendDockerChannels.register(registry: registry, service: service)
        await refusal("unavailable") {
            try await registry.invoke("docker:containers:start", context: context, arguments: [request("id", "box")])
        }
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func denialStopsAllMutationAndPayloadCannotApproveItself() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in
            if action.writesServer { throw NativeRPCError(code: "approval-required", message: "Ask the person first.") }
        }
        try await BackendDockerChannels.register(registry: registry, service: service)
        await refusal("approval-required") {
            try await registry.invoke("docker:containers:restart", context: context, arguments: [request("id", "box")])
        }
        await refusal("invalid-arguments") {
            try await registry.invoke("docker:containers:restart", context: context,
                                      arguments: [request("id", "box").setting("approved", .bool(true))])
        }
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func destructiveActionRequiresCurrentNameBeforeApproval() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in await fixture.action(action) }
        try await BackendDockerChannels.register(registry: registry, service: service)
        await refusal("confirmation-required") {
            try await registry.invoke("docker:containers:remove", context: context,
                                      arguments: [request("id", "alias").setting("confirmName", .string("old-name"))])
        }
        #expect(await fixture.actions().allSatisfy { !$0.destructive })
        #expect(await fixture.requests().allSatisfy { $0.method == "GET" })
        await service.shutdown()
    }

    @Test func confirmedRemovalApprovesAndDeletesCanonicalID() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in await fixture.action(action) }
        try await BackendDockerChannels.register(registry: registry, service: service)
        let result = try await registry.invoke("docker:containers:remove", context: context,
                                              arguments: [request("id", "alias").setting("confirmName", .string("td-test-box"))])
        #expect(result["ok"].bool == true)
        let approved = await fixture.actions().filter(\.destructive)
        #expect(approved.count == 1)
        #expect(approved.first?.resourceID == "canonical-box")
        #expect(approved.first?.confirmationName == "td-test-box")
        #expect(await fixture.requests().last?.path.contains("/containers/canonical-box?") == true)
        await service.shutdown()
    }

    @Test func installPreviewHasExactCommandAndNeverRunsIt() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service()
        try await BackendDockerChannels.register(registry: registry, service: service)
        let preview = try await registry.invoke("docker:install:preview", context: context, arguments: [request()])
        #expect(preview["command"].string == BackendDockerInstall.command)
        #expect(preview["requiresApproval"].bool == true)
        #expect(preview["requiresAdministrator"].bool == true)
        #expect(BackendDockerInstall.command.contains("mktemp"))
        #expect(await fixture.installs().isEmpty)
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func installerCannotRunOnThisMac() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in await fixture.action(action) }
        try await BackendDockerChannels.register(registry: registry, service: service)
        await refusal("unavailable") {
            try await registry.invoke("docker:install", context: context, arguments: [.object([.init("target", .string("local"))])])
        }
        #expect(await fixture.installs().isEmpty)
        #expect(await fixture.actions().allSatisfy { !$0.writesServer })
        await service.shutdown()
    }

    @Test func installerSuccessRequiresFreshEngineStatus() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service()
        try await BackendDockerChannels.register(registry: registry, service: service)
        let result = try await registry.invoke("docker:install", context: context, arguments: [request()])
        #expect(result["status"]["available"].bool == true)
        #expect(await fixture.installs() == [BackendDockerInstall.command])
        #expect(await fixture.requests().contains { $0.path == "/version" })
        await service.shutdown()
    }

    @Test func anotherOwnerCannotCloseStream() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service()
        try await BackendDockerChannels.register(registry: registry, service: service)
        let opened = try await registry.invoke("docker:events:open", context: context, arguments: [request()])
        let streamID = try #require(opened["streamId"].string)
        let other = NativeRPCContext(caller: .nativeApp, ownerID: "other-owner")
        await refusal("forbidden") {
            try await registry.invoke("docker:stream:close", context: other, arguments: [request("streamId", streamID)])
        }
        #expect(await service.activeCounts().streams == 1)
        await service.disconnect(ownerID: context.ownerID)
        #expect(await service.activeCounts().streams == 0)
        #expect(await fixture.streamCancellationCount() == 1)
        await service.shutdown()
    }

    @Test func wrongTargetCannotCloseOwnedStream() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service()
        try await BackendDockerChannels.register(registry: registry, service: service)
        let opened = try await registry.invoke("docker:events:open", context: context, arguments: [request()])
        let streamID = try #require(opened["streamId"].string)
        await refusal("forbidden") {
            try await registry.invoke("docker:stream:close", context: context,
                                      arguments: [request("streamId", streamID).setting("target", .string("another-server"))])
        }
        #expect(await service.activeCounts().streams == 1)
        await service.shutdown()
    }

    @Test func connectionOverridesAndDuplicateFieldsAreRefusedBeforeResolution() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service()
        try await BackendDockerChannels.register(registry: registry, service: service)
        for key in ["hostname", "password", "privateKey", "socketPath", "shell"] {
            await refusal("invalid-arguments") {
                try await registry.invoke("docker:status", context: context,
                                          arguments: [request().setting(key, .string("must-never-be-used"))])
            }
        }
        let duplicated: NativeRPCValue = .object([.init("target", .string("test-server")), .init("target", .string("another-server"))])
        await refusal("invalid-arguments") {
            try await registry.invoke("docker:status", context: context, arguments: [duplicated])
        }
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func providerDiagnosticsAreNotReturnedToCaller() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { _, _ in
            throw NativeRPCError(code: "approval-required", message: "ssh stderr PASSWORD=do-not-expose", details: .string("do-not-expose"))
        }
        try await BackendDockerChannels.register(registry: registry, service: service)
        do {
            _ = try await registry.invoke("docker:status", context: context, arguments: [request()])
            Issue.record("Provider diagnostic should fail safely")
        } catch let error as NativeRPCError {
            #expect(error.code == "approval-required")
            #expect(!error.message.contains("do-not-expose"))
            #expect(error.details == .missing)
        }
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func eventsAreOwnerFilteredAndDisconnectEmitsOneEnd() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service(), capture = BackendDockerChannelEventCapture()
        try await BackendDockerChannels.register(registry: registry, service: service)
        let received = BackendServersSSHOnce<NativeRPCValue>()
        let dataSubscription = try await registry.subscribe("docker:events:data", ownerID: context.ownerID) { event in
            await capture.record(event, other: false)
            received.finish(.success(event.arguments[0]))
        }
        let otherSubscription = try await registry.subscribe("docker:events:data", ownerID: "another-owner") { event in
            await capture.record(event, other: true)
        }
        let endSubscription = try await registry.subscribe("docker:stream:end", ownerID: context.ownerID) { event in
            await capture.record(event, other: false)
        }
        let opened = try await registry.invoke("docker:events:open", context: context, arguments: [request()])
        let id = try #require(opened["streamId"].string)
        await fixture.emitEvent(#"{"Type":"container","Action":"die","Actor":{"ID":"td-test-box","Attributes":{"token":"must-mask"}},"time":1,"timeNano":1000000000}"# + "\n")
        let event = try await gateValue(received, label: "owner-filtered event")
        #expect(event["streamId"].string == id)
        #expect(event["sequence"].number == 1)
        #expect(event["attributes"]["token"].string == "••••••")
        #expect(await capture.otherCount() == 0)
        await service.disconnect(ownerID: context.ownerID)
        await service.shutdown()
        #expect(await capture.endCount() == 1)
        #expect(await fixture.streamCancellationCount() == 1)
        await dataSubscription.cancelAndWait(); await otherSubscription.cancelAndWait(); await endSubscription.cancelAndWait()
    }

    @Test func invalidMutationFieldsFailBeforeApprovalAndEngineIO() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in await fixture.action(action) }
        try await BackendDockerChannels.register(registry: registry, service: service)
        let requests: [(String, NativeRPCValue)] = [
            ("docker:containers:start", request("id", "../bad")),
            ("docker:containers:stop", request("id", "box").setting("timeoutSeconds", .number(601))),
            ("docker:containers:remove", request("id", "box").setting("force", .string("true"))),
            ("docker:volumes:create", request("name", "invalid name")),
            ("docker:networks:create", request("name", "valid").setting("driver", .string("../bad"))),
            ("docker:exec:open", request("id", "box").setting("command", .array([]))),
        ]
        for (channel, payload) in requests {
            await refusal("invalid-arguments") { try await registry.invoke(channel, context: context, arguments: [payload]) }
        }
        #expect(await fixture.actions().isEmpty)
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func missingInstallerRunnerFailsBeforeWriteConsent() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = BackendDockerService(dependencies: .init(resolve: { _, _ in BackendDockerClient(transport: fixture) },
            targets: { _ in [.init(id: "test-server", name: "Fixture", kind: "server", platform: "linux")] },
            authorize: { action, _ in await fixture.action(action) }, install: nil))
        try await BackendDockerChannels.register(registry: registry, service: service)
        await refusal("unavailable") { try await registry.invoke("docker:install", context: context, arguments: [request()]) }
        #expect(await fixture.actions().allSatisfy { !$0.writesServer })
        #expect(await fixture.installs().isEmpty)
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func unavailableTargetFailsBeforeWriteConsent() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = BackendDockerService(dependencies: .init(resolve: { _, _ in
            throw NativeRPCError(code: "unavailable", message: "No connection exists")
        }, targets: { _ in [] }, authorize: { action, _ in await fixture.action(action) }))
        try await BackendDockerChannels.register(registry: registry, service: service)
        await refusal("unavailable") { try await registry.invoke("docker:containers:start", context: context, arguments: [request("id", "box")]) }
        #expect(await fixture.actions().allSatisfy { !$0.writesServer })
        #expect(await fixture.requests().isEmpty)
        await service.shutdown()
    }

    @Test func destructiveApprovalCarriesExactForceAndVolumeOptions() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in await fixture.action(action) }
        try await BackendDockerChannels.register(registry: registry, service: service)
        let payload = request("id", "alias").setting("confirmName", .string("td-test-box"))
            .setting("force", .bool(true)).setting("removeVolumes", .bool(true))
        _ = try await registry.invoke("docker:containers:remove", context: context, arguments: [payload])
        let action = try #require(await fixture.actions().first(where: \.destructive))
        #expect(action.parameters["force"].bool == true)
        #expect(action.parameters["removeVolumes"].bool == true)
        #expect(action.confirmationName == "td-test-box")
        await service.shutdown()
    }

    @Test func terminalApprovalCommandMasksEnvironmentSecretsBeforeConsent() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in
            await fixture.action(action)
            if action.writesServer { throw NativeRPCError(code: "approval-required", message: "Not approved") }
        }
        try await BackendDockerChannels.register(registry: registry, service: service)
        let payload = request("id", "box").setting("command", .array([.string("/bin/sh"), .string("-c"), .string("printf do-not-expose")]))
        await refusal("approval-required") { try await registry.invoke("docker:exec:open", context: context, arguments: [payload]) }
        let action = try #require(await fixture.actions().first(where: \.writesServer))
        #expect(action.commandPreview?.contains("do-not-expose") == false)
        #expect(action.commandPreview?.contains("••••••") == true)
        #expect(await fixture.requests().allSatisfy { $0.method == "GET" })
        await service.shutdown()
    }

    @Test func disconnectedOwnerCannotRequestConsentAfterSecretPreflightResumes() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let entered = BackendServersSSHOnce<Void>(), release = BackendServersSSHOnce<[String]>()
        let service = BackendDockerService(dependencies: .init(resolve: { _, _ in BackendDockerClient(transport: fixture) },
            targets: { _ in [.init(id: "test-server", name: "Fixture", kind: "server", platform: "linux")] },
            authorize: { action, _ in await fixture.action(action) }, secretValues: { _, _ in
                entered.finish(.success(()))
                // Deliberately ignores cancellation to verify the service's
                // owner-generation fence before opening a new approval.
                return try await release.value()
            }))
        try await BackendDockerChannels.register(registry: registry, service: service)
        let call = Task { try await registry.invoke("docker:exec:open", context: context, arguments: [request("id", "box")]) }
        try await gateValue(entered, label: "secret preflight")
        await service.disconnect(ownerID: context.ownerID)
        release.finish(.success([]))
        do { _ = try await taskValue(call, label: "disconnected terminal call"); Issue.record("A disconnected terminal request returned success") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await fixture.actions().allSatisfy { !$0.writesServer })
        #expect(await fixture.requests().allSatisfy { $0.method == "GET" })
        await service.shutdown()
    }

    @Test func directHandleDisconnectCancelsItsOwnTransportRequest() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let held = BackendDockerChannelHold(), service = fixture.service()
        await fixture.holdVersionRequest(held)
        try await BackendDockerChannels.register(registry: registry, service: service)
        // No registry.invoke pending task exists: the service must own this
        // direct invocation's cancellation instead of relying on the registry.
        let call = Task { try await service.handle("docker:status", context: context, arguments: [request()]) }
        try await gateValue(held.entered, label: "held version request")
        await service.disconnect(ownerID: context.ownerID)
        do { _ = try await taskValue(call, label: "direct handle cancellation"); Issue.record("Disconnected status returned success") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(held.wasCancelled)
        #expect(await fixture.requests().count == 1)
        await service.shutdown()
    }

    @Test func naturalEOFDeliversEndToCancellationAwareListener() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service(), ended = BackendServersSSHOnce<NativeRPCValue>()
        try await BackendDockerChannels.register(registry: registry, service: service)
        let subscription = try await registry.subscribe("docker:stream:end", ownerID: context.ownerID) { event in
            try Task.checkCancellation()
            ended.finish(.success(event.arguments[0]))
        }
        _ = try await registry.invoke("docker:events:open", context: context, arguments: [request()])
        await fixture.endStreams()
        let event = try await gateValue(ended, label: "natural EOF end")
        #expect(event["reason"].string == "eof")
        #expect(await service.activeCounts().streams == 0)
        await subscription.cancelAndWait(); await service.shutdown()
    }

    @Test func terminalApprovalMasksUnknownCredentialFlagValues() async throws {
        let fixture = BackendDockerChannelFixture(), registry = NativeChannelRegistry()
        let service = fixture.service { action, _ in
            await fixture.action(action)
            if action.writesServer { throw NativeRPCError(code: "approval-required", message: "Not approved") }
        }
        try await BackendDockerChannels.register(registry: registry, service: service)
        let payload = request("id", "box").setting("command", .array([
            .string("mysql"), .string("--password"), .string("fresh-untracked-password"),
            .string("--token=fresh-inline-token"), .string("-pfresh-attached-password")
        ]))
        await refusal("approval-required") { try await registry.invoke("docker:exec:open", context: context, arguments: [payload]) }
        let action = try #require(await fixture.actions().first(where: \.writesServer))
        let parameters = String(decoding: try action.parameters.encodedJSON(), as: UTF8.self)
        for secret in ["fresh-untracked-password", "fresh-inline-token", "fresh-attached-password"] {
            #expect(!parameters.contains(secret))
            #expect(action.commandPreview?.contains(secret) == false)
        }
        #expect(await fixture.requests().allSatisfy { $0.method == "GET" })
        await service.shutdown()
    }

    private func request(_ key: String? = nil, _ value: String? = nil) -> NativeRPCValue {
        var result: NativeRPCValue = .object([.init("target", .string("test-server"))])
        if let key, let value { result = result.setting(key, .string(value)) }; return result
    }
    private func refusal(_ code: String, operation: () async throws -> NativeRPCValue) async {
        do { _ = try await operation(); Issue.record("Expected refusal \(code)") }
        catch let error as NativeRPCError { #expect(error.code == code) }
        catch { Issue.record("Unexpected error \(error)") }
    }
    private func gateValue<T: Sendable>(_ gate: BackendServersSSHOnce<T>, label: String) async throws -> T {
        // A missing lifecycle event fails promptly instead of hanging the fake
        // suite. An unstructured watchdog can settle the once-gate without
        // waiting for an uncooperative child as a task-group timeout would.
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
                gate.finish(.failure(NativeRPCError(code: "test-timeout", message: "Fixture did not reach \(label).")))
            } catch {}
        }
        defer { watchdog.cancel() }
        return try await gate.value()
    }
    private func taskValue<T: Sendable>(_ task: Task<T, Error>, label: String) async throws -> T {
        let gate = BackendServersSSHOnce<T>()
        let observer = Task {
            do { gate.finish(.success(try await task.value)) }
            catch { gate.finish(.failure(error)) }
        }
        defer { observer.cancel() }
        do { return try await gateValue(gate, label: label) }
        catch { task.cancel(); throw error }
    }
}

private actor BackendDockerChannelFixture: BackendDockerTransport {
    private var calls: [BackendDockerRequest] = [], approvalActions: [BackendDockerAction] = [], commands: [String] = []
    private var continuations: [AsyncThrowingStream<Data, Error>.Continuation] = []
    private let cancellation = BackendDockerChannelCancellation()
    private var heldVersion: BackendDockerChannelHold?
    nonisolated func service(authorize: BackendDockerDependencies.Authorize? = { _, _ in }) -> BackendDockerService {
        BackendDockerService(dependencies: .init(resolve: { _, _ in BackendDockerClient(transport: self) }, targets: { _ in [
            .init(id: "test-server", name: "Fixture Linux", kind: "server", platform: "linux"),
            .init(id: "local", name: "This Mac", kind: "local", platform: "darwin")
        ] }, authorize: authorize, install: { _, command, _ in await self.installed(command) }))
    }
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        calls.append(request)
        let body: String
        if request.path == "/version" {
            if let heldVersion { try await heldVersion.wait() }
            body = #"{"Version":"27.0.0","ApiVersion":"1.47","MinAPIVersion":"1.24","Os":"linux","Arch":"amd64"}"#
        } else if request.path.contains("/containers/") && request.path.contains("/json") {
            body = #"{"Id":"canonical-box","Name":"/td-test-box","Created":"2026-10-07T12:00:00Z","Config":{"Image":"fixture","Tty":false,"Env":["PASSWORD=do-not-expose"],"Labels":{}},"State":{"Status":"running","Running":true},"Mounts":[],"NetworkSettings":{"Ports":{}}}"#
        } else { body = "{}" }
        return .init(status: request.method == "DELETE" ? 204 : 200, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream {
        calls.append(request)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = continuations.count; continuations.append(pair.continuation)
        let cancellation = self.cancellation
        return .init(status: 200, headers: [:], data: pair.stream, cancel: { cancellation.cancel(id, continuation: pair.continuation) })
    }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex { throw NativeRPCError(code: "unavailable", message: "No terminal fixture is installed here.") }
    func action(_ action: BackendDockerAction) { approvalActions.append(action) }
    func requests() -> [BackendDockerRequest] { calls }
    func actions() -> [BackendDockerAction] { approvalActions }
    func installs() -> [String] { commands }
    func streamCancellationCount() -> Int { cancellation.count }
    func emitEvent(_ text: String) { for continuation in continuations { continuation.yield(Data(text.utf8)) } }
    func endStreams() { for continuation in continuations { continuation.finish() } }
    func holdVersionRequest(_ hold: BackendDockerChannelHold) { heldVersion = hold }
    private func installed(_ command: String) { commands.append(command) }
}

private final class BackendDockerChannelHold: @unchecked Sendable {
    let entered = BackendServersSSHOnce<Void>()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                let refuse = lock.withLock { if cancelled { return true }; continuation = pending; return false }
                entered.finish(.success(()))
                if refuse { pending.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let pending = self.lock.withLock { self.cancelled = true; let old = self.continuation; self.continuation = nil; return old }
            pending?.resume(throwing: CancellationError())
        }
    }
}

private actor BackendDockerChannelEventCapture {
    private var other = 0, ends = 0
    func record(_ event: NativeRPCEvent, other: Bool) {
        if other { self.other += 1 }
        if event.channel == "docker:stream:end" { ends += 1 }
    }
    func otherCount() -> Int { other }
    func endCount() -> Int { ends }
}

private final class BackendDockerChannelCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Set<Int> = []
    var count: Int { lock.withLock { cancelled.count } }
    func cancel(_ id: Int, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        if lock.withLock({ cancelled.insert(id).inserted }) { continuation.finish() }
    }
}
