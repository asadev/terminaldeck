import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Production transport/client/channels against a private Unix Engine API.
/// This source is written for DKA's serial gate; DKT does not run it.
@Suite("DKT Docker contract")
struct DKTDockerContractTests {
    @Test func localTransportIsInertUntilRequestedAndClosesFiniteReplies() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let transport = localTransport(fake)
        #expect(fake.requests.isEmpty && fake.activeConnectionCount == 0)
        let response = try await transport.request(.init(path: "/version"))
        let version = try NativeRPCValue.parseJSON(response.body)
        #expect(response.status == 200 && version["ApiVersion"] == .string("1.47"))
        #expect(fake.requests.count == 1)
        #expect(fake.requests.first?.headers["host"] == "docker")
        #expect(fake.requests.first?.headers["connection"] == "close")
        try await eventually { fake.activeConnectionCount == 0 }
    }

    @Test func missingSocketFailsClearlyWithoutRevealingSubmittedPath() async throws {
        let path = DKTUnixSocketPath.temporaryRoot + "/dkt-missing-" + UUID().uuidString.prefix(12) + ".sock"
        try DKTUnixSocketPath.validateExistingParent(of: path)
        try #require(!FileManager.default.fileExists(atPath: path))
        var limits = transportLimits()
        limits.openTimeoutMilliseconds = 500
        let transport = BackendDockerLocalTransport(socketPath: path, limits: limits)
        let started = ContinuousClock.now
        do {
            _ = try await transport.request(.init(path: "/version"))
            Issue.record("A missing Docker socket returned success.")
        } catch let error as NativeRPCError {
            let missing = error.code == "docker-not-found"
            // Network.framework may keep the absent endpoint in .waiting.
            // Only the transport's exact bounded open deadline is accepted;
            // arbitrary unavailable failures must still fail this test.
            let openDeadline = error.code == "unavailable" && error.message == "Docker did not open a connection in time."
            #expect(missing || openDeadline)
            #expect(!error.message.contains(path))
            #expect(error.details == .missing)
        }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func requestFramingCannotInjectHeadersOrChangeTheDestination() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let transport = localTransport(fake)
        let unsafe: [BackendDockerRequest] = [
            .init(path: "/version\r\nHost: attacker"),
            .init(path: "//attacker/version"),
            .init(path: "/version", headers: ["Host": "attacker"]),
            .init(path: "/version", headers: ["Content-Length": "0"]),
            .init(path: "/version", headers: ["Transfer-Encoding": "chunked"]),
            .init(path: "/version", headers: ["X-Value": "safe\r\nHost: attacker"]),
            .init(path: "/version", headers: ["X-Value": "a", "x-value": "b"])
        ]
        for request in unsafe {
            do {
                _ = try await transport.request(request)
                Issue.record("Caller-controlled HTTP framing reached Docker.")
            } catch let error as NativeRPCError {
                #expect(error.code == "invalid-arguments")
            }
        }
        #expect(fake.requests.isEmpty && fake.activeConnectionCount == 0)
    }

    @Test func finiteBodyOverflowClosesThePrivateSocket() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        fake.setResponse(method: "GET", target: "/oversized", response: .init(body: Data(repeating: 65, count: 129)))
        var limits = transportLimits()
        limits.maximumBodyBytes = 128
        let transport = BackendDockerLocalTransport(socketPath: fake.socketPath, limits: limits)
        do {
            _ = try await transport.request(.init(path: "/oversized"))
            Issue.record("An oversized Engine response was accepted.")
        } catch let error as NativeRPCError {
            #expect(error.code == "docker-stream-overflow")
        }
        try await eventually { fake.activeConnectionCount == 0 }
    }

    @Test func HTTPChunksAndDockerFramesKeepUnicodeSourcesAndSecretsIntact() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let response = try await localTransport(fake).stream(.init(path: "/v1.47/containers/\(DKTDockerFake.containerID)/logs?follow=false"))
        let output = try BackendDockerStreams.logs(response: response, tty: false, secretValues: [DKTDockerFake.secret])
        defer { output.cancel() }
        var records: [NativeRPCValue] = []
        for try await record in output.records { records.append(record) }
        let stdout = records.filter { $0["source"] == .string("stdout") }.compactMap { $0["text"].string }.joined()
        let stderr = records.filter { $0["source"] == .string("stderr") }.compactMap { $0["text"].string }.joined()
        #expect(stdout == "ready 🙂 token=••••••\n")
        #expect(stderr == "synthetic warning\n")
        #expect(!records.map(\.compact).joined().contains(DKTDockerFake.secret))
        #expect(!stdout.contains("\u{fffd}"))
        try await eventually { fake.activeConnectionCount == 0 }
    }

    @Test func TTYLogsUseConsoleBytesWithoutMultiplexHeaders() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let response = try await localTransport(fake).stream(.init(path: "/v1.47/containers/\(DKTDockerFake.ttyContainerID)/logs?follow=false"))
        let output = try BackendDockerStreams.logs(response: response, tty: true, secretValues: [DKTDockerFake.secret])
        defer { output.cancel() }
        var text = ""
        for try await record in output.records {
            #expect(record["source"] == .string("console"))
            text += record["text"].string ?? ""
        }
        #expect(text == "ready 🙂 token=••••••\n")
        try await eventually { fake.activeConnectionCount == 0 }
    }

    @Test func fragmentedStatsCalculateCPUAndLinuxMemoryUsage() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let response = try await localTransport(fake).stream(.init(path: "/v1.47/containers/\(DKTDockerFake.containerID)/stats?stream=false"))
        let output = try BackendDockerStreams.stats(response: response)
        defer { output.cancel() }
        var records: [NativeRPCValue] = []
        for try await record in output.records { records.append(record) }
        let sample = try #require(records.first)
        #expect(records.count == 1)
        #expect(sample["cpuPercent"] == .number(20))
        #expect(sample["memoryBytes"] == .number(58_720_256))
        #expect(sample["memoryLimitBytes"] == .number(268_435_456))
        #expect(sample["memoryPercent"] == .number(21.875))
        #expect(sample["networkRxBytes"] == .number(1_024) && sample["networkTxBytes"] == .number(2_048))
        #expect(sample["blockReadBytes"] == .number(4_096) && sample["blockWriteBytes"] == .number(8_192))
        #expect(sample["pids"] == .number(3))
    }

    @Test func fragmentedEventsStripSecretAttributes() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let response = try await localTransport(fake).stream(.init(path: "/v1.47/events?until=1790000003"))
        let output = try BackendDockerStreams.events(response: response, secretValues: [DKTDockerFake.secret])
        defer { output.cancel() }
        var records: [NativeRPCValue] = []
        for try await record in output.records { records.append(record) }
        #expect(records.map { $0["action"].string } == ["start", "die"])
        #expect(records.first?["attributes"]["API_TOKEN"] == .string("••••••"))
        #expect(!records.map(\.compact).joined().contains(DKTDockerFake.secret))
    }

    @Test func failingStreamStatusIsARealFailureAndNeverPublishesEngineBody() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        fake.setResponse(method: "GET", target: "/broken-logs", response: .json(["message": DKTDockerFake.secret], statusCode: 404))
        let response = try await localTransport(fake).stream(.init(path: "/broken-logs"))
        do {
            _ = try BackendDockerStreams.logs(response: response, tty: false)
            Issue.record("An HTTP error became a successful empty log stream.")
        } catch let error as NativeRPCError {
            #expect(error.code == "docker-resource-missing")
            #expect(!error.wireValue.compact.contains(DKTDockerFake.secret))
        }
        try await eventually { fake.activeConnectionCount == 0 }
    }

    @Test func partialAndOversizedFramesFailWithBoundedPublicErrors() throws {
        var partial = try BackendDockerStreams.LogParser(tty: false)
        _ = try partial.consume(Data([1, 0, 0, 0, 0, 0, 0, 4, 65]))
        do {
            _ = try partial.finish()
            Issue.record("A partial Docker frame ended successfully.")
        } catch let error as NativeRPCError {
            #expect(error.code == "docker-protocol")
        }
        var oversized = try BackendDockerStreams.LogParser(tty: false, maximumFrameBytes: 8)
        do {
            _ = try oversized.consume(Data([1, 0, 0, 0, 0, 0, 0, 9]))
            Issue.record("A frame over the configured bound was accepted.")
        } catch let error as NativeRPCError {
            #expect(error.code == "docker-stream-overflow")
        }
    }

    @Test func overlappingSecretsAndSplitUTF8RemainPrivateUntilComplete() throws {
        var parser = try BackendDockerStreams.LogParser(tty: false, secretValues: ["secret", "secret-long"])
        let whole = Data("café🙂 secret-long secret\n".utf8)
        var records: [BackendDockerStreams.LogRecord] = []
        for byte in whole {
            records += try parser.consume(DKTDockerFake.multiplexedFrame(stream: 1, payload: Data([byte])))
        }
        records += try parser.finish()
        let text = records.map(\.text).joined()
        #expect(text == "café🙂 •••••• ••••••\n")
        #expect(!text.contains("secret") && !text.contains("\u{fffd}"))
    }

    @Test func typedClientNegotiatesOnceThenUsesVersionedEngineEndpoints() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let client = BackendDockerClient(transport: localTransport(fake))
        #expect(fake.requests.isEmpty)
        let containers = try await client.listContainers()
        let images = try await client.listImages()
        let volumes = try await client.listVolumes()
        let networks = try await client.listNetworks()
        let projects = try await client.listComposeProjects()
        #expect(containers.count == 2 && images.count == 1 && volumes.count == 1 && networks.count == 1)
        #expect(projects.count == 1 && projects.first?.name == "dkt-demo")
        #expect(projects.first?.services == ["web"])
        #expect(fake.requests.filter { $0.path == "/version" }.count == 1)
        #expect(fake.requests.dropFirst().allSatisfy { $0.path.hasPrefix("/v1.47/") })
        let composeRead = try #require(fake.requests.last)
        #expect(composeRead.enginePath == "/containers/json")
        let filters = try NativeRPCValue.parseJSON(Data((try #require(composeRead.query["filters"])).utf8))
        #expect(filters["label"] == .array([.string("com.docker.compose.project")]))
    }

    @Test func typedInspectStripsRawEnvCommandsAndHostMountPaths() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let client = BackendDockerClient(transport: localTransport(fake))
        let detail = try await client.inspectContainer(DKTDockerFake.containerID)
        #expect(detail.name == "dkt-web")
        let value = detail.value
        #expect(value["environment"].elements?.allSatisfy { $0["value"] == .string("••••••") } == true)
        #expect(!value.compact.contains(DKTDockerFake.secret))
        #expect(!value.compact.contains("synthetic/secret-mount"))
        #expect(!value.compact.contains("synthetic-secret"))
        #expect(value["Config"] == .missing && value["command"] == .missing)
        #expect(value["mounts"].elements?.first?["destination"] == .string("/data"))
    }

    @Test func versionNegotiationCapsNewEnginesAndRejectsIncompatibleOnes() async throws {
        for (engineVersion, minimum, compatible) in [("1.99", "1.24", true), ("1.40", "1.24", false), ("1.99", "1.48", false)] {
            let fake = DKTDockerFake()
            try fake.start()
            defer { fake.stop() }
            fake.setResponse(method: "GET", target: "/version", response: .json([
                "Version": "synthetic", "ApiVersion": engineVersion, "MinAPIVersion": minimum,
                "Os": "linux", "Arch": "amd64"
            ]))
            let client = BackendDockerClient(transport: localTransport(fake))
            do {
                _ = try await client.listContainers()
                #expect(compatible)
                #expect(fake.requests.last?.path == "/v1.47/containers/json")
            } catch let error as NativeRPCError {
                #expect(!compatible && error.code == "docker-api-version")
                #expect(fake.requests.count == 1)
            }
        }
    }

    @Test func typedHTTPAndMalformedJSONErrorsNeverExposeTheEngineBody() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let client = BackendDockerClient(transport: localTransport(fake))
        for status in [403, 404, 409, 500] {
            fake.setResponse(method: "GET", target: "/containers/json", response: .json(["message": DKTDockerFake.secret], statusCode: status))
            do {
                _ = try await client.listContainers()
                Issue.record("An Engine HTTP error became an empty container list.")
            } catch let error as NativeRPCError {
                #expect(error.code == (status == 404 ? "docker-resource-missing" : status == 403 ? "docker-permission" : "docker-api"))
                #expect(!error.wireValue.compact.contains(DKTDockerFake.secret))
            }
        }
        fake.setResponse(method: "GET", target: "/containers/json", response: .init(body: Data(("{broken:" + DKTDockerFake.secret).utf8)))
        do {
            _ = try await client.listContainers()
            Issue.record("Malformed Engine JSON became a successful result.")
        } catch let error as NativeRPCError {
            #expect(error.code == "docker-protocol")
            #expect(!error.wireValue.compact.contains(DKTDockerFake.secret))
        }
    }

    @Test func typedMutationUsesStructuredBodyAndRejectsInvalidIDsBeforeOpening() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let client = BackendDockerClient(transport: localTransport(fake))
        for id in ["../other", "bad?force=true", "bad\r\nHost: other", "bad%2Fid"] {
            do {
                try await client.startContainer(id)
                Issue.record("An invalid resource identifier reached Docker.")
            } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        #expect(fake.requests.isEmpty)
        let volume = try await client.createVolume(name: "td-test-contract-data", labels: ["terminaldeck.test": "true"])
        #expect(volume.name == "td-test-contract-data")
        let request = try #require(fake.requests.last)
        #expect(request.method == "POST" && request.enginePath == "/volumes/create")
        let body = try NativeRPCValue.parseJSON(request.body)
        #expect(body["Name"] == .string("td-test-contract-data") && body["Driver"] == .string("local"))
        #expect(body["Labels"]["terminaldeck.test"] == .string("true"))
    }

    @Test func channelRegistrationStartsNoConnectionsAndMissingApprovalFailsClosed() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let rig = try await makeRig(fake, authorize: nil)
        #expect(await rig.registry.channels().count == 28)
        #expect(fake.requests.isEmpty && fake.activeConnectionCount == 0)
        do {
            _ = try await rig.invoke("docker:containers:start", fields: [.init("id", .string(DKTDockerFake.containerID))])
            Issue.record("A missing access adapter allowed a mutation.")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        do {
            _ = try await rig.invoke("docker:containers:start", fields: [.init("id", .string(DKTDockerFake.containerID)), .init("approved", .bool(true))])
            Issue.record("An injected approval flag entered the closed channel schema.")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(fake.requests.isEmpty)
        await rig.stop()
    }

    @Test func channelApprovalRefusalAndBadArgumentsNeverMutateTheEngine() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let before = fake.snapshotInventory()
        let denied = try await makeRig(fake, authorize: { action, _ in
            if action.writesServer { throw NativeRPCError(code: "approval-required", message: "Synthetic refusal.") }
        })
        do {
            _ = try await denied.invoke("docker:containers:stop", fields: [.init("id", .string(DKTDockerFake.containerID))])
            Issue.record("A declined mutation reached the Engine.")
        } catch let error as NativeRPCError { #expect(error.code == "approval-required") }
        #expect(fake.requests.allSatisfy { $0.method == "GET" } && fake.snapshotInventory() == before)
        await denied.stop()
        let allowed = try await makeRig(fake)
        do {
            _ = try await allowed.invoke("docker:containers:stop", fields: [.init("id", .string(DKTDockerFake.containerID)), .init("timeoutSeconds", .number(-1))])
            Issue.record("An invalid timeout reached the Engine.")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(fake.requests.allSatisfy { $0.method == "GET" })
        #expect(fake.snapshotInventory() == before)
        await allowed.stop()
    }

    @Test func destructiveChannelChecksTheCurrentNameAndMutatesCanonicalID() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let actions = DKTContractActions()
        let rig = try await makeRig(fake, authorize: { action, _ in await actions.add(action) })
        do {
            _ = try await rig.invoke("docker:containers:remove", fields: [
                .init("id", .string("dkt-web")), .init("confirmName", .string("old-name")), .init("force", .bool(true))
            ])
            Issue.record("A stale name confirmed a destructive operation.")
        } catch let error as NativeRPCError { #expect(error.code == "confirmation-required") }
        #expect(fake.requests.allSatisfy { $0.method == "GET" })
        #expect(await actions.values.allSatisfy { !$0.destructive && !$0.writesServer })
        _ = try await rig.invoke("docker:containers:remove", fields: [
            .init("id", .string("dkt-web")), .init("confirmName", .string("dkt-web")), .init("force", .bool(true))
        ])
        let removal = try #require(fake.requests.first { $0.method == "DELETE" })
        #expect(removal.enginePath == "/containers/" + DKTDockerFake.containerID)
        #expect(removal.query["force"] == "true" && removal.query["v"] == "false")
        let approved = try #require(await actions.values.last)
        #expect(approved.destructive && approved.writesServer)
        #expect(approved.resourceID == DKTDockerFake.containerID && approved.confirmationName == "dkt-web")
        await rig.stop()
    }

    @Test func visibleLogStreamIsOwnedMaskedAndEndsOnceOnClose() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let rig = try await makeRig(fake)
        let visible = DKTContractEvents(), stranger = DKTContractEvents()
        let ownedSubscription = try await rig.registry.subscribeAll(ownerID: "dkt-screen") { await visible.add($0) }
        let otherSubscription = try await rig.registry.subscribeAll(ownerID: "another-screen") { await stranger.add($0) }
        #expect(fake.requests.isEmpty)
        let open = try await rig.invoke("docker:logs:open", fields: [.init("id", .string(DKTDockerFake.containerID))])
        let streamID = try #require(open["streamId"].string)
        try await eventuallyAsync { await visible.values.filter { $0.channel == "docker:logs:data" }.compactMap { $0.arguments.first?["text"].string }.joined().contains("synthetic warning") }
        #expect(await rig.service.activeCounts().streams == 1)
        #expect(await stranger.values.isEmpty)
        do {
            _ = try await rig.invoke("docker:stream:close", fields: [.init("streamId", .string(streamID))], owner: "another-screen")
            Issue.record("A different screen closed an owned stream.")
        } catch let error as NativeRPCError { #expect(error.code == "forbidden") }
        _ = try await rig.invoke("docker:stream:close", fields: [.init("streamId", .string(streamID))])
        try await eventually { fake.activeConnectionCount == 0 }
        let events = await visible.values
        #expect(events.filter { $0.channel == "docker:stream:end" }.count == 1)
        #expect(events.last?.arguments.first?["reason"] == .string("closed"))
        #expect(!events.map { $0.wireValue.compact }.joined().contains(DKTDockerFake.secret))
        let sequence = events.compactMap { $0.arguments.first?["sequence"].number }
        #expect(sequence == sequence.sorted() && Set(sequence).count == sequence.count)
        #expect(await rig.service.activeCounts().streams == 0)
        await ownedSubscription.cancelAndWait()
        await otherSubscription.cancelAndWait()
        await rig.stop()
    }

    @Test func disconnectStopsOnlyThatOwnersStreamsAndShutdownStopsTheRest() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let rig = try await makeRig(fake)
        _ = try await rig.invoke("docker:logs:open", fields: [.init("id", .string(DKTDockerFake.containerID))], owner: "first-screen")
        _ = try await rig.invoke("docker:stats:open", fields: [.init("id", .string(DKTDockerFake.containerID))], owner: "second-screen")
        #expect(await rig.service.activeCounts().streams == 2)
        await rig.service.disconnect(ownerID: "first-screen")
        #expect(await rig.service.activeCounts().streams == 1)
        await rig.service.shutdown()
        #expect(await rig.service.activeCounts().streams == 0)
        try await eventually { fake.activeConnectionCount == 0 }
        let requestsAfterShutdown = fake.requests.count
        await Task.yield()
        #expect(fake.requests.count == requestsAfterShutdown)
        await rig.registry.shutdown()
    }

    @Test func containerTerminalUsesHijackAndRejectsOtherOwnersInput() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let rig = try await makeRig(fake)
        let events = DKTContractEvents()
        let subscription = try await rig.registry.subscribeAll(ownerID: "dkt-screen") { await events.add($0) }
        let opened = try await rig.invoke("docker:exec:open", fields: [.init("id", .string(DKTDockerFake.containerID))])
        let sessionID = try #require(opened["sessionId"].string)
        let execID = try #require(opened["execId"].string)
        let input = Data("echo DKT\n".utf8)
        do {
            _ = try await rig.invoke("docker:exec:write", fields: [.init("sessionId", .string(sessionID)), .init("data", .string(input.base64EncodedString()))], owner: "another-screen")
            Issue.record("A different screen wrote into an approved terminal.")
        } catch let error as NativeRPCError { #expect(error.code == "forbidden") }
        #expect(fake.hijackedBytes.isEmpty)
        _ = try await rig.invoke("docker:exec:write", fields: [.init("sessionId", .string(sessionID)), .init("data", .string(input.base64EncodedString()))])
        try await eventually { fake.hijackedBytes.reduce(into: Data()) { $0.append($1) } == input }
        _ = try await rig.invoke("docker:exec:resize", fields: [.init("sessionId", .string(sessionID)), .init("columns", .number(120)), .init("rows", .number(40))])
        let resize = try #require(fake.requests.last { $0.enginePath == "/exec/\(execID)/resize" })
        #expect(resize.query["h"] == "40" && resize.query["w"] == "120")
        _ = try await rig.invoke("docker:exec:close", fields: [.init("sessionId", .string(sessionID))])
        try await eventually { fake.activeConnectionCount == 0 }
        let ends = await events.values.filter { $0.channel == "docker:exec:end" }
        #expect(ends.count == 1 && ends.first?.arguments.first?["reason"] == .string("closed"))
        #expect(ends.first?.arguments.first?["exitCode"] == .missing)
        #expect(await rig.service.activeCounts().sessions == 0)
        await subscription.cancelAndWait()
        await rig.stop()
    }

    @Test func installerChannelPreviewLocalDenialAndMissingRunnerDoNotTouchEngine() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let rig = try await makeRig(fake)
        let preview = try await rig.invoke("docker:install:preview")
        #expect(preview == BackendDockerInstall.preview)
        for (channel, target) in [("docker:install:preview", "local"), ("docker:install", "local"), ("docker:install", "fixture-server")] {
            do {
                _ = try await rig.invoke(channel, target: target)
                Issue.record("An unsupported installer action returned success.")
            } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        }
        #expect(fake.requests.isEmpty)
        await rig.stop()
    }

    @Test func disconnectWhileApprovalWaitsPreventsOpeningOrMutatingDocker() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let entered = BackendServersSSHOnce<Void>(), release = BackendServersSSHOnce<Void>()
        let rig = try await makeRig(fake, authorize: { _, _ in
            entered.finish(.success(()))
            try await release.value()
        })
        let operation = Task { try await rig.invoke("docker:containers:stop", fields: [.init("id", .string(DKTDockerFake.containerID))]) }
        try await entered.value()
        await rig.service.disconnect(ownerID: "dkt-screen")
        release.finish(.success(()))
        do {
            _ = try await operation.value
            Issue.record("A disconnected screen reached a mutation after approval returned.")
        } catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(fake.requests.isEmpty)
        await rig.stop()
    }

    @Test func destructiveApprovalRefusalAfterInspectionLeavesAllInventoryIntact() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let before = fake.snapshotInventory()
        let actions = DKTContractActions()
        let rig = try await makeRig(fake, authorize: { action, _ in
            await actions.add(action)
            if action.destructive { throw NativeRPCError(code: "approval-required", message: "Synthetic refusal.") }
        })
        do {
            _ = try await rig.invoke("docker:containers:remove", fields: [
                .init("id", .string(DKTDockerFake.containerID)), .init("confirmName", .string("dkt-web")), .init("force", .bool(true))
            ])
            Issue.record("A destructive approval refusal reached a delete request.")
        } catch let error as NativeRPCError { #expect(error.code == "approval-required") }
        #expect(fake.requests.contains { $0.enginePath.hasSuffix("/json") })
        #expect(fake.requests.allSatisfy { $0.method == "GET" })
        #expect(fake.snapshotInventory() == before)
        #expect(await actions.values.last?.confirmationName == "dkt-web")
        await rig.stop()
    }

    @Test func SSHTransportUsesOnlyTheFixedExistingConnectionCommand() async throws {
        let commands = DKTContractCommands()
        let transport = BackendDockerSSHTransport(openDialStdio: { command in
            await commands.add(command)
            throw NativeRPCError(code: "unavailable", message: "No live SSH connection is supplied in this test.")
        }, limits: transportLimits())
        #expect(await commands.values.isEmpty)
        do {
            _ = try await transport.request(.init(path: "/version"))
            Issue.record("A missing existing SSH connection returned success.")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await commands.values == ["docker system dial-stdio"])
    }

    @Test func installerReportsSuccessOnlyAfterARealEngineStatusResponse() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let commands = DKTContractCommands()
        let rig = try await makeRig(fake, install: { target, command, _ in
            #expect(target == "fixture-server")
            await commands.add(command)
        })
        let installed = try await rig.invoke("docker:install")
        #expect(installed["ok"] == .bool(true) && installed["status"]["available"] == .bool(true))
        #expect(await commands.values == [BackendDockerInstall.command])
        #expect(fake.requests.last?.path == "/version")
        fake.setResponse(method: "GET", target: "/version", response: .json(["message": DKTDockerFake.secret], statusCode: 500))
        do {
            _ = try await rig.invoke("docker:install")
            Issue.record("An installer callback succeeded without a working Engine.")
        } catch let error as NativeRPCError {
            #expect(error.code == "docker-api")
            #expect(!error.wireValue.compact.contains(DKTDockerFake.secret))
        }
        await rig.stop()
    }

    private func makeRig(_ fake: DKTDockerFake, authorize: BackendDockerDependencies.Authorize? = { _, _ in },
                         install: BackendDockerDependencies.Install? = nil) async throws -> DKTContractRig {
        let client = BackendDockerClient(transport: localTransport(fake))
        let service = BackendDockerService(dependencies: .init(resolve: { target, _ in
            guard target == "fixture-server" else { throw NativeRPCError(code: "unavailable", message: "Only the private test target exists.") }
            return client
        }, targets: { _ in [
            .init(id: "fixture-server", name: "Private test server", kind: "server", platform: "linux"),
            .init(id: "local", name: "This Mac", kind: "local", platform: "darwin")
        ] }, authorize: authorize, install: install, secretValues: { _, _ in [DKTDockerFake.secret] }))
        let registry = NativeChannelRegistry()
        _ = try await BackendDockerChannels.register(registry: registry, service: service, ownerID: "dkt-contract")
        return .init(registry: registry, service: service)
    }

    private func transportLimits() -> BackendDockerTransportLimits {
        var limits = BackendDockerTransportLimits()
        limits.maximumReadBytes = 64
        limits.openTimeoutMilliseconds = 2_000
        limits.requestTimeoutMilliseconds = 2_000
        limits.writeTimeoutMilliseconds = 2_000
        return limits
    }
    private func localTransport(_ fake: DKTDockerFake) -> BackendDockerLocalTransport {
        // Match BackendDockerMCPConnections.client("local"): the trusted
        // resolver supplies the fixture path and production transport defaults.
        // Dedicated framing/overflow cases retain explicit stress limits.
        .init(socketPath: fake.socketPath)
    }
    private func eventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
    private func eventuallyAsync(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predicate())
    }
}

private struct DKTContractRig: Sendable {
    let registry: NativeChannelRegistry
    let service: BackendDockerService
    func invoke(_ channel: String, fields: [NativeRPCValue.Field] = [], target: String = "fixture-server", owner: String = "dkt-screen") async throws -> NativeRPCValue {
        try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: owner),
            arguments: [.object([.init("target", .string(target))] + fields)])
    }
    func stop() async { await service.shutdown(); await registry.shutdown() }
}

private actor DKTContractActions {
    private(set) var values: [BackendDockerAction] = []
    func add(_ action: BackendDockerAction) { values.append(action) }
}

private actor DKTContractEvents {
    private(set) var values: [NativeRPCEvent] = []
    func add(_ event: NativeRPCEvent) { values.append(event) }
}

private actor DKTContractCommands {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
